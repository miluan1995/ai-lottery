#!/bin/bash
# AI Lottery Oracle — draw winner
# Called by cron every hour. Picks a random holder weighted by balance.
set -euo pipefail

RPC="https://bsc-rpc.publicnode.com"
VAULT="0x3e219c19D56982D02f1FB2ca76AcE87Dca959E4E"
TOKEN="0x12A95d42Fd40Fab96b7E53062a4FF489CE757777"
PORTAL="0xe2cE6ab80874Fa9Fa2aAE65D277Dd6B8e65C9De0"
PK=$(grep '^PRIVATE_KEY=' /Users/mac/.openclaw/workspace/.env | head -1 | sed 's/PRIVATE_KEY=//' | tr -d ' "')

export ALL_PROXY=socks5://127.0.0.1:1080

# 1. Check pool has funds
POOL=$(cast call "$VAULT" "getPoolBalance()(uint256,uint256)" --rpc-url "$RPC" 2>/dev/null | head -1 | awk '{print $1}')
if [ "$POOL" = "0" ]; then
  echo "$(date -u +%FT%T) Pool empty, skip draw"
  exit 0
fi

# 2. Get holders from Transfer events
CREATION_BLOCK=88598690
LATEST=$(cast block-number --rpc-url "$RPC" 2>/dev/null)

# Query in chunks of 5000 blocks to avoid RPC limits
HOLDERS=$(python3 -c "
import subprocess, json, sys

creation = $CREATION_BLOCK
latest = $LATEST
token = '$TOKEN'
rpc = '$RPC'
chunk = 5000
all_logs = []

for start in range(creation, latest + 1, chunk):
    end = min(start + chunk - 1, latest)
    cmd = ['cast', 'logs', '--from-block', str(start), '--to-block', str(end),
           '--address', token, 'Transfer(address,address,uint256)',
           '--rpc-url', rpc, '--json']
    r = subprocess.run(cmd, capture_output=True, text=True, env={**__import__('os').environ, 'ALL_PROXY': 'socks5://127.0.0.1:1080'})
    try:
        logs = json.loads(r.stdout)
        all_logs.extend(logs)
    except: pass

# Build holder map from all_logs
" 2>/dev/null)

HOLDERS=$(echo "$all_logs_placeholder" | python3 -c "
import sys, json

logs = json.load(sys.stdin)
balances = {}
ZERO = '0x' + '0' * 64
DEAD = '0x000000000000000000000000000000000000dead'

for log in logs:
    topics = log['topics']
    fr = '0x' + topics[1][-40:]
    to = '0x' + topics[2][-40:]
    val = int(log['data'], 16)

    # skip zero/dead/portal/vault addresses
    skip = {'0x' + '0'*40, DEAD, '$PORTAL'.lower(), '$VAULT'.lower()}

    if fr.lower() not in skip:
        balances[fr.lower()] = balances.get(fr.lower(), 0) - val
    if to.lower() not in skip:
        balances[to.lower()] = balances.get(to.lower(), 0) + val

# Filter positive balances
holders = {k: v for k, v in balances.items() if v > 0}

if not holders:
    print('NO_HOLDERS')
else:
    # Weighted random selection
    import random
    addrs = list(holders.keys())
    weights = [holders[a] for a in addrs]
    winner = random.choices(addrs, weights=weights, k=1)[0]
    # Checksum
    print(winner)
")

if [ "$HOLDERS" = "NO_HOLDERS" ]; then
  echo "$(date -u +%FT%T) No holders, skip draw"
  exit 0
fi

WINNER="$HOLDERS"
echo "$(date -u +%FT%T) Drawing winner: $WINNER"

# 3. Call drawWinner
TX=$(cast send \
  --rpc-url "$RPC" \
  --private-key "$PK" \
  --legacy \
  "$VAULT" \
  "drawWinner(address)" \
  "$WINNER" \
  --json 2>/dev/null | python3 -c "import sys,json; d=json.load(sys.stdin); print(d.get('transactionHash','FAILED'))")

echo "$(date -u +%FT%T) Draw TX: $TX"

# 4. Log
ROUND=$(cast call "$VAULT" "getCurrentRound()(uint256)" --rpc-url "$RPC" 2>/dev/null | awk '{print $1}')
echo "$(date -u +%FT%T) Round $ROUND complete. Winner: $WINNER"
