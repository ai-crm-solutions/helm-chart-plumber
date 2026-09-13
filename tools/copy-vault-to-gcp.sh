#!/usr/bin/env bash
# Copy every secret from the on-prem Vault into the GCP Vault.
#   * BEO / BEO-DEV are SKIPPED (the GCP copies are live production for BEO)
#   * values are streamed through private temp files and never printed
#   * Plumber is also written as "Trades" (the new product name) with DATABASE_URL
#     repointed at the new GCP Postgres
set -uo pipefail

OP=kubernetes-admin@kubernetes
KCTX=gke_beo-crm-3c9771fd_us-central1-a_beo-gke

OT=$(kubectl --context "$OP" -n vault exec vault-0 -- cat /home/vault/.vault-token)
KT=$(kubectl --context "$KCTX" -n vault exec vault-0 -- cat /home/vault/.vault-token)
GPOD=$(kubectl --context "$KCTX" -n vault get pod vault-0 -o jsonpath='{.metadata.name}')

# NOTE: Joinery is deliberately NOT copied - it is not deployed on GCP.
#       KV/Trades and KV/Trades-Dev are produced by tools/setup-vault-trades.sh
#       (they need a rewritten DATABASE_URL for the new GCP Postgres).
SKIP="BEO BEO-DEV"
PATHS="AI Cleaners Clothing Events GB Plumber Salon Salon-Omnirai Stripe TicketingMate aiworkflowsolutions chat-db postgres"

TMP=$(mktemp -d); chmod 700 "$TMP"
trap 'rm -rf "$TMP"' EXIT

read_kv() {  # $1 = path on the on-prem vault
  kubectl --context "$OP" -n vault exec vault-0 -- env VAULT_TOKEN="$OT" \
    vault kv get -format=json "KV/$1" 2>/dev/null \
  | python3 -c "import json,sys; d=json.load(sys.stdin); print(json.dumps((d.get('data') or {}).get('data') or {}))"
}

write_kv() {  # $1 = path on the GCP vault, $2 = local json file
  kubectl --context "$KCTX" -n vault cp "$2" "$GPOD":/tmp/put.json >/dev/null 2>&1
  kubectl --context "$KCTX" -n vault exec "$GPOD" -- env VAULT_TOKEN="$KT" \
    vault kv put "KV/$1" @/tmp/put.json >/dev/null 2>&1 && echo "   ✓ KV/$1" || echo "   ✗ KV/$1 FAILED"
  kubectl --context "$KCTX" -n vault exec "$GPOD" -- rm -f /tmp/put.json >/dev/null 2>&1
}

echo "=== copying secrets to the GCP Vault ==="
for p in $PATHS; do
  case " $SKIP " in *" $p "*) echo "   - $p SKIPPED (live on GCP)"; continue;; esac
  if read_kv "$p" > "$TMP/x.json" && [ -s "$TMP/x.json" ] && [ "$(cat "$TMP/x.json")" != "{}" ]; then
    write_kv "$p" "$TMP/x.json"
  else
    echo "   ✗ $p could not be read"
  fi
done

echo
echo "=== Trades (new name for Plumber, DATABASE_URL -> GCP Postgres) ==="
PGPASS=$(kubectl --context "$KCTX" -n trades-dev get secret postgres-trades-dev -o jsonpath='{.data.POSTGRES_PASSWORD}' 2>/dev/null | base64 -d)
if [ -z "$PGPASS" ]; then
  echo "   ✗ postgres-trades-dev secret missing — run the Postgres step first"; exit 1
fi
read_kv Plumber > "$TMP/trades.json"
python3 - "$TMP/trades.json" "$PGPASS" <<'PY'
import json, sys
path, pw = sys.argv[1], sys.argv[2]
d = json.load(open(path))
d["DATABASE_URL"] = f"postgresql+psycopg2://trades:{pw}@postgres.trades-dev.svc.cluster.local:5432/trades"
json.dump(d, open(path, "w"))
print("   keys:", ", ".join(sorted(d.keys())))
PY
write_kv Trades "$TMP/trades.json"

echo
echo "=== separate 'Joinery/' mount on the on-prem Vault ==="
echo "   (not copied to GCP - joinery is not deployed there)"
  kubectl --context "$OP" -n vault exec vault-0 -- env VAULT_TOKEN="$OT" vault kv list Joinery 2>/dev/null | tail -n +3 | sed 's/^/   /' | head -10

echo
echo "=== GCP Vault KV contents now ==="
kubectl --context "$KCTX" -n vault exec "$GPOD" -- env VAULT_TOKEN="$KT" vault kv list KV 2>/dev/null | tail -n +3 | sort | tr '\n' ' '; echo
