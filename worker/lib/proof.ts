/**
 * Shared Attestcoin proof helpers — APIs from @gluwa/usc-sdk@0.18.0 docs/typings only.
 */
import { JsonRpcProvider, Wallet, Contract } from "ethers";
import { chainInfo, blockProver, proofProvider } from "@gluwa/usc-sdk";
import "dotenv/config";

export function requireEnv(name: string): string {
  const v = process.env[name];
  if (!v) throw new Error(`Missing env ${name}`);
  return v;
}

export function getProviders() {
  const source = new JsonRpcProvider(requireEnv("SOURCE_CHAIN_RPC_URL"));
  const creditcoin = new JsonRpcProvider(requireEnv("CREDITCOIN_RPC_URL"));
  return { source, creditcoin };
}

export function getChainKey(): number {
  return Number(process.env.SOURCE_CHAIN_KEY ?? "1");
}

export function getProofBuilder(chainKey: number) {
  const url = requireEnv("PROOF_BUILDER_URL");
  return new proofProvider.service.ProofBuilder(chainKey, url);
}

/** Wait for attestation + fetch proof for a Sepolia tx hash. */
export async function buildProofForTx(txHash: string) {
  const { source, creditcoin } = getProviders();
  const chainKey = getChainKey();

  const info = new chainInfo.PrecompileChainInfoProvider(creditcoin);
  const supported = await info.getSupportedChains();
  console.log("supportedChains", supported);

  const tx = await source.getTransaction(txHash);
  if (!tx?.blockNumber) throw new Error("tx not mined");

  const builder = getProofBuilder(chainKey);
  console.log("waiting for attestation at height", tx.blockNumber);
  await builder.waitUntilHeightAttested(chainKey, tx.blockNumber);

  const result = await builder.getProof(txHash);
  if (!result.success || !result.data) {
    throw new Error(`Proof failed: ${result.error}`);
  }
  return result.data;
}

/** Optional dry-run against BlockProver precompile (view verify). */
export async function dryRunVerify(proofData: {
  chainKey: number;
  headerNumber: number;
  txBytes: string;
  merkleProof: unknown;
  continuityProof: unknown;
}) {
  const { creditcoin } = getProviders();
  const prover = new blockProver.PrecompileBlockProver(creditcoin);
  // Method signature from SDK docs / typings
  const ok = await prover.verifySingle(
    proofData.chainKey,
    proofData.headerNumber,
    proofData.txBytes,
    proofData.merkleProof as never,
    proofData.continuityProof as never,
  );
  return ok;
}

/** Minimal ABI for ASCBase.execute + ProofHireVault.openJob */
export const VAULT_ABI = [
  "function openJob(bytes32 jobId, address worker) payable",
  "function execute(uint8 action, uint64 chainKey, uint64 blockHeight, bytes encodedTransaction, bytes32 merkleRoot, tuple(bytes32 hash, bool isLeft)[] siblings, bytes32 lowerEndpointDigest, bytes32[] continuityRoots) returns (bool)",
  "function reputation(address) view returns (uint256)",
  "function jobs(bytes32) view returns (address client, address worker, uint256 escrow, bool open, bool paid)",
  "function ACTION_PAY_MILESTONE() view returns (uint8)",
];

export function getVault(signerOrProvider: Wallet | JsonRpcProvider) {
  return new Contract(requireEnv("PROOFHIRE_VAULT_ADDRESS"), VAULT_ABI, signerOrProvider);
}
