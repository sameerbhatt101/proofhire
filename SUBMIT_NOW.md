# ProofHire — DoraHacks submit NOW (Sameer-only)

**Deadline:** 2026-09-13 23:59:00 ET (page Extended: 2026-09-14 03:59 UTC)  
**Hackathon:** https://dorahacks.io/hackathon/buidl-ctc-2026-fall/detail  
**Register / Submit BUIDL** from that page (Sameer KYC — agent cannot do this).

---

## Paste-ready project fields

| Field | Paste exactly |
| --- | --- |
| **Project Name** | `ProofHire` |
| **Project Logo** | *(optional — skip or use any PH mark)* |
| **Project Sector** | `AI` *(secondary note in description: DeFi escrow rail)* |
| **GitHub Repository URL** | `https://github.com/sameerbhatt101/proofhire` |
| **Project Deck (PDF URL)** | `https://sameerbhatt101.github.io/proofhire/ProofHire_Pitch.pdf` |
| **Prototype Demo Video URL** | *(you must record — see DEMO_SCRIPT.md; upload YouTube/unlisted and paste URL)* |
| **Live demo (optional extra in description)** | `https://sameerbhatt101.github.io/proofhire/` |
| **Interactive pitch** | `https://sameerbhatt101.github.io/proofhire/pitch.html` |

### Project Description (paste)

```
ProofHire is Attestcoin-native milestone escrow for AI / freelance work.
Clients lock CTC on Creditcoin; acceptance happens on Ethereum Sepolia;
Attestcoin proves that acceptance in-transaction via BlockProver 0xFD2 so
escrow can release and reputation can update — without a trusted backend.

Live Sepolia AcceptanceRegistry:
https://sepolia.etherscan.io/address/0x46F8A74A0F64Da7D778645e9Aa1f6116500213e6

Demo: https://sameerbhatt101.github.io/proofhire/
Pitch: https://sameerbhatt101.github.io/proofhire/pitch.html
Repo: https://github.com/sameerbhatt101/proofhire

CC3 ProofHireVault deploy is code-complete; awaiting Creditcoin Discord CTC faucet (not invented as live).
```

### Attestcoin Protocol Integration Summary (paste)

Copy from `submit/ATTESTCOIN_INTEGRATION_SUMMARY.md` (full text), or this short form:

```
ProofHire uses the official Attestcoin dApp Builder path end-to-end:
(1) Source SC — AcceptanceRegistry on Sepolia emits MilestoneAccepted;
(2) Readability worker — @gluwa/usc-sdk waitUntilHeightAttested + ProofBuilder.getProof;
(3) ASC — ProofHireVault extends ASCBase (@gluwa/asc-contracts) and calls verifyAndEmit at BlockProver 0xFD2 inside the Creditcoin tx;
(4) Business logic — escrow CTC release + proved-work reputation after EvmV1Decoder receipt/event checks.
Attestcoin is the settlement bridge, not a side quest. Packages: usc-sdk 0.18.0, asc-contracts 0.2.1.
Live Sepolia registry: 0x46F8A74A0F64Da7D778645e9Aa1f6116500213e6
```

---

## Team fields (you / each member)

| Field | Notes |
| --- | --- |
| First & Last Name | Legal name |
| Email | Payout / DoraHacks contact |
| Telegram / X / LinkedIn | Optional |
| Resume PDF URL | Optional |
| Short Bio | 1–3 sentences |
| Role | e.g. `Lead / Builder` |
| Country of Residence | Required |
| Country of Citizenship | Required |

Also complete any KYC prompts shown for prizes / CEIP.

---

## Live links (already public — do not invent CC3 vault)

- Repo: https://github.com/sameerbhatt101/proofhire
- Sepolia AcceptanceRegistry: https://sepolia.etherscan.io/address/0x46F8A74A0F64Da7D778645e9Aa1f6116500213e6
- Deploy tx: https://sepolia.etherscan.io/tx/0x0f3af57c8f1bdf76de53cca899629fa57189027dcee4f77ad8d8768d7a70a47f
- Pages demo: https://sameerbhatt101.github.io/proofhire/
- Pages pitch: https://sameerbhatt101.github.io/proofhire/pitch.html
- Pitch PDF: https://sameerbhatt101.github.io/proofhire/ProofHire_Pitch.pdf
- Alt raw PDF: https://github.com/sameerbhatt101/proofhire/raw/main/submit/ProofHire_Pitch.pdf

## Parked (not Sameer-blocking for submit)

- Creditcoin `ProofHireVault` deploy — needs Discord CTC faucet (agent will not touch Discord).

## Sameer checklist (order)

1. Register as Hacker on DoraHacks detail page → complete team + KYC.
2. Record ≤3 min demo (DEMO_SCRIPT.md); Sepolia-only + static demo/pitch is OK if CC3 faucet still parked — narrate vault as pending faucet honestly.
3. Upload video → copy URL.
4. Submit BUIDL with the paste fields above.
5. (Optional later) Discord faucet → deploy vault → update description with CC3 explorer URL.

Winners: 2026-09-20.
