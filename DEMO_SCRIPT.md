# ProofHire — Demo Script (<= 3 minutes)

## Prep

- Sepolia explorer tab open on AcceptanceRegistry  
  https://sepolia.etherscan.io/address/0x46F8A74A0F64Da7D778645e9Aa1f6116500213e6
- Static demo + pitch: https://sameerbhatt101.github.io/proofhire/ (or `apps/demo/`)
- Optional: CC3 vault + worker if Discord faucet unlocked (do not invent address)

## Script

### 0:00-0:20 Hook
Freelance/agent work still settles on trust. ProofHire: acceptance on Ethereum, escrow+reputation on Creditcoin, Attestcoin is the only link.

### 0:20-0:50 openJob (Creditcoin)
Show escrow lock on Blockscout **if vault live**. Else: show vault code path in repo + say “CC3 deploy awaiting faucet” while walking `ProofHireVault.openJob`.

### 0:50-1:20 acceptMilestone (Sepolia)
Show delivery artifact idea, then live Sepolia registry / `MilestoneAccepted` path on explorer.

### 1:20-2:10 Attestcoin proof
Narrate `@gluwa/usc-sdk` `waitUntilHeightAttested` → `getProof` → vault `execute` → Merkle + continuity + **0xFD2 in-tx verify**. Cite docs.attestcoin.org dApp Builder shape.

### 2:10-2:40 Outcome
Worker paid + reputation when vault live; replay fails (Query already processed). If vault pending: show Foundry tests + ASCBase dedupe in code.

### 2:40-3:00 Close
Track AI (+DeFi). Original. Attestcoin core. GitHub + Pages + Sepolia explorer.

## Fallback (no Discord faucet)

Record screen of Pages demo → pitch → Sepolia explorer → GitHub Attestcoin summary. Honest about CC3 pending. Prefer this over inventing a live CC3 address.
