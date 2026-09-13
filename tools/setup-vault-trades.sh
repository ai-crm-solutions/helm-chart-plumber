#!/usr/bin/env bash
# Finish the GCP Vault setup for the trades app:
#   * KV/Trades      -> prod database
#   * KV/Trades-Dev  -> dev database
#   * policies + k8s auth roles for the trades / trades-dev namespaces
# Passwords are read from the namespace secrets and never printed.
set -uo pipefail

KCTX=gke_beo-crm-3c9771fd_us-central1-a_beo-gke
KT=$(kubectl --context "$KCTX" -n vault exec vault-0 -- cat /home/vault/.vault-token)
GPOD=$(kubectl --context "$KCTX" -n vault get pod vault-0 -o jsonpath='{.metadata.name}')
TMP=$(mktemp -d); chmod 700 "$TMP"; trap 'rm -rf "$TMP"' EXIT

vault_get() { kubectl --context "$KCTX" -n vault exec "$GPOD" -- env VAULT_TOKEN="$KT" vault kv get -format=json "KV/$1"; }
# KV v2 wraps the payload as {data:{data:{...}}}. Read the flat map, never the envelope.
vault_flat() { vault_get "$1" | python3 -c "import json,sys; d=json.load(sys.stdin); print(json.dumps((d.get('data') or {}).get('data') or {}))"; }
vault_put() { # $1 path, $2 file
  kubectl --context "$KCTX" -n vault cp "$2" "$GPOD":/tmp/put.json >/dev/null 2>&1
  kubectl --context "$KCTX" -n vault exec "$GPOD" -- env VAULT_TOKEN="$KT" vault kv put "KV/$1" @/tmp/put.json >/dev/null 2>&1 && echo "   ✓ KV/$1" || echo "   ✗ KV/$1 FAILED"
  kubectl --context "$KCTX" -n vault exec "$GPOD" -- rm -f /tmp/put.json >/dev/null 2>&1
}

echo "=== secrets: prod + dev database URLs ==="
for env in prod dev; do
  if [ "$env" = "prod" ]; then ns=trades; path=Trades; host=postgres.trades.svc.cluster.local; sec=postgres-trades;
  else ns=trades-dev; path=Trades-Dev; host=postgres.trades-dev.svc.cluster.local; sec=postgres-trades-dev; fi
  PW=$(kubectl --context "$KCTX" -n "$ns" get secret "$sec" -o jsonpath='{.data.POSTGRES_PASSWORD}' | base64 -d)
  vault_flat Plumber > "$TMP/$path.json"
  python3 - "$TMP/$path.json" "$PW" "$host" <<'PY'
import json, sys
f, pw, host = sys.argv[1], sys.argv[2], sys.argv[3]
d = json.load(open(f))
d["DATABASE_URL"] = f"postgresql+psycopg2://trades:{pw}@{host}:5432/trades"
json.dump(d, open(f, "w"))
PY
  echo "  $path -> $host"
  vault_put "$path" "$TMP/$path.json"
done

echo
echo "=== Vault policies ==="
for p in trades-app trades-dev-app; do
  case "$p" in trades-app) kv="Trades";; *) kv="Trades-Dev";; esac
  cat > "$TMP/$p.hcl" <<EOF
path "KV/data/$kv" { capabilities = ["read", "list"] }
path "KV/data/$kv/*" { capabilities = ["read", "list"] }
EOF
  kubectl --context "$KCTX" -n vault cp "$TMP/$p.hcl" "$GPOD":/tmp/p.hcl >/dev/null 2>&1
  kubectl --context "$KCTX" -n vault exec "$GPOD" -- env VAULT_TOKEN="$KT" vault policy write "$p" /tmp/p.hcl >/dev/null 2>&1 && echo "   ✓ policy $p (read KV/data/$kv)"
  kubectl --context "$KCTX" -n vault exec "$GPOD" -- rm -f /tmp/p.hcl >/dev/null 2>&1
done

echo
echo "=== kubernetes auth roles ==="
kubectl --context "$KCTX" -n vault exec "$GPOD" -- env VAULT_TOKEN="$KT" vault write auth/kubernetes/role/trades \
  bound_service_account_names='*' bound_service_account_namespaces=trades policies=trades-app token_ttl=86400 >/dev/null 2>&1 \
  && echo "   ✓ role trades  (ns trades -> trades-app)"
kubectl --context "$KCTX" -n vault exec "$GPOD" -- env VAULT_TOKEN="$KT" vault write auth/kubernetes/role/trades-dev \
  bound_service_account_names='*' bound_service_account_namespaces=trades-dev policies=trades-dev-app token_ttl=86400 >/dev/null 2>&1 \
  && echo "   ✓ role trades-dev (ns trades-dev -> trades-dev-app)"

echo
echo "=== verification (key names only) ==="
for p in Trades Trades-Dev; do
  printf "  %-12s " "$p"
  vault_get "$p" | python3 -c "
import json,sys
d=json.load(sys.stdin); data=(d.get('data') or {}).get('data') or {}
u=data.get('DATABASE_URL','')
import re
m=re.search(r'@([^/]+)/', u)
print(f\"{len(data)} keys | db host: {m.group(1) if m else 'n/a'}\")"
done
echo "  roles:"; kubectl --context "$KCTX" -n vault exec "$GPOD" -- env VAULT_TOKEN="$KT" vault list auth/kubernetes/role 2>/dev/null | tail -n +3 | sort | tr '\n' ' '; echo
