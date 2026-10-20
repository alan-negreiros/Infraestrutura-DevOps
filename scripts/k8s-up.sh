#!/usr/bin/env bash
set -euo pipefail

ROOT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd)"
CLUSTER_NAME="${CLUSTER_NAME:-atividade-devops}"
MIN_MEMORY_MULTI_NODE=$((6 * 1024 * 1024 * 1024))
NAMESPACE="apis"
OVERLAY_DIR="$ROOT_DIR/k8s/overlays/local"
SECRETS_FILE="$OVERLAY_DIR/secrets.env"
IMAGES=(contratos-api:local flash-sales-api:local)

log() {
  printf '\n==> %s\n' "$*"
}

for cmd in docker kind kubectl openssl; do
  if ! command -v "$cmd" >/dev/null 2>&1; then
    echo "Erro: '$cmd' não encontrado no PATH." >&2
    exit 1
  fi
done

if [[ -z "${KIND_CONFIG:-}" ]]; then
  docker_memory="$(docker info --format '{{.MemTotal}}')"
  if (( docker_memory >= MIN_MEMORY_MULTI_NODE )); then
    KIND_CONFIG="$ROOT_DIR/k8s/kind-cluster.yaml"
  else
    KIND_CONFIG="$ROOT_DIR/k8s/kind-cluster-single-node.yaml"
    echo "Docker com $((docker_memory / 1024 / 1024)) MiB de memória (menos de 6 GiB): usando cluster de nó único."
  fi
fi

if kind get clusters 2>/dev/null | grep -qx "$CLUSTER_NAME"; then
  log "Cluster kind '$CLUSTER_NAME' já existe"
else
  log "Criando cluster kind '$CLUSTER_NAME' a partir de $(basename "$KIND_CONFIG")"
  kind create cluster --name "$CLUSTER_NAME" --config "$KIND_CONFIG"
fi
kubectl config use-context "kind-$CLUSTER_NAME" >/dev/null

log "Instalando o Calico (CNI com suporte a NetworkPolicy)"
kubectl apply --server-side -k "$ROOT_DIR/k8s/addons/calico" >/dev/null
kubectl -n kube-system rollout status daemonset/calico-node --timeout=300s
kubectl wait --for=condition=Ready nodes --all --timeout=300s

log "Instalando o metrics-server (fonte de métricas do HPA)"
kubectl apply -k "$ROOT_DIR/k8s/addons/metrics-server"

if [[ "${SKIP_BUILD:-0}" != "1" ]]; then
  log "Construindo as imagens das APIs"
  docker build -t contratos-api:local "$ROOT_DIR/services/contratos"
  docker build -t flash-sales-api:local "$ROOT_DIR/services/flash-sales"
fi

log "Carregando as imagens nos nós do cluster"
kind load docker-image --name "$CLUSTER_NAME" "${IMAGES[@]}"

if [[ ! -f "$SECRETS_FILE" ]]; then
  log "Gerando senhas aleatórias em k8s/overlays/local/secrets.env"
  for key in POSTGRES_PASSWORD CONTRATOS_DB_PASSWORD FLASH_SALES_DB_PASSWORD REDIS_PASSWORD GRAFANA_ADMIN_PASSWORD; do
    echo "$key=$(openssl rand -hex 16)"
  done > "$SECRETS_FILE"
fi

existing_release="$(kubectl -n "$NAMESPACE" get deployment contratos --ignore-not-found -o name 2>/dev/null || true)"

log "Aplicando os manifestos (overlay local)"
kubectl -n "$NAMESPACE" delete job redis-seed --ignore-not-found >/dev/null 2>&1 || true
kubectl apply -k "$OVERLAY_DIR"

if [[ -n "$existing_release" && "${SKIP_BUILD:-0}" != "1" ]]; then
  log "Reiniciando as APIs para usar as imagens recém-construídas"
  kubectl -n "$NAMESPACE" rollout restart deployment contratos flash-sales flash-sales-export
fi

log "Aguardando os componentes ficarem prontos"
kubectl -n "$NAMESPACE" rollout status statefulset/postgres --timeout=300s
kubectl -n "$NAMESPACE" rollout status statefulset/redis --timeout=300s
for deployment in contratos flash-sales flash-sales-export gateway prometheus grafana; do
  kubectl -n "$NAMESPACE" rollout status "deployment/$deployment" --timeout=300s
done
kubectl -n "$NAMESPACE" wait --for=condition=complete job/redis-seed --timeout=180s

cat <<EOF

Ambiente Kubernetes pronto.
  Gateway (APIs): http://localhost:8081
  Prometheus:     http://localhost:9091
  Grafana:        http://localhost:3001 (usuário admin, senha GRAFANA_ADMIN_PASSWORD em k8s/overlays/local/secrets.env)

Teste rápido: bash tests/smoke/smoke-test.sh http://localhost:8081
EOF
