#!/usr/bin/env bash
# install-k3s.sh — cluster k3s du lab.
#   deploy                              tout le cluster par SSH (lit ../lab.env)
#   server <nom>                        sur VM1, en sudo
#   agent <nom> <IP_VM1> <fichier_token> sur VM2/VM3, en sudo
set -Eeuo pipefail

readonly K3S_VERSION="${K3S_VERSION:-v1.37.2+k3s1}"
readonly TOKEN_PATH=/var/lib/rancher/k3s/server/node-token

die() { printf '[ERREUR] %s\n' "$*" >&2; exit 1; }
log() { printf '\n\033[1;34m==> %s\033[0m\n' "$*"; }

# Les VM démarrent en « localhost ».
set_hostname() {
  hostnamectl set-hostname "$1"
  if [[ -d /etc/cloud ]]; then
    echo "preserve_hostname: true" >/etc/cloud/cloud.cfg.d/99-hostname.cfg
  fi
}

install_server() {
  local node=$1
  set_hostname "$node"
  # Aucune exposition : accès par port-forward.
  curl -sfL https://get.k3s.io | INSTALL_K3S_VERSION="$K3S_VERSION" sh -s - server \
    --node-name "$node" --disable traefik --disable servicelb --write-kubeconfig-mode 600
  echo "Server $node prêt. Token des agents : $TOKEN_PATH"
}

install_agent() {
  local node=$1 server_ip=$2 token_file=$3
  [[ -r $token_file ]] || die "Fichier token illisible : $token_file"
  set_hostname "$node"
  # K3S_* est recopié dans le service : la valeur, pas un fichier temporaire.
  local token
  token="$(<"$token_file")"
  curl -sfL https://get.k3s.io | INSTALL_K3S_VERSION="$K3S_VERSION" \
    K3S_URL="https://${server_ip}:6443" K3S_TOKEN="$token" sh -s - agent --node-name "$node"
  echo "Agent $node installé."
}

# Variables ssh développées côté client, volontairement.
# shellcheck disable=SC2029
deploy() {
  local env_file self i ip user
  env_file="$(dirname "${BASH_SOURCE[0]}")/../lab.env"
  [[ -r $env_file ]] || die "lab.env introuvable (copier lab.env.example)."
  # shellcheck source=/dev/null
  source "$env_file"
  for i in 1 2 3; do
    ip="VM${i}_IP"; user="VM${i}_USER"
    [[ -n ${!ip:-} && -n ${!user:-} ]] || die "$ip ou $user manquant dans lab.env."
  done

  self="$(realpath "${BASH_SOURCE[0]}")"
  tmp="$(mktemp -d)"   # global pour le trap EXIT
  trap 'rm -rf "${tmp:-}"' EXIT

  log "vm1 ($VM1_IP) : installation du server"
  scp -q "$self" "$VM1_USER@$VM1_IP:install-k3s.sh"
  # -t pour sudo ; token copié en 600 pour le récupérer sans sudo.
  ssh -t "$VM1_USER@$VM1_IP" "sudo bash install-k3s.sh server vm1 \
    && sudo install -m 600 -o $VM1_USER $TOKEN_PATH .k3s-token"
  scp -q "$VM1_USER@$VM1_IP:.k3s-token" "$tmp/token"
  ssh "$VM1_USER@$VM1_IP" "rm -f .k3s-token install-k3s.sh"

  for i in 2 3; do
    ip="VM${i}_IP"; user="VM${i}_USER"
    log "vm$i (${!ip}) : installation de l'agent"
    scp -q "$self" "$tmp/token" "${!user}@${!ip}:"
    ssh -t "${!user}@${!ip}" "sudo bash install-k3s.sh agent vm$i $VM1_IP token; \
      rc=\$?; rm -f install-k3s.sh token; exit \$rc"
  done

  log "Vérification des nœuds"
  ssh -t "$VM1_USER@$VM1_IP" "sudo k3s kubectl get nodes -o wide"
}

case "${1:-}" in
  deploy) deploy ;;
  server|agent)
    [[ $EUID -eq 0 ]] || die "Lancer avec sudo."
    if [[ $1 == server ]]; then
      [[ $# -eq 2 ]] || die "Usage : $0 server <nom>"
      install_server "$2"
    else
      [[ $# -eq 4 ]] || die "Usage : $0 agent <nom> <IP_server> <fichier_token>"
      install_agent "$2" "$3" "$4"
    fi
    ;;
  *) die "Usage : $0 deploy | server <nom> | agent <nom> <IP_server> <fichier_token>" ;;
esac
