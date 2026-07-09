#!/usr/bin/env bash
# Applies the two Secrets that are kept OUT of git (ArgoCD deploys everything
# else). Run once before/after the first ArgoCD sync. Idempotent.
#
# Single source of truth for all real secret values is the gitignored
# ./secret-synapse.yaml. This script derives everything from it — it contains
# NO secrets itself, so it is safe to commit to a public repo.
set -euo pipefail
cd "$(dirname "$0")"

export KUBECONFIG="${KUBECONFIG:-$HOME/.kube/linode-config}"

if [ ! -f ./secret-synapse.yaml ]; then
  echo "ERROR: K8s/secret-synapse.yaml not found." >&2
  echo "Copy secret-synapse.example.yaml's inner block to secret-synapse.yaml and fill in real values." >&2
  exit 1
fi

# Pull the Postgres password out of the gitignored secrets file so it is never
# duplicated (or hardcoded) anywhere tracked by git.
PG_PASSWORD=$(python3 -c "import yaml,sys; print(yaml.safe_load(open('secret-synapse.yaml'))['database']['args']['password'])")

kubectl get namespace matrix >/dev/null 2>&1 || kubectl create namespace matrix

# Postgres password (consumed by the postgres StatefulSet env).
kubectl -n matrix create secret generic matrix-postgres-secret \
  --from-literal=POSTGRES_PASSWORD="${PG_PASSWORD}" \
  --dry-run=client -o yaml | kubectl apply -f -

# Synapse merged secret config (mounted at /secrets/secrets.yaml).
kubectl -n matrix create secret generic synapse-secrets \
  --from-file=secrets.yaml=./secret-synapse.yaml \
  --dry-run=client -o yaml | kubectl apply -f -

echo "✓ matrix-postgres-secret and synapse-secrets applied to namespace 'matrix'"
