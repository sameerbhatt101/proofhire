/** Poll Sepolia MilestoneAccepted and submit Attestcoin proofs. */
import { Contract, Wallet } from "ethers";
import { buildProofForTx, dryRunVerify, getProviders, getVault, requireEnv } from "./lib/proof.js";

const REGISTRY_ABI = ["event MilestoneAccepted(bytes32 indexed jobId, address indexed client, address indexed worker, uint256 amountHint, bytes32 metadataHash)"];

async function handleTx(txHash: string) {
  const proof = await buildProofForTx(txHash);
  if (!(await dryRunVerify(proof))) throw new Error("verify failed");
  const { creditcoin } = getProviders();
  const wallet = new Wallet(requireEnv("WORKER_PK"), creditcoin);
  const vault = getVault(wallet);
  const sent = await vault.execute(1, proof.chainKey, proof.headerNumber, proof.txBytes, proof.merkleProof.root, proof.merkleProof.siblings, proof.continuityProof.lowerEndpointDigest, proof.continuityProof.roots);
  console.log("paid via", sent.hash);
  await sent.wait();
}

async function main() {
  const { source } = getProviders();
  const registry = new Contract(requireEnv("ACCEPTANCE_REGISTRY_ADDRESS"), REGISTRY_ABI, source);
  console.log("watching MilestoneAccepted on", await registry.getAddress());
  registry.on("MilestoneAccepted", async (...args: unknown[]) => {
    const ev = args[args.length - 1] as { log?: { transactionHash?: string }; transactionHash?: string };
    const hash = ev.log?.transactionHash ?? ev.transactionHash;
    if (!hash) return;
    console.log("event in", hash);
    try { await handleTx(hash); } catch (e) { console.error(e); }
  });
}
main().catch((e) => { console.error(e); process.exit(1); });
