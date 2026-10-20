#!/usr/bin/env bash
set -euo pipefail

ROOT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd)"
TARGET="${1:-compose}"
CLUSTER_NAME="${CLUSTER_NAME:-atividade-devops}"
DURATION="${DURATION:-2m}"

case "$TARGET" in
  compose)
    network="atividade-devops_frontend"
    base_url="http://gateway:8080"
    ;;
  k8s)
    network="kind"
    base_url="http://${CLUSTER_NAME}-control-plane:30080"
    ;;
  *)
    echo "Uso: $0 [compose|k8s]" >&2
    exit 1
    ;;
esac

if ! docker network inspect "$network" >/dev/null 2>&1; then
  echo "Rede Docker '$network' não encontrada. O ambiente '$TARGET' está no ar?" >&2
  exit 1
fi

echo "Teste de carga no ambiente '$TARGET' ($base_url): rampa de 30s e $DURATION no pico"
echo "Pico: ${CONTRATOS_RPS:-20} req/s em contratos, ${CHECKOUT_RPS:-40} req/s em checkout, ${EXPORT_VUS:-1} exportação(ões) contínua(s)"

docker run --rm -i \
  --network "$network" \
  -e BASE_URL="$base_url" \
  -e DURATION="$DURATION" \
  -e CONTRATOS_RPS="${CONTRATOS_RPS:-20}" \
  -e CHECKOUT_RPS="${CHECKOUT_RPS:-40}" \
  -e EXPORT_VUS="${EXPORT_VUS:-1}" \
  -e EXPORT_RECORDS="${EXPORT_RECORDS:-200000}" \
  grafana/k6:0.55.0 run - < "$ROOT_DIR/tests/load/load-test.js"
