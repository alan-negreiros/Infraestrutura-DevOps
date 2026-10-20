#!/usr/bin/env bash
set -euo pipefail

NAMESPACE="${NAMESPACE:-apis}"
POD="teste-isolamento-rede"

cleanup() {
  kubectl -n "$NAMESPACE" delete pod "$POD" --ignore-not-found --wait=false >/dev/null 2>&1 || true
}
trap cleanup EXIT

kubectl -n "$NAMESPACE" delete pod "$POD" --ignore-not-found --wait=true >/dev/null
kubectl -n "$NAMESPACE" apply -f - >/dev/null <<'EOF'
apiVersion: v1
kind: Pod
metadata:
  name: teste-isolamento-rede
  labels:
    app.kubernetes.io/name: teste-isolamento-rede
spec:
  restartPolicy: Never
  automountServiceAccountToken: false
  securityContext:
    runAsNonRoot: true
    runAsUser: 1000
    runAsGroup: 1000
    seccompProfile:
      type: RuntimeDefault
  containers:
    - name: teste
      image: postgres:17-alpine
      command:
        - sh
        - -c
        - |
          probe() {
            if sh -c "$2" >/dev/null 2>&1; then echo "$1=aberto"; else echo "$1=bloqueado"; fi
          }
          probe gateway "wget -qO- -T 5 http://gateway:8080/healthz"
          probe contratos "wget -qO- -T 5 http://contratos:3000/health"
          probe flash-sales "wget -qO- -T 5 http://flash-sales:3000/health"
          probe postgres "pg_isready -h postgres -U postgres -t 5"
          probe redis "printf 'PING\r\n' | nc -w 5 redis 6379 | grep -qE 'NOAUTH|PONG'"
      resources:
        requests:
          cpu: 10m
          memory: 16Mi
        limits:
          cpu: 100m
          memory: 64Mi
      securityContext:
        allowPrivilegeEscalation: false
        readOnlyRootFilesystem: true
        capabilities:
          drop: ["ALL"]
EOF

kubectl -n "$NAMESPACE" wait --for=jsonpath='{.status.phase}'=Succeeded "pod/$POD" --timeout=120s >/dev/null
result="$(kubectl -n "$NAMESPACE" logs "$POD")"

echo "Conexões a partir de um pod sem permissões no namespace $NAMESPACE:"
failures=0
while IFS='=' read -r target expected; do
  actual="$(grep "^$target=" <<<"$result" | cut -d= -f2)"
  if [[ "$actual" == "$expected" ]]; then
    printf 'OK    %-12s %s\n' "$target" "$actual"
  else
    printf 'FALHA %-12s esperado %s, obtido %s\n' "$target" "$expected" "${actual:-sem resposta}"
    failures=$((failures + 1))
  fi
done <<'EOF'
gateway=aberto
contratos=bloqueado
flash-sales=bloqueado
postgres=bloqueado
redis=bloqueado
EOF

if (( failures > 0 )); then
  echo "As NetworkPolicies não estão sendo aplicadas como esperado."
  exit 1
fi
echo "Isolamento de rede funcionando."
