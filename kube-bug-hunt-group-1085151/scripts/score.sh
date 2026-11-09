#!/usr/bin/env bash
set -euo pipefail
pass=true
echo "[CHECK] Nœuds k3s..."
kubectl get nodes || pass=false
echo "[CHECK] Kyverno..."
kubectl -n kyverno get deploy kyverno-admission-controller || pass=false
echo "[CHECK] KEDA..."
kubectl -n keda get deploy keda-operator || pass=false
echo "[CHECK] Prometheus/Grafana..."
kubectl -n ops get svc | grep -E 'prometheus|grafana' || pass=false
echo "[CHECK] RabbitMQ..."
kubectl -n messaging get statefulset | grep rabbitmq || pass=false
echo "[CHECK] PSS labels sur ns app..."
kubectl get ns app -o jsonpath='{.metadata.labels.pod-security\.kubernetes\.io/enforce}' | grep restricted || pass=false
if $pass; then echo "[OK] Score minimal atteint"; else echo "[WARN] Des éléments manquent"; exit 1; fi
