#!/usr/bin/env bash
set -euo pipefail

BASE_URL="${1:-${BASE_URL:-http://localhost:8080}}"
EVENT_ID="${EVENT_ID:-show-2026}"
WAIT_SECONDS="${WAIT_SECONDS:-90}"

failures=0
body_file="$(mktemp)"
trap 'rm -f "$body_file"' EXIT

request() {
  local method="$1" path="$2" payload="${3:-}"
  local args=(-s -o "$body_file" -w '%{http_code}' -X "$method" --max-time 30)
  if [[ -n "$payload" ]]; then
    args+=(-H 'Content-Type: application/json' -d "$payload")
  fi
  curl "${args[@]}" "$BASE_URL$path" || echo "000"
}

check() {
  local description="$1" expected="$2" method="$3" path="$4" payload="${5:-}"
  local status
  status="$(request "$method" "$path" "$payload")"
  if [[ "$status" == "$expected" ]]; then
    printf 'OK    %-55s %s\n' "$description" "$status"
  else
    printf 'FALHA %-55s esperado %s, recebido %s\n' "$description" "$expected" "$status"
    printf '      resposta: %s\n' "$(head -c 300 "$body_file")"
    failures=$((failures + 1))
  fi
}

echo "Aguardando o gateway em $BASE_URL (até ${WAIT_SECONDS}s)..."
deadline=$((SECONDS + WAIT_SECONDS))
until [[ "$(request GET /contratos/ready)" == "200" && "$(request GET /flash-sales/ready)" == "200" ]]; do
  if (( SECONDS >= deadline )); then
    echo "As APIs não ficaram prontas a tempo."
    exit 1
  fi
  sleep 3
done

echo
echo "Gateway"
check "GET /healthz" 200 GET /healthz
check "Rota inexistente retorna 404" 404 GET /nao-existe

echo
echo "API de Contratos"
check "GET /contratos/health" 200 GET /contratos/health
check "GET /contratos/ready" 200 GET /contratos/ready
check "POST /contratos/contracts cria contrato" 201 POST /contratos/contracts \
  '{"title":"Contrato smoke test","userId":"smoke-user","description":"Criado pelo smoke test","value":1500.50}'
check "POST /contratos/contracts sem campos obrigatórios" 400 POST /contratos/contracts '{"description":"incompleto"}'
check "GET /contratos/metrics bloqueado no gateway" 404 GET /contratos/metrics

echo
echo "API de Flash Sales"
check "GET /flash-sales/health" 200 GET /flash-sales/health
check "GET /flash-sales/ready" 200 GET /flash-sales/ready
check "POST /flash-sales/checkout compra 1 ingresso" 201 POST /flash-sales/checkout \
  "{\"eventId\":\"$EVENT_ID\",\"userId\":\"smoke-user\",\"quantity\":1}"
check "POST /flash-sales/checkout acima do estoque" 409 POST /flash-sales/checkout \
  "{\"eventId\":\"$EVENT_ID\",\"userId\":\"smoke-user\",\"quantity\":100000000}"
check "POST /flash-sales/checkout evento inexistente" 409 POST /flash-sales/checkout \
  '{"eventId":"evento-inexistente","userId":"smoke-user","quantity":1}'
check "POST /flash-sales/checkout sem campos obrigatórios" 400 POST /flash-sales/checkout '{"userId":"smoke-user"}'
check "POST /flash-sales/tickets/export (1000 registros)" 200 POST /flash-sales/tickets/export '{"records":1000}'
check "GET /flash-sales/metrics bloqueado no gateway" 404 GET /flash-sales/metrics

echo
if (( failures > 0 )); then
  echo "$failures verificação(ões) falharam."
  exit 1
fi
echo "Todas as verificações passaram."
