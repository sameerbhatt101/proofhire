# ProofHire — Architecture

## One-liner
Clients lock budgets on Creditcoin, accept work on Ethereum Sepolia, and Attestcoin unlocks payout + reputation on Creditcoin — no centralized oracle.

## Why Attestcoin is load-bearing
| Without | With |
|---|---|
| Backend tells Creditcoin accepted | Sepolia MilestoneAccepted inclusion proved (Merkle + continuity) |
| Escrow trusts an operator | Release requires BlockProver 0xFD2 success in the same tx |
| Off-chain reputation | Reputation only from proved successful source txs |

## Components (official dApp Builder Infrastructure)
1. Source SC: AcceptanceRegistry (Sepolia) emits MilestoneAccepted
2. Readability worker: wait attestation • ProofBuilder.getProof ™ call ASC
3. ASC: ProofHireVault extends ASCBase • verifyAndEmit at 0xFD2
4. Business logic: release escrow + increment reputation (same contract)

## Flow
1. Client openJob on Creditcoin (native CTC escrow)
2. Worker delivers off-band
3. Client acceptMilestone on Sepolia
4. Worker submits Attestcoin proof to ProofHireVault.execute
5. Vault checks receiptStatus==1, emitter allowlist, job/worker binding, pays out

## Track
Primary AI (agent/human milestones for Agent Money). Secondary DeFi/escrow + attested work credit.
