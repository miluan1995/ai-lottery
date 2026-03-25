#!/usr/bin/env python3
"""AI Lottery Oracle V2 — trigger draw via Butterfly Oracle on-chain.
Calls requestDraw() on VaultV2, which sends a prompt to FlapAIProvider.
Oracle calls back fulfillReasoning() to pick and pay winner.

Before calling: ensure setCandidates() has been called with current holders.
"""
import subprocess, json, sys, os
from datetime import datetime, timezone

RPC = "https://bsc-rpc.publicnode.com"
VAULT = "0xBBccFD642a68F7040BaCAC74fCf4E501Fbf6b4e5"
TOKEN = "0x50FE03558Abd4733393d516baDf93D1508377777"
KNOWN_HOLDERS_FILE = os.path.join(os.path.dirname(__file__), "holders.json")
ENV = {**os.environ, "ALL_PROXY": "socks5://127.0.0.1:1080"}

SKIP = {
    "0x0000000000000000000000000000000000000000",
    "0x000000000000000000000000000000000000dead",
    "0xe2ce6ab80874fa9fa2aae65d277dd6b8e65c9de0",  # Portal
    VAULT.lower(),
    "0x3290590f5da46481f25e7328e21edf1fbdc3c438",  # SplitVault
}

def cast(*args):
    r = subprocess.run(["cast"] + list(args) + ["--rpc-url", RPC],
                       capture_output=True, text=True, env=ENV)
    return r.stdout.strip()

def log(msg):
    print(f"{datetime.now(timezone.utc).strftime('%FT%T')} {msg}", flush=True)

# Load PK
with open("/Users/mac/.openclaw/workspace/.env") as f:
    for line in f:
        if line.startswith("PRIVATE_KEY="):
            PK = line.split("=", 1)[1].strip().strip('"')
            break

# 1. Check if draw is already pending
pending = cast("call", VAULT, "isDrawPending()(bool)")
if "true" in pending.lower():
    log("Draw already pending (Oracle callback not yet received). Skip.")
    sys.exit(0)

# 2. Check pool balance
pool_raw = cast("call", VAULT, "getPoolBalance()(uint256,uint256)")
lines = pool_raw.split("\n")
pool = int(lines[0].split()[0])
reserve = int(lines[1].split()[0]) if len(lines) > 1 else 0
total = pool + reserve
log(f"Pool: {pool/1e18:.6f} BNB, Reserve: {reserve/1e18:.6f} BNB, Total: {total/1e18:.6f} BNB")

if total == 0:
    log("Pool empty, skip"); sys.exit(0)

# 3. Update candidates — load holders and check balances
known = set()
if os.path.exists(KNOWN_HOLDERS_FILE):
    with open(KNOWN_HOLDERS_FILE) as f:
        known = set(json.load(f))
known.add("0xd82913909e136779e854302e783ecdb06bfc7ee2")  # deployer always

holders = []
for addr in known:
    if addr.lower() in SKIP:
        continue
    try:
        raw = cast("call", TOKEN, "balanceOf(address)(uint256)", addr)
        bal = int(raw.split()[0])
        if bal > 0:
            holders.append(addr)
            log(f"  Holder: {addr} = {bal/1e18:.0f} AILOT")
    except:
        pass

if not holders:
    log("No holders with balance, skip"); sys.exit(0)

log(f"Found {len(holders)} eligible holders")

# 4. Update on-chain candidates
candidates_str = "[" + ",".join(holders) + "]"
r = subprocess.run([
    "cast", "send", "--rpc-url", RPC, "--private-key", PK, "--legacy",
    VAULT, "setCandidates(address[])", candidates_str, "--json"
], capture_output=True, text=True, env=ENV)
try:
    tx = json.loads(r.stdout)
    log(f"setCandidates TX: {tx.get('transactionHash','?')}")
except:
    log(f"setCandidates error: {r.stderr[:200]}")

# 5. Call requestDraw — triggers Oracle (costs 0.005 BNB)
log("Calling requestDraw() — sending 0.005 BNB to Oracle...")
r = subprocess.run([
    "cast", "send", "--rpc-url", RPC, "--private-key", PK, "--legacy",
    VAULT, "requestDraw()", "--json"
], capture_output=True, text=True, env=ENV)
try:
    tx = json.loads(r.stdout)
    txh = tx.get("transactionHash", "UNKNOWN")
    status = tx.get("status", "")
    if status != "0x1":
        log(f"requestDraw FAILED! TX: {txh} status={status}")
        sys.exit(1)
    log(f"requestDraw TX: {txh} ✅")
    log("Oracle will callback fulfillReasoning() shortly to pick winner.")
except:
    log(f"requestDraw error: {r.stderr[:300]}")
    sys.exit(1)

# 6. Report
rnd = cast("call", VAULT, "getCurrentRound()(uint256)").split()[0]
log(f"Draw requested for round {rnd}. Oracle will decide winner on-chain.")
