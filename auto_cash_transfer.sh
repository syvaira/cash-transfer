#!/usr/bin/env bash
# AgentWallet CASH auto transfer script
# Requirements: curl, node, python3
# Usage: AGENTWALLET_DEST=... AGENTWALLET_TOKEN=... bash auto_cash_transfer.sh

set -euo pipefail

USERNAME="syvairaa"
DEST="GTxy3MAXM1XMZNfgoruuRgvNjJJ9xasRoj1y5tPyvsac"
CASH_MINT="CASHx9KJUStyftLFWGvEVf59SGeG9sh5FfcnZMVPCASH"
TOKEN_PROG="TokenzQdBNbLqP5VEhdkAS6EPFLC1PHnBqCXEpPxuEb"
RPC="https://api.mainnet-beta.solana.com"
API="https://frames.ag/api"
STATE_FILE="${HOME}/.agentwallet/auto_cash_transfer_state.json"

# Runtime overrides
if [ -n "${AGENTWALLET_USERNAME:-}" ]; then
  USERNAME="$AGENTWALLET_USERNAME"
fi
if [ -n "${AGENTWALLET_DEST:-}" ]; then
  DEST="$AGENTWALLET_DEST"
fi

# Determine API token
if [ -n "${AGENTWALLET_TOKEN:-}" ]; then
  TOKEN="$AGENTWALLET_TOKEN"
elif [ -f "${HOME}/.agentwallet/config.json" ]; then
  TOKEN=$(python3 - <<'PY'
import json, os
path = os.path.expanduser('~/.agentwallet/config.json')
with open(path) as f:
    data = json.load(f)
print(data.get('apiToken',''))
PY
)
else
  echo "ERROR: No AgentWallet token found. Set AGENTWALLET_TOKEN or configure ~/.agentwallet/config.json." >&2
  exit 1
fi

if [ -z "$TOKEN" ]; then
  echo "ERROR: AgentWallet apiToken is empty." >&2
  exit 1
fi

mkdir -p "$(dirname "$STATE_FILE")"

validate_json() {
  python3 - <<'PY'
import json, sys
text = sys.stdin.read()
try:
    json.loads(text)
except Exception as exc:
    sys.stderr.write('ERROR: Invalid JSON response from AgentWallet balances endpoint.\n')
    sys.stderr.write(text + '\n')
    sys.exit(1)
PY
}

load_state() {
  if [ -f "$STATE_FILE" ]; then
    python3 - <<'PY'
import json, pathlib
path = pathlib.Path('${STATE_FILE}')
try:
    data = json.loads(path.read_text())
except Exception:
    data = {}
print(json.dumps(data))
PY
  else
    echo '{}'
  fi
}

save_state() {
  python3 - <<'PY'
import json, pathlib, sys
state = json.loads(sys.argv[1])
path = pathlib.Path('${STATE_FILE}')
path.write_text(json.dumps(state, indent=2))
PY
"$1"
}

STATE_JSON=$(load_state)
LAST_SENT_RAW=$(python3 - <<'PY'
import json, sys
state = json.loads(sys.stdin.read())
print(state.get('lastSentRaw', '0'))
PY
<<<"$STATE_JSON")

printf '\n'
printf '============================================\n'
printf '  AgentWallet CASH Auto Transfer\n'
printf '============================================\n\n'

printf '[1/5] Checking balance...\n'
BALANCE_RESPONSE=$(curl -sS -H "Authorization: Bearer $TOKEN" "$API/wallets/$USERNAME/balances" || true)
if [ -z "$BALANCE_RESPONSE" ]; then
  echo "ERROR: No response from AgentWallet balances endpoint." >&2
  exit 1
fi
validate_json <<<"$BALANCE_RESPONSE"

SOL_ADDR=$(python3 - <<'PY'
import json, sys
obj = json.loads(sys.stdin.read())
solanas = obj.get('solanaWallets') or obj.get('solana')
address = ''
if isinstance(solanas, list) and len(solanas) > 0:
    address = solanas[0].get('address','')
elif isinstance(solanas, dict):
    address = solanas.get('address','')
print(address or '')
PY
<<<"$BALANCE_RESPONSE")

if [ -z "$SOL_ADDR" ]; then
  echo "ERROR: Unable to parse Solana address from balances response." >&2
  exit 1
fi

RAW_VALUE=$(python3 - <<'PY'
import json, sys
obj = json.loads(sys.stdin.read())
solanas = obj.get('solanaWallets') or obj.get('solana')
balances = []
if isinstance(solanas, list) and len(solanas) > 0:
    balances = solanas[0].get('balances', [])
elif isinstance(solanas, dict):
    balances = solanas.get('balances', [])
raw = '0'
for item in balances:
    if item.get('asset','').lower() == 'cash':
        raw = item.get('rawValue', '0')
        break
print(raw)
PY
<<<"$BALANCE_RESPONSE")

if [ -z "$RAW_VALUE" ] || [ "$RAW_VALUE" = "0" ]; then
  echo "No CASH balance available to send. Current raw balance: $RAW_VALUE"
  exit 0
fi

printf '  OK Solana : %s\n' "$SOL_ADDR"
printf '  OK CASH   : %s (raw units)\n' "$RAW_VALUE"

if [ "$RAW_VALUE" = "$LAST_SENT_RAW" ]; then
  echo "Balance is unchanged since last transfer; nothing to do."
  exit 0
fi

printf '[2/5] Fetching source token account...\n'
SRC_JSON=$(curl -s -X POST -H 'Content-Type: application/json' -d "{\"jsonrpc\":\"2.0\",\"id\":1,\"method\":\"getTokenAccountsByOwner\",\"params\":[\"$SOL_ADDR\",{\"mint\":\"$CASH_MINT\"},{\"encoding\":\"jsonParsed\"}]}" "$RPC")
SRC=$(python3 - <<'PY'
import json, sys
obj = json.loads(sys.stdin.read())
value = obj.get('result', {}).get('value', [])
print(value[0].get('pubkey','') if value else '')
PY
<<<"$SRC_JSON")

if [ -z "$SRC" ]; then
  echo "ERROR: Source CASH token account not found for $SOL_ADDR." >&2
  exit 1
fi
printf '  OK Source : %s\n' "$SRC"

printf '[3/5] Fetching destination token account...\n'
DST_JSON=$(curl -s -X POST -H 'Content-Type: application/json' -d "{\"jsonrpc\":\"2.0\",\"id\":1,\"method\":\"getTokenAccountsByOwner\",\"params\":[\"$DEST\",{\"mint\":\"$CASH_MINT\"},{\"encoding\":\"jsonParsed\"}]}" "$RPC")
DST=$(python3 - <<'PY'
import json, sys
obj = json.loads(sys.stdin.read())
value = obj.get('result', {}).get('value', [])
print(value[0].get('pubkey','') if value else '')
PY
<<<"$DST_JSON")

if [ -z "$DST" ]; then
  echo "ERROR: Destination CASH token account not found for $DEST." >&2
  echo "The recipient must already have a CASH token account." >&2
  exit 1
fi
printf '  OK Dest   : %s\n' "$DST"

printf '[4/5] Encoding instruction data...\n'
DATA=$(node - <<'NODE'
const raw = BigInt($RAW_VALUE);
const buf = Buffer.alloc(10);
buf[0] = 12;
let value = raw;
for (let i = 0; i < 8; i++) {
  buf[1 + i] = Number(value & 0xffn);
  value >>= 8n;
}
buf[9] = 6;
process.stdout.write(buf.toString('base64'));
NODE
)

if [ -z "$DATA" ]; then
  echo "ERROR: Failed to encode instruction data." >&2
  exit 1
fi
printf '  OK Data   : %s\n' "$DATA"

printf '[5/5] Broadcasting transaction...\n'
TX=$(curl -s -X POST "$API/wallets/$USERNAME/actions/contract-call" \
  -H "Authorization: Bearer $TOKEN" \
  -H "Content-Type: application/json" \
  -d "{\"chainType\":\"solana\",\"instructions\":[{\"programId\":\"$TOKEN_PROG\",\"accounts\":[{\"pubkey\":\"$SRC\",\"isSigner\":false,\"isWritable\":true},{\"pubkey\":\"$CASH_MINT\",\"isSigner\":false,\"isWritable\":false},{\"pubkey\":\"$DST\",\"isSigner\":false,\"isWritable\":true},{\"pubkey\":\"$SOL_ADDR\",\"isSigner\":true,\"isWritable\":false}],\"data\":\"$DATA\"}],\"network\":\"mainnet\"}")

if echo "$TX" | grep -q '"status":"confirmed"'; then
  HASH=$(echo "$TX" | grep -o '"txHash":"[^" ]*"' | cut -d'"' -f4 || true)
  NEW_STATE=$(python3 - <<'PY'
import json, datetime, sys
state = json.loads(sys.argv[1])
state['lastSentRaw'] = '$RAW_VALUE'
state['lastSentAt'] = datetime.datetime.utcnow().isoformat() + 'Z'
state['lastTx'] = '$HASH'
print(json.dumps(state))
PY
"$STATE_JSON")
  save_state "$NEW_STATE"
  printf '\n'
printf '============================================\n'
printf '  TRANSFER CONFIRMED!\n'
printf '============================================\n\n'
printf '  Explorer : https://solscan.io/tx/%s\n' "$HASH"
  exit 0
else
  echo "ERROR: Transaction failed." >&2
  echo "$TX" >&2
  exit 1
fi
