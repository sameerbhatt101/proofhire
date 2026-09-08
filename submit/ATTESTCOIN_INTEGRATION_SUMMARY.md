# ProofHire — Attestcoin Integration Summary

**Project:** ProofHire · **Hackathon:** DoraHacks BUIDL CTC 2026 Fall · **Track:** AI  
**One line:** Milestone escrow on Creditcoin that pays only after an Attestcoin-proved Sepolia acceptance — Attestcoin is the settlement bridge, not a side quest.

## Why Attestcoin is load-bearing

Clients and agent workflows live on Ethereum; capital and reputation live on Creditcoin. Without Attestcoin, a backend would tell Creditcoin “accepted.” With Attestcoin, payout requires a Merkle + continuity inclusion proof of a Sepolia `MilestoneAccepted` event, verified **in the same Creditcoin transaction** via BlockProver precompile `0xFD2`.

## Official dApp Builder shape (used end-to-end)

| Layer | ProofHire component | Attestcoin role |
| --- | --- | --- |
| 1. Source SC | `AcceptanceRegistry` (Ethereum Sepolia) | Emits `MilestoneAccepted` — the attested fact |
| 2. Readability worker | TypeScript worker (`@gluwa/usc-sdk`) | `waitUntilHeightAttested` → `ProofBuilder.getProof` → call ASC |
| 3. ASC | `ProofHireVault` extends `ASCBase` (`@gluwa/asc-contracts`) | `verifyAndEmit` at BlockProver `0xFD2` |
| 4. Business logic | Same vault contract | Release CTC escrow + increment proved-work reputation |

## Integration depth (not a wrapper)

- **In-transaction verify:** Payout path calls BlockProver `0xFD2` inside the Creditcoin tx through ASCBase — not an off-chain “trusted” flag.
- **ASCBase dedupe:** Already-processed queries fail on replay; escrow cannot double-spend from the same attested source tx.
- **EvmV1Decoder binding:** Receipt `status == 1`, emitter allowlist, and job/worker event binding before release.
- **USC ProofBuilder path:** Worker waits for attestation, builds proofs, then `vault.execute` — matching docs.attestcoin.org dApp Builder Infrastructure.

## Flow (readable)

1. Client `openJob` → CTC locked in `ProofHireVault` on Creditcoin.  
2. Worker delivers off-band (PR, media, agent output).  
3. Client `acceptMilestone` on Sepolia → `MilestoneAccepted` log.  
4. Worker submits Attestcoin proof → vault verifies in-tx → payout + reputation.

## Live status (no fabricated metrics)

- **Sepolia AcceptanceRegistry (live):** `0x46F8A74A0F64Da7D778645e9Aa1f6116500213e6`  
  Explorer: https://sepolia.etherscan.io/address/0x46F8A74A0F64Da7D778645e9Aa1f6116500213e6  
- **ProofHireVault on CC3:** pending Discord CTC faucet (scaffold + Foundry build green).  
- Packages: `@gluwa/usc-sdk@0.18.0`, `@gluwa/asc-contracts@0.2.1`.

## Citations

https://docs.attestcoin.org/ · environments (BlockProver `0xFD2`, ChainInfo `0xFD3`, CC3 proof builder) · Gluwa ASC/USC packages · https://github.com/gluwa/attestcoin-protocol-examples

*MIT for ProofHire app logic; Gluwa packages retain upstream licenses.*
