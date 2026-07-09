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

# coturn shared secret (voice/video). Derived from the same source of truth so
# it always matches Synapse's turn_shared_secret. Skipped if TURN isn't configured.
TURN_SECRET=$(python3 -c "import yaml; c=yaml.safe_load(open('secret-synapse.yaml')); print(c.get('turn_shared_secret',''))")
if [ -n "$TURN_SECRET" ]; then
  kubectl -n matrix create secret generic coturn-secret \
    --from-literal=TURN_SECRET="${TURN_SECRET}" \
    --dry-run=client -o yaml | kubectl apply -f -
  echo "✓ coturn-secret applied"
fi

# matrix-registration config (contains registration + admin API secrets).
# Mounted at /config/config.yaml. Optional — skipped if the file is absent.
if [ -f ./registration-config.yaml ]; then
  kubectl -n matrix create secret generic matrix-registration-config \
    --from-file=config.yaml=./registration-config.yaml \
    --dry-run=client -o yaml | kubectl apply -f -
  echo "✓ matrix-registration-config applied"
fi

echo "✓ matrix-postgres-secret and synapse-secrets applied to namespace 'matrix'"
