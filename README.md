# ProofHire

Attestcoin milestone escrow for DoraHacks BUIDL CTC 2026 Fall.  
Builder: Sameer Bhatt / agent Money.

Clients lock CTC on Creditcoin. Acceptance happens on Ethereum Sepolia.  
Attestcoin proves that acceptance so Creditcoin can release escrow and update reputation.

## Live (public)

| What | URL |
| --- | --- |
| GitHub | https://github.com/sameerbhatt101/proofhire |
| Demo walkthrough | https://sameerbhatt101.github.io/proofhire/ |
| Interactive pitch | https://sameerbhatt101.github.io/proofhire/pitch.html |
| Pitch PDF | https://sameerbhatt101.github.io/proofhire/ProofHire_Pitch.pdf |
| Sepolia AcceptanceRegistry | https://sepolia.etherscan.io/address/0x46F8A74A0F64Da7D778645e9Aa1f6116500213e6 |
| Deploy tx | https://sepolia.etherscan.io/tx/0x0f3af57c8f1bdf76de53cca899629fa57189027dcee4f77ad8d8768d7a70a47f |

**CC3 ProofHireVault:** not deployed yet (Discord CTC faucet parked). Do not invent an address.

## Hackathon pointers

- Detail: https://dorahacks.io/hackathon/buidl-ctc-2026-fall/detail
- Deadline: **2026-09-13 23:59:00 ET** (extended)
- Prizes: USD 15,000 (10k / 3k / 2k) + CEIP fast-track for top 3
- **Submit paste sheet:** [SAMEER_SUBMIT.md](./SAMEER_SUBMIT.md) (also [SUBMIT_NOW.md](./SUBMIT_NOW.md))
- Companion: [HACKATHON_BRIEF.md](./HACKATHON_BRIEF.md) · [ARCHITECTURE.md](./ARCHITECTURE.md) · [DEMO_SCRIPT.md](./DEMO_SCRIPT.md) · [SAMEER_STEPS.md](./SAMEER_STEPS.md) · [submit/ATTESTCOIN_INTEGRATION_SUMMARY.md](./submit/ATTESTCOIN_INTEGRATION_SUMMARY.md)

## Why Attestcoin is core

Work settlement across chains. Acceptance event on Sepolia; capital and reputation on Creditcoin.  
Payout path calls BlockProver precompile `0xFD2` inside the Creditcoin transaction via ASCBase from `@gluwa/asc-contracts`.

## Layout

- `contracts/sepolia/AcceptanceRegistry.sol`
- `contracts/creditcoin/ProofHireVault.sol`
- `worker/` TypeScript readability worker (`@gluwa/usc-sdk`)
- `apps/demo/` static walkthrough + HTML pitch
- `submit/` pitch PDF + Attestcoin summary for DoraHacks
- `test/` Foundry tests (AcceptanceRegistry passing)
- `docs/ATTESTCOIN_SOURCES.md`
- `_vendor/` offline copies of Gluwa packages

## Dependencies

`@gluwa/usc-sdk` 0.18.0, `@gluwa/asc-contracts` 0.2.1, ethers v6, OpenZeppelin 5.4.0

## Status

- forge build: successful (`via_ir` required for EvmV1Decoder)
- forge test: AcceptanceRegistry PASS
- Sepolia registry: **live** (address above)
- CC3 vault / Discord faucet / DoraHacks KYC / demo video: **Sameer-only** — see SUBMIT_NOW.md
- Proof builder URL: environments docs vs SDK tutorial examples disagree; `.env.example` uses environments host

## DoraHacks Attestcoin summary

Readability: Sepolia `MilestoneAccepted` → ProofBuilder proofs → `ProofHireVault.execute` → `verifyAndEmit` at `0xFD2` → EvmV1Decoder receipt+event checks → escrow release + reputation.

MIT for ProofHire app logic. Gluwa packages keep upstream licenses.
