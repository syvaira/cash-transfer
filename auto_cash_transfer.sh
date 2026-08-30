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
  python3 - "$1" <<'PY'
import json, sys
path = sys.argv[1]
with open(path, 'r', encoding='utf-8') as f:
    text = f.read()
try:
    json.loads(text)
except Exception as exc:
    sys.stderr.write('ERROR: Invalid JSON response from AgentWallet balances endpoint.\n')
    sys.stderr.write('--- RAW RESPONSE START ---\n')
    sys.stderr.write(text + '\n')
    sys.stderr.write('--- RAW RESPONSE END ---\n')
    sys.stderr.write('--- RAW RESPONSE REPR PREFIX ---\n')
    sys.stderr.write(repr(text[:200]) + '\n')
    sys.stderr.write('--- RAW RESPONSE REPR PREFIX END ---\n')
    sys.stderr.write('--- RAW RESPONSE HEX PREFIX ---\n')
    sys.stderr.write(' '.join(f'{ord(c):02x}' for c in text[:32]) + '\n')
    sys.stderr.write('--- RAW RESPONSE HEX PREFIX END ---\n')
    sys.stderr.write(f'parse error: {exc}\n')
    sys.exit(1)
PY
}

load_state() {
  if [ -f "$STATE_FILE" ]; then
    python3 - "$STATE_FILE" <<'PY'
import json, pathlib, sys
path = pathlib.Path(sys.argv[1])
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
  python3 - "$STATE_FILE" "$1" <<'PY'
import json, pathlib, sys
state_file, payload = sys.argv[1], sys.argv[2]
state = json.loads(payload)
pathlib.Path(state_file).write_text(json.dumps(state, indent=2))
PY
}

STATE_JSON=$(load_state)
LAST_SENT_RAW=$(python3 - "$STATE_JSON" <<'PY'
import json, sys
state = json.loads(sys.argv[1])
print(state.get('lastSentRaw', '0'))
PY
)

printf '\n'
printf '============================================\n'
printf '  AgentWallet CASH Auto Transfer\n'
printf '============================================\n\n'

printf '[1/5] Checking balance...\n'
BALANCE_FILE=$(mktemp)
cleanup() {
  rm -f "$BALANCE_FILE"
}
trap cleanup EXIT
HTTP_STATUS=$(curl -sS --compressed -H "Authorization: Bearer $TOKEN" -H 'Accept: application/json' -o "$BALANCE_FILE" -w "%{http_code}" "$API/wallets/$USERNAME/balances" || true)
BALANCE_RESPONSE=$(cat "$BALANCE_FILE")
RESPONSE_LEN=$(wc -c < "$BALANCE_FILE" | tr -d '[:space:]')
printf '  HTTP status: %s\n' "$HTTP_STATUS"
printf '  Response length: %s\n' "$RESPONSE_LEN"
if [ -z "$BALANCE_RESPONSE" ] && [ "$HTTP_STATUS" != "200" ]; then
  echo "ERROR: AgentWallet balances request failed with HTTP status $HTTP_STATUS." >&2
  echo "RAW RESPONSE FILE PATH: $BALANCE_FILE" >&2
  echo "RAW RESPONSE CONTENT:" >&2
  cat "$BALANCE_FILE" >&2
  exit 1
fi
if [ -z "$BALANCE_RESPONSE" ]; then
  echo "ERROR: No response from AgentWallet balances endpoint." >&2
  exit 1
fi
validate_json "$BALANCE_FILE"

SOL_ADDR=$(python3 - "$BALANCE_RESPONSE" <<'PY'
import json, sys
obj = json.loads(sys.argv[1])
solanas = obj.get('solanaWallets') or obj.get('solana')
address = ''
if isinstance(solanas, list) and len(solanas) > 0:
    address = solanas[0].get('address','')
elif isinstance(solanas, dict):
    address = solanas.get('address','')
print(address or '')
PY
)

if [ -z "$SOL_ADDR" ]; then
  echo "ERROR: Unable to parse Solana address from balances response." >&2
  echo "RAW BALANCES RESPONSE:" >&2
  echo "$BALANCE_RESPONSE" >&2
  exit 1
fi
printf '  Solana addr: %s\n' "$SOL_ADDR"

printf '[2/5] Fetching source token account...\n'
SRC_JSON=$(curl -s -X POST -H 'Content-Type: application/json' -d "{\"jsonrpc\":\"2.0\",\"id\":1,\"method\":\"getTokenAccountsByOwner\",\"params\":[\"$SOL_ADDR\",{\"mint\":\"$CASH_MINT\"},{\"encoding\":\"jsonParsed\"}]}" "$RPC")
SRC=$(python3 -c 'import json, sys
obj = json.loads(sys.stdin.read())
value = obj.get("result", {}).get("value", [])
print(value[0].get("pubkey","") if value else "")' <<<"$SRC_JSON")

if [ -z "$SRC" ]; then
  echo "ERROR: Source CASH token account not found for $SOL_ADDR." >&2
  echo "RAW getTokenAccountsByOwner RESPONSE:" >&2
  echo "$SRC_JSON" >&2
  exit 1
fi

SRC_BALANCE_JSON=$(curl -s -X POST -H 'Content-Type: application/json' -d "{\"jsonrpc\":\"2.0\",\"id\":1,\"method\":\"getTokenAccountBalance\",\"params\":[\"$SRC\"]}" "$RPC")
RAW_VALUE=$(python3 -c 'import json, sys
obj = json.loads(sys.stdin.read())
value = obj.get("result", {}).get("value", {})
print(value.get("amount", "0"))' <<<"$SRC_BALANCE_JSON")
UI_AMOUNT=$(python3 -c 'import json, sys
obj = json.loads(sys.stdin.read())
value = obj.get("result", {}).get("value", {})
print(value.get("uiAmountString", "0"))' <<<"$SRC_BALANCE_JSON")

if [ -z "$RAW_VALUE" ] || [ "$RAW_VALUE" = "0" ]; then
  echo "No CASH balance available to send. Current raw balance: $RAW_VALUE"
  echo "  Solana addr used : $SOL_ADDR" >&2
  echo "  Source token acct: $SRC" >&2
  echo "RAW getTokenAccountBalance RESPONSE:" >&2
  echo "$SRC_BALANCE_JSON" >&2
  exit 0
fi

printf '  OK Solana : %s\n' "$SOL_ADDR"
printf '  OK CASH   : %s (%s raw units)\n' "$UI_AMOUNT" "$RAW_VALUE"

if [ "$RAW_VALUE" = "$LAST_SENT_RAW" ]; then
  echo "Balance is unchanged since last transfer; nothing to do."
  exit 0
fi

printf '  OK Source : %s\n' "$SRC"

printf '[3/5] Fetching destination token account...\n'
DST_JSON=$(curl -s -X POST -H 'Content-Type: application/json' -d "{\"jsonrpc\":\"2.0\",\"id\":1,\"method\":\"getTokenAccountsByOwner\",\"params\":[\"$DEST\",{\"mint\":\"$CASH_MINT\"},{\"encoding\":\"jsonParsed\"}]}" "$RPC")
DST=$(python3 - "$DST_JSON" <<'PY'
import json, sys
obj = json.loads(sys.argv[1])
value = obj.get('result', {}).get('value', [])
print(value[0].get('pubkey','') if value else '')
PY
)

if [ -z "$DST" ]; then
  echo "ERROR: Destination CASH token account not found for $DEST." >&2
  echo "The recipient must already have a CASH token account." >&2
  exit 1
fi
printf '  OK Dest   : %s\n' "$DST"

printf '[4/5] Encoding instruction data...\n'
DATA=$(node - "$RAW_VALUE" <<'NODE'
const raw = BigInt(process.argv[2]);
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
  NEW_STATE=$(python3 - "$STATE_JSON" "$RAW_VALUE" "$HASH" <<'PY'
import json, datetime, sys
state = json.loads(sys.argv[1])
state['lastSentRaw'] = sys.argv[2]
state['lastSentAt'] = datetime.datetime.utcnow().isoformat() + 'Z'
state['lastTx'] = sys.argv[3]
print(json.dumps(state))
PY
)
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
