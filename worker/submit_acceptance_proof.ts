/** Manual Attestcoin proof submit for ProofHireVault.execute */
import { Wallet } from "ethers";
import { buildProofForTx, dryRunVerify, getProviders, getVault, requireEnv } from "./lib/proof.js";

async function main() {
  const args = process.argv.slice(2);
  const txIdx = args.indexOf("--tx");
  const txHash = txIdx >= 0 ? args[txIdx + 1] : process.env.SEPOLIA_TX_HASH;
  if (!txHash) throw new Error("need --tx");
  const proof = await buildProofForTx(txHash);
  console.log("height", proof.headerNumber);
  const ok = await dryRunVerify(proof);
  if (!ok) throw new Error("verifySingle failed");
  const { creditcoin } = getProviders();
  const wallet = new Wallet(requireEnv("WORKER_PK"), creditcoin);
  const vault = getVault(wallet);
  const sent = await vault.execute(1, proof.chainKey, proof.headerNumber, proof.txBytes, proof.merkleProof.root, proof.merkleProof.siblings, proof.continuityProof.lowerEndpointDigest, proof.continuityProof.roots);
  console.log("hash", sent.hash);
  await sent.wait();
}
main().catch((e) => { console.error(e); process.exit(1); });
