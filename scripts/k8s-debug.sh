#!/usr/bin/env bash
set -uo pipefail

NAMESPACE="${NAMESPACE:-apis}"

echo "==> Recursos"
kubectl -n "$NAMESPACE" get all,hpa,pdb,pvc,networkpolicy -o wide

echo
echo "==> Eventos recentes"
kubectl -n "$NAMESPACE" get events --sort-by=.lastTimestamp | tail -40

for pod in $(kubectl -n "$NAMESPACE" get pods -o name); do
  echo
  echo "==> Logs de $pod"
  kubectl -n "$NAMESPACE" logs "$pod" --all-containers --tail=50 || true
done
