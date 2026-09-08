# SAMEER — DoraHacks submit (paste sheet)

**You only:** DoraHacks register/KYC + record demo video + click Submit.  
**Deadline:** 2026-09-13 23:59:00 ET  
**Start here:** https://dorahacks.io/hackathon/buidl-ctc-2026-fall/detail → Register as Hacker → Submit BUIDL

Do **not** invent a CC3 vault address. Discord faucet is optional/later.

---

## 1) Project fields — paste exactly

| Field | Value |
| --- | --- |
| Project Name | `ProofHire` |
| Project Logo | optional — skip |
| Project Sector | `AI` |
| GitHub Repository URL | `https://github.com/sameerbhatt101/proofhire` |
| Project Deck (PDF URL) | `https://sameerbhatt101.github.io/proofhire/ProofHire_Pitch.pdf` |
| Prototype Demo Video URL | *(your YouTube/unlisted URL after recording — see DEMO_SCRIPT.md)* |

**Alt PDF if Pages lags:** `https://github.com/sameerbhatt101/proofhire/raw/main/submit/ProofHire_Pitch.pdf`

### Project Description

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

CC3 ProofHireVault is code-complete; deploy awaits Creditcoin Discord CTC faucet (not live yet — no fabricated address).
```

### Attestcoin Protocol Integration Summary

```
ProofHire uses the official Attestcoin dApp Builder path end-to-end:
(1) Source SC — AcceptanceRegistry on Sepolia emits MilestoneAccepted;
(2) Readability worker — @gluwa/usc-sdk waitUntilHeightAttested + ProofBuilder.getProof;
(3) ASC — ProofHireVault extends ASCBase (@gluwa/asc-contracts) and calls verifyAndEmit at BlockProver 0xFD2 inside the Creditcoin tx;
(4) Business logic — escrow CTC release + proved-work reputation after EvmV1Decoder receipt/event checks.
Attestcoin is the settlement bridge, not a side quest. Packages: usc-sdk 0.18.0, asc-contracts 0.2.1.
Live Sepolia registry: 0x46F8A74A0F64Da7D778645e9Aa1f6116500213e6
Explorer: https://sepolia.etherscan.io/address/0x46F8A74A0F64Da7D778645e9Aa1f6116500213e6
```

Longer version (optional): `submit/ATTESTCOIN_INTEGRATION_SUMMARY.md`

---

## 2) Team fields (you)

| Field | What to enter |
| --- | --- |
| First & Last Name | legal name |
| Email | payout / DoraHacks contact |
| Telegram / X / LinkedIn | optional |
| Resume PDF URL | optional |
| Short Bio | 1–3 sentences |
| Role | `Lead / Builder` |
| Country of Residence | required |
| Country of Citizenship | required |

Complete any KYC prompts for prizes / CEIP.

---

## 3) Live URLs (public — confirmed)

| What | URL |
| --- | --- |
| Repo | https://github.com/sameerbhatt101/proofhire |
| Pages demo | https://sameerbhatt101.github.io/proofhire/ |
| Pages pitch | https://sameerbhatt101.github.io/proofhire/pitch.html |
| Pitch PDF | https://sameerbhatt101.github.io/proofhire/ProofHire_Pitch.pdf |
| Sepolia registry | https://sepolia.etherscan.io/address/0x46F8A74A0F64Da7D778645e9Aa1f6116500213e6 |
| Deploy tx | https://sepolia.etherscan.io/tx/0x0f3af57c8f1bdf76de53cca899629fa57189027dcee4f77ad8d8768d7a70a47f |

---

## 4) Your checklist (order)

1. Register as Hacker + team + KYC on DoraHacks.
2. Record ≤3 min demo (DEMO_SCRIPT.md). If CC3 faucet still parked: film Pages demo + pitch + Sepolia explorer; say vault is faucet-pending.
3. Upload video → paste Prototype Demo Video URL.
4. Submit BUIDL with the table + description + Attestcoin summary above.
5. Optional later: Discord faucet → deploy vault → add real CC3 explorer URL (never invent one).

Winners: 2026-09-20.
