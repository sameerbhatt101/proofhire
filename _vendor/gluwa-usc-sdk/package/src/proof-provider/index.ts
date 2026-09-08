export * as raw from './raw';
export * as service from './service';
export * as merkle from './merkle';

import { TransactionMerkleProof } from './merkle';

/**
 * A continuity proof used to prove block continuity in the attestation chain.
 * @member lowerEndpointDigest The digest of the block before the continuity chain starts
 * @member roots Array of merkle roots (digests computed on-chain)
 *
 */
export interface ContinuityProof {
  lowerEndpointDigest: string;
  roots: string[];
}

/**
 * Merges multiple ContinuityProofs into a single proof.
 *
 * The resulting proof will have the lowerEndpointDigest of the first proof,
 * and will concatenate all roots from the provided proofs.
 *
 * **IMPORTANT: This method expects the proofs to be in order from lowest to highest block number and contiguous.
 * Otherwise, the resulting proof will not be usable for proving.**
 *
 * @param proofs Array of tuples containing [blockHeight, ContinuityProof] pairs, ordered by block height
 * @returns A merged ContinuityProof containing all roots from the input proofs
 * @throws Error if proofs are not contiguous
 *
 * @example
 * ```typescript
 * const proof1: ContinuityProof = { lowerEndpointDigest: '0x123...', roots: ['0xabc...', '0xdef...'] };
 * const proof2: ContinuityProof = { lowerEndpointDigest: '0x456...', roots: ['0xdef...', '0x789...'] };
 *
 * const mergedProof = ContinuityProofBuilder.mergeProofs([
 *   [100, proof1],
 *   [102, proof2]
 * ]);
 * // Result: { lowerEndpointDigest: '0x123...', roots: ['0xabc...', '0xdef...', '0x789...'] }
 * ```
 */
export function mergeProofs(proofs: [number, ContinuityProof][]): ContinuityProof {
  if (proofs.length === 0) {
    return { lowerEndpointDigest: '', roots: [] };
  } else {
    let mergedRoots: string[] = [];
    let latestHeight = -1;

    for (const [height, proof] of proofs) {
      let startIdx = 0;

      // If we have a latest height, find the index of its root in the current proof
      if (latestHeight !== -1) {
        startIdx = latestHeight - height + 1;

        if (startIdx < 0) {
          throw new Error(`Proofs are not contiguous: latestHeight=${latestHeight}, currentHeight=${height}`);
        }
      } else {
        startIdx = 0;
      }

      for (let i = startIdx; i < proof.roots.length; i++) {
        mergedRoots.push(proof.roots[i]);
      }

      latestHeight = height + proof.roots.length - 1;
    }

    return {
      lowerEndpointDigest: proofs[0][1].lowerEndpointDigest,
      roots: mergedRoots,
    };
  }
}

export interface ContinuityResponse {
  chainKey: number;
  headerNumber: number;
  txIndex: number;
  txHash: string;
  txBytes: string;
  continuityProof: ContinuityProof;
  merkleProof: TransactionMerkleProof;
  cached: boolean;
  generatedAt: Date;
}

export interface ProofResult {
  success: boolean;
  data?: ContinuityResponse;
  error?: string;
}

export interface BatchContinuityResponse {
  chainKey: number;
  fromHeader: number;
  toHeader: number;
  continuityProof: ContinuityProof;
  merkleProofs: Map<number, Map<number, BatchMerkleProofEntry>>;
  cached: boolean;
  generatedAt: Date;
}

export interface BatchMerkleProofEntry {
  txHash: string;
  txBytes: string;
  merkleProof: TransactionMerkleProof;
}

export interface BatchProofResult {
  success: boolean;
  data?: BatchContinuityResponse;
  error?: string;
}

export interface ProofProvider {
  getProof(transactionHash: string): Promise<ProofResult>;
  getBatchProof(transactionHashes: string[]): Promise<BatchProofResult>;
}
