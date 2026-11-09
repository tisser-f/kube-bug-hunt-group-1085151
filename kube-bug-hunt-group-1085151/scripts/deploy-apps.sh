#!/usr/bin/env bash
# deploy-apps.sh — déploie orders-api + worker (namespace app) puis teste la chaîne de bout en bout.
# Usage : sudo bash scripts/deploy-apps.sh   (après k3s-stack.sh)
set -Eeuo pipefail
export KUBECONFIG="${KUBECONFIG:-/etc/rancher/k3s/k3s.yaml}"

readonly NS="app"
readonly MANIFEST="$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd)/lab/d-messaging/apps.yaml"
readonly PF_PORT=18080
PF_PID=""

log() { printf '\033[1;34m[%(%H:%M:%S)T] %s\033[0m\n' -1 "$*"; }
ok()  { printf '\033[1;32m[OK] %s\033[0m\n' "$*"; }
die() { printf '\033[1;31m[ERREUR] %s\033[0m\n' "$*" >&2; exit 1; }
trap '[[ -n $PF_PID ]] && kill "$PF_PID" 2>/dev/null || true' EXIT

rmq() { kubectl -n messaging exec rabbitmq-0 -c rabbitmq -- rabbitmqctl -q "$@"; }
# awk lit toute la sortie : pas de SIGPIPE avec pipefail.
depth() { rmq list_queues -p /orders name messages | awk -v q="$1" '$1==q {print $2}'; }

# ---------- 0. Prérequis ----------
[[ $EUID -eq 0 ]] || die "Lancer avec sudo."
[[ -r $MANIFEST ]] || die "Manifeste introuvable : $MANIFEST"
kubectl get ns "$NS" >/dev/null 2>&1 || die "Namespace $NS absent : lancer k3s-stack.sh d'abord."

# ---------- 1. Déploiement ----------
log "Application de $MANIFEST"
kubectl apply -f "$MANIFEST"
# Le code est dans une ConfigMap : redémarrage pour charger la dernière version.
kubectl -n "$NS" rollout restart deploy/orders-api deploy/worker >/dev/null
for d in orders-api worker; do
  kubectl -n "$NS" rollout status "deploy/$d" --timeout=180s || die "$d pas prêt. Voir : kubectl -n $NS logs deploy/$d"
done
ok "orders-api et worker prêts"

# ---------- 2. Test de bout en bout ----------
kubectl -n "$NS" port-forward svc/orders-api "$PF_PORT:80" >/dev/null 2>&1 &
PF_PID=$!
for _ in $(seq 1 15); do
  curl -fsS "http://127.0.0.1:$PF_PORT/healthz" >/dev/null 2>&1 && break
  sleep 1
done
curl -fsS "http://127.0.0.1:$PF_PORT/healthz" >/dev/null || die "orders-api injoignable via port-forward."

dlq_before="$(depth orders.dlq)"

log "Envoi d'une commande valide"
resp="$(curl -fsS -X POST -H 'Content-Type: application/json' \
  -d '{"item":"test","qty":1}' "http://127.0.0.1:$PF_PORT/orders")" || die "POST /orders en échec."
id="$(sed -n 's/.*"id": *"\([^"]*\)".*/\1/p' <<<"$resp")"
[[ -n $id ]] || die "Réponse inattendue : $resp"

log "Envoi d'un message invalide (doit finir en DLQ)"
curl -fsS -X POST --data 'pas-du-json' "http://127.0.0.1:$PF_PORT/orders?raw=1" >/dev/null \
  || die "POST /orders?raw=1 en échec."

sleep 3
logs="$(kubectl -n "$NS" logs deploy/worker --since=5m)"
grep -qF "[OK] commande traitée : $id" <<<"$logs" || die "Commande $id non traitée par le worker."
ok "Commande $id consommée par le worker"

dlq_after="$(depth orders.dlq)"
(( dlq_after > dlq_before )) || die "DLQ inchangée ($dlq_before -> $dlq_after)."
ok "Message invalide routé vers orders.dlq ($dlq_before -> $dlq_after)"

log "État des queues"
rmq list_queues -p /orders name messages consumers
