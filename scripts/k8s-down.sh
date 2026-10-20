#!/usr/bin/env bash
set -euo pipefail

CLUSTER_NAME="${CLUSTER_NAME:-atividade-devops}"

kind delete cluster --name "$CLUSTER_NAME"
