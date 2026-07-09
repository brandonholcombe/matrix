# Kodloki Chat — self-hosted Matrix (Synapse + Element)

A private, **non-federated** Matrix homeserver for <100 users, with real
end-to-end encryption and first-class mobile apps (Element / Element X on
iOS & Android). Deploys to the shared LKE cluster `tow-c1` under kodloki
conventions (ingress-nginx, cert-manager `letsencrypt-prod`,
`linode-block-storage-retain`, ArgoCD-watched, hosts on `*.kodloki.io`).

## What's in the box

| Component | Kind | Host | Notes |
|-----------|------|------|-------|
| Synapse (homeserver) | StatefulSet + 20Gi PVC | `matrix.kodloki.io` | Federation OFF, registration token-gated |
| Postgres 16 | StatefulSet + 10Gi PVC | internal | C-collation DB Synapse requires |
| Element web | Deployment | `element.kodloki.io` | Browser client; `Kodloki Chat` brand |
| coturn (optional) | Deployment (hostNetwork) | node IP | Voice/video; `K8s/optional/`, not auto-synced |

**Server name is `matrix.kodloki.io`** → user IDs look like
`@you:matrix.kodloki.io`. This is permanent; don't change it after go-live.

## Design choices (closed island)

- `federation_domain_whitelist: []` — no traffic to/from other Matrix servers.
- `enable_registration: false` + `registration_requires_token: true` — the
  only way to get an account is an admin-minted one-time token.
- `encryption_enabled_by_default_for_room_type: invite` — E2EE is **on by
  default** for every private room and DM.
- `trusted_key_servers: []` — we never phone home to matrix.org.

## Deploy

Secrets are kept out of git (see `.gitignore`); everything else is GitOps.

```bash
export KUBECONFIG=~/.kube/linode-config

# 1) DNS — point both hosts at the cluster LoadBalancer
#    A  matrix.kodloki.io   -> 172.232.176.47
#    A  element.kodloki.io  -> 172.232.176.47

# 2) Create the two secrets (namespace is auto-created by the script)
cd matrix/K8s && ./apply-secrets.sh

# 3) Register the ArgoCD app (or `kubectl apply -f matrix/argocd/matrix-app.yaml`)
kubectl apply -f matrix/argocd/matrix-app.yaml
```

ArgoCD will sync Postgres → Synapse (initContainer generates the signing key
on the PVC) → Element, and cert-manager issues both TLS certs.

## Onboard users (token-gated registration)

Create an admin, then mint one-time registration tokens for everyone else.

```bash
POD=$(kubectl -n matrix get pod -l app=synapse -o name | head -1)

# First user as admin (uses registration_shared_secret from the mounted config)
kubectl -n matrix exec -it "$POD" -- \
  register_new_matrix_user -c /secrets/secrets.yaml -c /config/homeserver.yaml \
  http://localhost:8008 -a

# Then mint registration tokens via the Admin API (needs the admin's access token):
#   POST /_synapse/admin/v1/registration_tokens/new  { "uses_allowed": 1 }
# Hand each token to a user; they self-register in the app with it.
```

## Clients

- **Mobile:** users install **Element X** (or classic Element) from the App
  Store / Play Store, choose "Other homeserver", enter `matrix.kodloki.io`.
- **Web:** `https://element.kodloki.io` (already pre-pointed at the homeserver).
- **Desktop:** Element desktop, same homeserver.

There is no separate "Kodloki" app in the stores — that would require building
and publishing white-labeled apps (Apple/Google dev accounts, review). Element
pointed at your server is the supported path.

## Voice / video (optional, fiddly)

Text + media chat works with zero extra setup. Calls need a TURN server:

1. `kubectl apply -f K8s/optional/coturn-secret.example.yaml` (with real secret).
2. `kubectl apply -f K8s/optional/coturn.yaml`.
3. Open `3478/udp+tcp` and `49160-49200/udp` to the coturn node in the Linode
   Cloud Firewall.
4. Add the `turn_uris` / `turn_shared_secret` block (see `coturn.yaml` header)
   to `secret-synapse.yaml` and re-run `apply-secrets.sh`; restart Synapse.

## Known limitations (Matrix, honest list)

- **Synapse is resource-hungry** relative to user count; Postgres is the main
  ops burden (backups, upgrades).
- **"Unable to decrypt"** can happen if a user loses their device/keys without
  a set-up key backup. Encourage Secure Backup on first login.
- **coturn on LKE is manual** (firewall + node IP), per above.
- E2EE key history and cross-signing are per-device; onboarding users should
  verify their sessions.

## Push notifications

Element's own push gateway (sygnal, via the Element apps) handles push for the
public Element apps out of the box — no Rocket.Chat-style monthly cap. If you
later ship white-labeled apps you'd self-host sygnal; not needed for stock
Element.
