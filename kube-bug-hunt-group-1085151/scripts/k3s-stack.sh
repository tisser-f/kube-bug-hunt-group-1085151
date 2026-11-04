#!/usr/bin/env bash
# =============================================================================
# k3s-stack.sh
# Installe sur k3s (Debian 12, single-node) :
#   Helm 4 -> kube-prometheus-stack -> (Kyverno || KEDA || RabbitMQ en parallèle)
# RabbitMQ : chart Bitnami (images bitnamilegacy, FIGÉES depuis août 2025 = lab only),
#            métriques Prometheus + ServiceMonitor, vhost "orders",
#            exchange "orders" (topic) -> queue durable "orders.q" -> DLX "orders.dlx" -> DLQ "orders.dlq".
#
# Idempotent : relançable sans casse (helm upgrade --install, secrets jamais régénérés).
# Usage      : sudo ./k3s-stack.sh
# Versions vérifiées le 2026-11-04.
# =============================================================================
set -Eeuo pipefail
IFS=$'\n\t'
umask 077

# ---------- Versions épinglées ----------
readonly HELM_VERSION="v4.3.1"
readonly KPS_VERSION="92.18.0"              # kube-prometheus-stack
readonly KYVERNO_VERSION="3.9.2"            # chart 3.9.2 = Kyverno v1.19.2
readonly KEDA_VERSION="2.21.0"
readonly RABBITMQ_CHART_VERSION="16.0.14"   # RabbitMQ 4.1.3 

# ---------- Paramètres ----------
readonly TIMEOUT="10m"
readonly NS_MON="monitoring" NS_KYV="kyverno" NS_KEDA="keda" NS_MQ="rabbitmq"
readonly MQ_VHOST="orders" MQ_USER="admin"
export KUBECONFIG="${KUBECONFIG:-/etc/rancher/k3s/k3s.yaml}"

WORKDIR="$(mktemp -d)"
readonly WORKDIR
KUBECTL=()

# ---------- Logs & gestion d'erreurs ----------
log() { printf '\033[1;34m[%(%H:%M:%S)T] %s\033[0m\n' -1 "$*"; }
ok()  { printf '\033[1;32m[OK] %s\033[0m\n' "$*"; }
die() { printf '\033[1;31m[ERREUR] %s\033[0m\n' "$*" >&2; exit 1; }
on_error() { printf '\033[1;31m[ERREUR] ligne %s : "%s" (code %s)\033[0m\n' "$1" "$2" "$3" >&2; }
trap 'rc=$?; on_error "$LINENO" "$BASH_COMMAND" "$rc"' ERR
trap 'rm -rf "$WORKDIR"' EXIT

k()   { "${KUBECTL[@]}" "$@"; }
gen() { openssl rand -hex "${1:-24}"; }

# helm_up <release> <namespace> <chart> <version> [args helm...]
# --rollback-on-failure (Helm 4, ex --atomic) : rollback, ou uninstall si 1re install ratée.
helm_up() {
  local rel=$1 ns=$2 chart=$3 ver=$4; shift 4
  helm upgrade --install "$rel" "$chart" --version "$ver" -n "$ns" --create-namespace \
    --rollback-on-failure --wait --timeout "$TIMEOUT" "$@"
}

ensure_ns() { local ns; for ns in "$@"; do k create ns "$ns" --dry-run=client -o yaml | k apply -f - >/dev/null; done; }

ensure_secret() {
  local ns=$1 name=$2 kv d args=(); shift 2
  if k -n "$ns" get secret "$name" >/dev/null 2>&1; then ok "Secret $ns/$name existant : réutilisé"; return 0; fi
  d="$WORKDIR/sec-$name"; mkdir -p "$d"
  for kv in "$@"; do
    printf '%s' "${kv#*=}" >"$d/${kv%%=*}"
    args+=("--from-file=${kv%%=*}=$d/${kv%%=*}")
  done
  k -n "$ns" create secret generic "$name" "${args[@]}" >/dev/null
  ok "Secret $ns/$name créé"
}

# ---------- 0. Prérequis ----------
preflight() {
  log "Vérification des prérequis"
  [[ $EUID -eq 0 ]] || die "Lancer en root (sudo) : kubeconfig k3s + écriture dans /usr/local/bin."
  grep -q '^VERSION_ID="12"' /etc/os-release || log "Attention : OS différent de Debian 12."
  local bin
  for bin in curl openssl tar sha256sum base64; do
    command -v "$bin" >/dev/null || die "Binaire manquant : $bin (apt install $bin)"
  done
  if command -v kubectl >/dev/null; then KUBECTL=(kubectl)
  elif command -v k3s >/dev/null; then KUBECTL=(k3s kubectl)
  else die "kubectl / k3s introuvable."; fi
  [[ -r $KUBECONFIG ]] || die "Kubeconfig illisible : $KUBECONFIG"
  k get --raw='/readyz' >/dev/null || die "API server k3s injoignable."
  ok "Prérequis OK"
}

# ---------- 1. Helm (binaire officiel + vérification SHA256) ----------
install_helm() {
  if command -v helm >/dev/null && [[ "$(helm version --template '{{.Version}}' 2>/dev/null)" == "$HELM_VERSION" ]]; then
    ok "Helm $HELM_VERSION déjà installé"; return 0
  fi
  local arch
  case "$(uname -m)" in
    x86_64) arch=amd64 ;; aarch64|arm64) arch=arm64 ;;
    *) die "Architecture non supportée : $(uname -m)" ;;
  esac
  local tgz="helm-${HELM_VERSION}-linux-${arch}.tar.gz" base="https://get.helm.sh"
  log "Téléchargement Helm $HELM_VERSION ($arch)"
  curl -fsSL --retry 3 -o "$WORKDIR/$tgz" "$base/$tgz"
  curl -fsSL --retry 3 -o "$WORKDIR/$tgz.sha256sum" "$base/$tgz.sha256sum"
  # Compare uniquement le hash (1er champ) : robuste quel que soit le format du fichier.
  local expected actual
  expected="$(awk '{print $1; exit}' "$WORKDIR/$tgz.sha256sum")"
  actual="$(sha256sum "$WORKDIR/$tgz" | awk '{print $1}')"
  [[ -n $expected && $expected == "$actual" ]] || die "Checksum Helm invalide (attendu $expected, obtenu $actual)."
  tar -xzf "$WORKDIR/$tgz" -C "$WORKDIR" "linux-${arch}/helm"
  install -m 0755 "$WORKDIR/linux-${arch}/helm" /usr/local/bin/helm
  ok "Helm $(helm version --template '{{.Version}}') installé"
}

# ---------- 2. kube-prometheus-stack (en premier : fournit les CRD ServiceMonitor) ----------
install_kps() {
  log "kube-prometheus-stack $KPS_VERSION"
  ensure_secret "$NS_MON" grafana-admin "admin-user=admin" "admin-password=$(gen)"
  cat >"$WORKDIR/kps-values.yaml" <<'EOF'
# k3s : controller-manager, scheduler et kube-proxy écoutent sur 127.0.0.1,
# etcd embarqué / sqlite -> non scrapables par défaut : désactivés (sinon cibles "down").
kubeEtcd:              { enabled: false }
kubeControllerManager: { enabled: false }
kubeScheduler:         { enabled: false }
kubeProxy:             { enabled: false }
defaultRules:
  rules:
    etcd: false
prometheus:
  prometheusSpec:
    serviceMonitorSelectorNilUsesHelmValues: false
    podMonitorSelectorNilUsesHelmValues: false
    ruleSelectorNilUsesHelmValues: false
    retention: 7d
    resources:
      requests: { cpu: 200m, memory: 512Mi }
      limits:   { memory: 1536Mi }
alertmanager:
  alertmanagerSpec:
    resources:
      requests: { cpu: 20m, memory: 64Mi }
      limits:   { memory: 128Mi }
grafana:
  admin:
    existingSecret: grafana-admin
    userKey: admin-user
    passwordKey: admin-password
EOF
  helm_up kps "$NS_MON" oci://ghcr.io/prometheus-community/charts/kube-prometheus-stack \
    "$KPS_VERSION" -f "$WORKDIR/kps-values.yaml"
  k get crd servicemonitors.monitoring.coreos.com >/dev/null || die "CRD ServiceMonitor absente après install kps."
  ok "kube-prometheus-stack prêt"
}

# ---------- 3a. Kyverno ----------
deploy_kyverno() {
  helm_up kyverno "$NS_KYV" oci://ghcr.io/kyverno/charts/kyverno "$KYVERNO_VERSION"
}

# ---------- 3b. KEDA ----------
deploy_keda() {
  helm_up keda "$NS_KEDA" keda "$KEDA_VERSION" --repo https://kedacore.github.io/charts
}

# ---------- 3c. RabbitMQ  ----------
prepare_rabbitmq() {
  log "Préparation RabbitMQ (secrets + topologie)"
  # Clés attendues par le chart Bitnami : rabbitmq-password / rabbitmq-erlang-cookie
  ensure_secret "$NS_MQ" rabbitmq-auth "rabbitmq-password=$(gen)" "rabbitmq-erlang-cookie=$(gen 32)"

  local pw sha
  pw="$(k -n "$NS_MQ" get secret rabbitmq-auth -o jsonpath='{.data.rabbitmq-password}' | base64 -d)"
  [[ -n $pw ]] || die "Mot de passe RabbitMQ vide dans le secret rabbitmq-auth."

  cat >"$WORKDIR/load_definition.json" <<EOF
{
  "users": [ { "name": "${MQ_USER}", "password": "${pw}", "tags": "administrator" } ],
  "vhosts": [ { "name": "${MQ_VHOST}" } ],
  "permissions": [
    { "user": "${MQ_USER}", "vhost": "${MQ_VHOST}", "configure": ".*", "write": ".*", "read": ".*" }
  ],
  "exchanges": [
    { "name": "orders",     "vhost": "${MQ_VHOST}", "type": "topic",  "durable": true, "auto_delete": false, "internal": false, "arguments": {} },
    { "name": "orders.dlx", "vhost": "${MQ_VHOST}", "type": "fanout", "durable": true, "auto_delete": false, "internal": false, "arguments": {} }
  ],
  "queues": [
    { "name": "orders.q", "vhost": "${MQ_VHOST}", "durable": true, "auto_delete": false,
      "arguments": { "x-queue-type": "classic", "x-dead-letter-exchange": "orders.dlx" } },
    { "name": "orders.dlq", "vhost": "${MQ_VHOST}", "durable": true, "auto_delete": false,
      "arguments": { "x-queue-type": "classic" } }
  ],
  "bindings": [
    { "source": "orders",     "vhost": "${MQ_VHOST}", "destination": "orders.q",   "destination_type": "queue", "routing_key": "orders.#", "arguments": {} },
    { "source": "orders.dlx", "vhost": "${MQ_VHOST}", "destination": "orders.dlq", "destination_type": "queue", "routing_key": "",         "arguments": {} }
  ]
}
EOF
  # --server-side : pas d'annotation last-applied-configuration (qui recopierait le secret en clair).
  k -n "$NS_MQ" create secret generic rabbitmq-definitions \
    --from-file=load_definition.json="$WORKDIR/load_definition.json" --dry-run=client -o yaml \
    | k apply --server-side --force-conflicts -f - >/dev/null

  # Checksum en annotation : le pod redémarre seulement si la topologie change.
  sha="$(sha256sum "$WORKDIR/load_definition.json" | awk '{print $1}')"
  cat >"$WORKDIR/rabbitmq-values.yaml" <<EOF
global:
  security:
    allowInsecureImages: true          # requis pour des images hors docker.io/bitnami
image:
  repository: bitnamilegacy/rabbitmq   # images figées : lab uniquement
volumePermissions:
  image:
    repository: bitnamilegacy/os-shell
replicaCount: 1
auth:
  username: ${MQ_USER}
  existingPasswordSecret: rabbitmq-auth
  existingErlangSecret: rabbitmq-auth
  securePassword: false                # incompatible avec loadDefinition (doc Bitnami)
loadDefinition:
  enabled: true
  existingSecret: rabbitmq-definitions
extraConfiguration: |
  load_definitions = /app/load_definition.json
metrics:
  enabled: true                        # active le plugin rabbitmq_prometheus
  serviceMonitor:
    default:
      enabled: true                    # endpoint /metrics
podAnnotations:
  checksum/definitions: "${sha}"
EOF
  ok "RabbitMQ préparé"
}

deploy_rabbitmq() {
  helm_up rabbitmq "$NS_MQ" oci://registry-1.docker.io/bitnamicharts/rabbitmq \
    "$RABBITMQ_CHART_VERSION" -f "$WORKDIR/rabbitmq-values.yaml"
}

# ---------- Exécution parallèle (gain de temps principal) ----------
run_parallel() {
  local -A pids=()
  local job rc=0
  for job in "$@"; do
    log "Lancement : $job"
    "$job" >"$WORKDIR/$job.log" 2>&1 &
    pids[$job]=$!
  done
  for job in "${!pids[@]}"; do
    if wait "${pids[$job]}"; then ok "$job terminé"
    else rc=1; printf '\n--- %s.log ---\n' "$job" >&2; cat "$WORKDIR/$job.log" >&2; fi
  done
  (( rc == 0 )) || die "Au moins une installation a échoué (logs ci-dessus)."
}

# ---------- 4. Vérification ----------
verify() {
  log "Vérification RabbitMQ (vhost $MQ_VHOST)"
  k -n "$NS_MQ" exec rabbitmq-0 -c rabbitmq -- rabbitmqctl -q list_exchanges -p "$MQ_VHOST" name type durable
  k -n "$NS_MQ" exec rabbitmq-0 -c rabbitmq -- rabbitmqctl -q list_queues -p "$MQ_VHOST" name durable arguments
  local q
  for q in orders.q orders.dlq; do
    k -n "$NS_MQ" exec rabbitmq-0 -c rabbitmq -- rabbitmqctl -q list_queues -p "$MQ_VHOST" name \
      | grep -qx "$q" || die "Queue $q absente."
  done
  [[ -n "$(k -n "$NS_MQ" get servicemonitor -o name)" ]] || die "Aucun ServiceMonitor RabbitMQ."
  ok "Topologie et ServiceMonitor OK"
}

summary() {
  cat <<EOF

Terminé en ${SECONDS}s.
  Grafana  : kubectl -n $NS_MON port-forward svc/kps-grafana 3000:80
             mdp : kubectl -n $NS_MON get secret grafana-admin -o jsonpath='{.data.admin-password}' | base64 -d
  Prometheus (cible RabbitMQ "up" dans Status > Targets) :
             kubectl -n $NS_MON port-forward svc/prometheus-operated 9090
  RabbitMQ : kubectl -n $NS_MQ port-forward svc/rabbitmq 15672
             user : $MQ_USER / mdp : kubectl -n $NS_MQ get secret rabbitmq-auth -o jsonpath='{.data.rabbitmq-password}' | base64 -d
EOF
}

main() {
  preflight
  install_helm
  ensure_ns "$NS_MON" "$NS_KYV" "$NS_KEDA" "$NS_MQ"
  install_kps
  prepare_rabbitmq
  run_parallel deploy_kyverno deploy_keda deploy_rabbitmq
  verify
  summary
}

main "$@"