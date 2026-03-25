#!/usr/bin/env python3
"""AI Lottery Oracle — draw winner. Run hourly via cron.
Uses balanceOf to check known holders instead of scanning Transfer events.
New holders discovered via flap.sh API or manual addition.
"""
import subprocess, json, random, sys, os
from datetime import datetime, timezone

RPC = "https://bsc-rpc.publicnode.com"
VAULT = "0x3e219c19D56982D02f1FB2ca76AcE87Dca959E4E"
TOKEN = "0xe82c87d599eED544c08A28370C3B9c56CbC77777"
PORTAL = "0xe2cE6ab80874Fa9Fa2aAE65D277Dd6B8e65C9De0"
KNOWN_HOLDERS_FILE = os.path.join(os.path.dirname(__file__), "holders.json")
ENV = {**os.environ, "ALL_PROXY": "socks5://127.0.0.1:1080"}

# Addresses to exclude from lottery
SKIP = {
    "0x0000000000000000000000000000000000000000",
    "0x000000000000000000000000000000000000dead",
    PORTAL.lower(),
    VAULT.lower(),
    "0x5aeef4b3a8e39d53edf5b4f9b22a55d0fc885c2f",  # SplitVault
    "0x1de460f363af910f51726def188f9004276bf4bc",  # gmgn_router
}

def cast(*args):
    r = subprocess.run(["cast"] + list(args) + ["--rpc-url", RPC],
                       capture_output=True, text=True, env=ENV)
    return r.stdout.strip()

def log(msg):
    print(f"{datetime.now(timezone.utc).strftime('%FT%T')} {msg}", flush=True)

def load_known():
    if os.path.exists(KNOWN_HOLDERS_FILE):
        with open(KNOWN_HOLDERS_FILE) as f:
            return set(json.load(f))
    return set()

def save_known(addrs):
    with open(KNOWN_HOLDERS_FILE, "w") as f:
        json.dump(sorted(addrs), f)

# Load PK
with open("/Users/mac/.openclaw/workspace/.env") as f:
    for line in f:
        if line.startswith("PRIVATE_KEY="):
            PK = line.split("=", 1)[1].strip().strip('"')
            break

# 1. Check pool
pool_raw = cast("call", VAULT, "getPoolBalance()(uint256,uint256)")
pool = int(pool_raw.split("\n")[0].split()[0])
if pool == 0:
    log("Pool empty, skip"); sys.exit(0)
log(f"Pool: {pool/1e18:.4f} BNB")

# 2. Load known addresses and check balances
known = load_known()
# Always include deployer
known.add("0xd82913909e136779e854302e783ecdb06bfc7ee2")

holders = {}
for addr in known:
    if addr.lower() in SKIP:
        continue
    try:
        raw = cast("call", TOKEN, "balanceOf(address)(uint256)", addr)
        bal = int(raw.split()[0])
        if bal > 0:
            holders[addr.lower()] = bal
    except:
        pass

if not holders:
    log("No holders with balance, skip"); sys.exit(0)

log(f"Found {len(holders)} holders with balance")
for addr, bal in sorted(holders.items(), key=lambda x: -x[1]):
    log(f"  {addr} = {bal/1e18:.0f} AILOT")

# 3. Weighted random pick
addrs = list(holders.keys())
weights = [holders[a] for a in addrs]
winner = random.choices(addrs, weights=weights, k=1)[0]
log(f"Winner: {winner} (balance: {holders[winner]/1e18:.0f} AILOT)")

# 4. Draw on-chain
r = subprocess.run([
    "cast", "send", "--rpc-url", RPC, "--private-key", PK, "--legacy",
    VAULT, "drawWinner(address)", winner, "--json"
], capture_output=True, text=True, env=ENV)
try:
    tx = json.loads(r.stdout)
    log(f"Draw TX: {tx.get('transactionHash', 'UNKNOWN')}")
    if tx.get("status") != "0x1":
        log(f"TX FAILED! status={tx.get('status')}"); sys.exit(1)
except:
    log(f"TX error: {r.stderr[:200]}"); sys.exit(1)

# 5. Confirm
rnd = cast("call", VAULT, "getCurrentRound()(uint256)").split()[0]
log(f"Round {rnd} drawn. Winner: {winner}")

# Save updated known list
save_known(known)
