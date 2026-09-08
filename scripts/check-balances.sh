#!/usr/bin/env bash
set -euo pipefail
ROOT="$(cd "$(dirname "$0")/.." && pwd)"
export PATH="$HOME/.foundry/bin:$ROOT/.tools:$PATH"
DEPLOYER="$(python3 - <<'PY'
import json
from pathlib import Path
p=Path('/home/box/agent-data/agents/6f9970c1-a774-453e-a2cc-f35ca9ed0d07/secrets/proofhire-keys.json')
print(json.loads(p.read_text())['wallets']['deployer']['address'])
PY
)"
echo "deployer=$DEPLOYER"
echo -n "sepolia_wei="; cast balance "$DEPLOYER" --rpc-url https://ethereum-sepolia-rpc.publicnode.com
echo -n "cc3_wei="; cast balance "$DEPLOYER" --rpc-url https://rpc.cc3-testnet.creditcoin.network
