#!/usr/bin/env bash
# install-k3s.sh — installe k3s sur une VM du lab (Debian 12).
#
#   VM1 (server) : sudo bash install-k3s.sh server vm1
#   VM2/VM3      : sudo K3S_TOKEN=<token> bash install-k3s.sh agent vm2
#
# Les IP viennent de lab.env (copie de lab.env.example, ignorée par git).
# Le token s'affiche à la fin de l'installation du server.
# Ensuite, sur VM1 : sudo bash scripts/k3s-stack.sh
set -Eeuo pipefail

readonly K3S_VERSION="${K3S_VERSION:-v1.37.2+k3s1}"

die() { printf '[ERREUR] %s\n' "$*" >&2; exit 1; }

[[ $EUID -eq 0 ]] || die "Lancer avec sudo."
[[ $# -eq 2 ]] || die "Usage : $0 server|agent <nom-du-noeud>"
role=$1 node=$2

LAB_ENV="$(dirname "${BASH_SOURCE[0]}")/../lab.env"
if [[ -r $LAB_ENV ]]; then
  # shellcheck source=/dev/null
  source "$LAB_ENV"
fi

# L'image des VM nomme chaque machine « localhost » au boot : on fixe le nom.
hostnamectl set-hostname "$node"
if [[ -d /etc/cloud ]]; then
  echo "preserve_hostname: true" >/etc/cloud/cloud.cfg.d/99-hostname.cfg
fi

export INSTALL_K3S_VERSION="$K3S_VERSION"
case "$role" in
  server)
    # traefik et servicelb inutiles : aucune exposition, accès par port-forward.
    curl -sfL https://get.k3s.io | sh -s - server \
      --node-name "$node" --disable traefik --disable servicelb \
      --write-kubeconfig-mode 600
    printf '\nk3s server prêt. Token pour les agents :\n'
    cat /var/lib/rancher/k3s/server/node-token
    ;;
  agent)
    if [[ -z ${K3S_URL:-} && -n ${VM1_IP:-} ]]; then
      export K3S_URL="https://${VM1_IP}:6443"
    fi
    [[ -n ${K3S_URL:-} ]] || die "VM1_IP absent de lab.env (ou K3S_URL non défini)."
    [[ -n ${K3S_TOKEN:-} ]] || die "K3S_TOKEN requis pour un agent."
    curl -sfL https://get.k3s.io | sh -s - agent --node-name "$node"
    echo "Agent $node installé. Vérifier sur VM1 : sudo k3s kubectl get nodes"
    ;;
  *) die "Rôle inconnu : $role (server ou agent)" ;;
esac
