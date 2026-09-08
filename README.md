# ProofHire

Attestcoin milestone escrow scaffold for DoraHacks BUIDL CTC 2026 Fall.
Builder: Sameer Bhatt / agent Money.

Clients lock CTC on Creditcoin. Acceptance happens on Ethereum Sepolia.
Attestcoin proves that acceptance so Creditcoin can release escrow and update reputation.

## Hackathon pointers
- Detail page: https://dorahacks.io/hackathon/buidl-ctc-2026-fall/detail
- Deadline: 2026-09-13 23:59:00 ET (extended; confirm on page)
- Prizes: USD 15,000 (10k / 3k / 2k) + CEIP fast-track for top 3
- Companion docs: HACKATHON_BRIEF.md, ARCHITECTURE.md, DEMO_SCRIPT.md, PITCH_DECK_OUTLINE.md, SAMEER_STEPS.md

## Why Attestcoin is core
Work settlement across chains. Acceptance event on Sepolia; capital and reputation on Creditcoin.
Payout path calls BlockProver precompile 0xFD2 inside the Creditcoin transaction via ASCBase from @gluwa/asc-contracts.

## Layout
- contracts/sepolia/AcceptanceRegistry.sol
- contracts/creditcoin/ProofHireVault.sol
- worker/ TypeScript readability worker (@gluwa/usc-sdk)
- apps/demo/ static walkthrough
- test/ Foundry tests (AcceptanceRegistry passing)
- docs/ATTESTCOIN_SOURCES.md
- _vendor/ offline copies of Gluwa packages

## Dependencies
@gluwa/usc-sdk 0.18.0, @gluwa/asc-contracts 0.2.1, ethers v6, OpenZeppelin 5.4.0

## Status
- forge build: successful (via_ir required for EvmV1Decoder)
- forge test: AcceptanceRegistry test PASS
- Live CC3/Sepolia loop, DoraHacks registration, demo video, PDF deck: Sameer-only (SAMEER_STEPS.md)
- Proof builder URL: environments docs vs SDK tutorial examples disagree; .env.example uses environments host

## DoraHacks Attestcoin summary
Readability: Sepolia MilestoneAccepted -> ProofBuilder proofs -> ProofHireVault.execute -> verifyAndEmit at 0xFD2 -> EvmV1Decoder receipt+event checks -> escrow release + reputation.

MIT for ProofHire app logic. Gluwa packages keep upstream licenses.

Public repo: https://github.com/sameerbhatt101/proofhire
