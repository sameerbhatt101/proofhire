# ProofHire — Demo Script (<= 3 minutes)

## Prep
- Client + Worker wallets funded (Sepolia + CC3 testnet)
- Contracts deployed; explorer tabs open
- Worker ready (submit or watch mode)

## Script
### 0:00-0:20 Hook
Freelance/agent work still settles on trust. ProofHire: acceptance on Ethereum, escrow+reputation on Creditcoin, Attestcoin is the only link.

### 0:20-0:50 openJob (Creditcoin)
Show escrow lock on Blockscout.

### 0:50-1:20 acceptMilestone (Sepolia)
Show delivery artifact, then MilestoneAccepted log.

### 1:20-2:10 Attestcoin proof
waitUntilHeightAttested then getProof then vault execute. Narrate Merkle + continuity + 0xFD2 in-tx verify. Show payout + reputation.

### 2:10-2:40 Outcome
Worker paid; replay fails (Query already processed).

### 2:40-3:00 Close
Track AI (+DeFi). Original. Attestcoin core. GitHub + docs citations.

## Fallback
If attestation lag: keep labeled recorded successful CC3 submission as B-roll.
