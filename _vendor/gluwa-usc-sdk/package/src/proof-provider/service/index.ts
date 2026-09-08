import axios, { AxiosInstance } from 'axios';

import { BatchContinuityResponse, BatchProofResult, ContinuityResponse, ProofResult, ProofProvider } from '..';

const API_BASE_PATH = '/api/v1/proof-by-tx';
const API_BATCH_BASE_PATH = '/api/v1/proof-batch-by-tx';
const API_ATTESTED_HEIGHT_PATH = '/api/v1/attested-height';

class ApiClient {
  private client: AxiosInstance;

  constructor(baseURL: string, timeoutMs: number = 10000) {
    this.client = axios.create({
      baseURL,
      timeout: timeoutMs,
      headers: {
        'Content-Type': 'application/json',
      },
    });
  }

  async queryProofFor(chainKey: number, transactionHash: string): Promise<ContinuityResponse> {
    try {
      const res = await this.client.get(`${API_BASE_PATH}/${chainKey}/${transactionHash}`);

      return res.data as ContinuityResponse;
    } catch (error) {
      if (axios.isAxiosError(error)) {
        throw new Error(`Failed to fetch proof: ${error}`);
      } else {
        throw new Error(`Unexpected error: ${error}`);
      }
    }
  }

  async queryProofBatchFor(chainKey: number, transactionHashes: string[]): Promise<BatchContinuityResponse> {
    try {
      const res = await this.client.post(`${API_BATCH_BASE_PATH}/${chainKey}`, transactionHashes);
      const data = res.data;

      const merkleProofs = new Map(
        Object.entries(data.merkleProofs).map(([headerNumber, proofsMap]: [string, any]) => [
          Number(headerNumber),
          new Map(
            Object.entries(proofsMap).map(([txIndex, proofEntry]: [string, any]) => [
              Number(txIndex),
              {
                txHash: proofEntry.txHash,
                txBytes: proofEntry.txBytes,
                merkleProof: proofEntry.merkleProof,
              },
            ]),
          ),
        ]),
      );

      return {
        chainKey: data.chainKey,
        fromHeader: data.fromHeader,
        toHeader: data.toHeader,
        continuityProof: data.continuityProof,
        merkleProofs,
        cached: data.cached,
        generatedAt: new Date(data.generatedAt),
      } as BatchContinuityResponse;
    } catch (error) {
      if (axios.isAxiosError(error)) {
        throw new Error(`Failed to fetch batch proofs: ${error}`);
      } else {
        throw new Error(`Unexpected error: ${error}`);
      }
    }
  }

  async queryAttestedHeight(chainKey: number): Promise<number | undefined> {
    try {
      const res = await this.client.get(`${API_ATTESTED_HEIGHT_PATH}/${chainKey}`);
      return res.data.attestedHeight;
    } catch (error) {
      if (axios.isAxiosError(error)) {
        throw new Error(`Failed to fetch attested height: ${error}`);
      } else {
        throw new Error(`Unexpected error: ${error}`);
      }
    }
  }
}

/**
 * Proof provider that fetches proofs from a remote service.
 * It uses an HTTP client to communicate with the API service.
 * Timeout can be configured for the HTTP requests.
 *
 * Service is expected to expose an HTTP endpoint at `/api/v1/proof-by-tx/{chainKey}/{transactionHash}`
 *
 */
export class ProofBuilder implements ProofProvider {
  private client: ApiClient;

  private chainKey: number;

  constructor(chainKey: number, builderUrl: string, timeout: number = 10000) {
    this.chainKey = chainKey;
    this.client = new ApiClient(builderUrl, timeout);
  }

  /**
   * Generates a proof for the given transaction hash by querying the remote proof API service.
   *
   * Transaction hash should be provided as a hex string, and should exists in the source chain for which the
   * chainKey was specified during the generator construction.
   *
   * @param transactionHash - The hash of the transaction to generate a proof for, as a hex string.
   * @returns A promise that resolves to the result of the proof generation
   * @throws Error if the API request fails
   *
   * @example
   * ```typescript
   * const chainKey = 2; // Example chain key
   * const builderUrl = 'https://prover.cc3-testnet.creditcoin.network';
   * const proofBuilder = new proofProvider.service.ProofBuilder(chainKey, builderUrl);
   * const proofResult = await proofBuilder.getProof(transactionHash);
   * // Results in:
   * // {
   * //   success: true,
   * //   data: {
   * //     chainKey: 2,
   * //     headerNumber: 123456,
   * //     txIndex: 0,
   * //     txHash: '0xabc...',
   * //     txBytes: '0x123...',
   * //     continuityProof: {
   * //       lowerEndpointDigest: '0xdef...',
   * //       roots: [ '0x789...', '0x456...', ... ]
   * //     },
   * //     merkleProof: {
   * //       root: '0x789...',
   * //       siblings: [ { hash: '0xabc...', isLeft: true }, ... ]
   * //     cached: false,
   * //     generatedAt: '2024-01-01T00:00:00Z'
   * //   }
   * // }
   * ```
   */
  public async getProof(transactionHash: string): Promise<ProofResult> {
    try {
      const continuityProof = await this.client.queryProofFor(this.chainKey, transactionHash);

      return { success: true, data: continuityProof };
    } catch (error) {
      return { success: false, error: `Failed to generate proof via API: ${error}` };
    }
  }

  /**
   * Generates proofs for a batch of transaction hashes by querying the remote proof API service.
   *
   * Transaction hashes should be provided as an array of hex strings, and should exist in the source chain for which the
   * chainKey was specified during the generator construction.
   *
   * @param transactionHashes - An array of transaction hashes to generate proofs for, as hex strings.
   * @returns A promise that resolves to an array of results for each proof generation
   *
   * @example
   * ```typescript
   * const chainKey = 2;
   * const builderUrl = 'https://prover.cc3-testnet.creditcoin.network';
   * const proofBuilder = new proofProvider.service.ProofBuilder(chainKey, builderUrl);
   * const batchProofResult = await proofBuilder.getBatchProof([transactionHash1, transactionHash2, transactionHash3]);
   * // Results in:
   * // [
   * //   {
   * //     success: true,
   * //     data: {
   * //       chainKey: 2,
   * //       fromHeader: 123456,
   * //       toHeader: 123458,
   * //       continuityProof: {
   * //         lowerEndpointDigest: '0xdef...',
   * //         roots: [ '0x789...', '0x321...', ..., '0x7a3...' ]
   * //       },
   * //       merkleProofs: {
   * //         '123456': {
   * //           '0': {
   * //             txHash: '0xabc...',
   * //             txBytes: '0x123...',
   * //             merkleProof: {
   * //               root: '0x789...',
   * //               siblings: [ { hash: '0xabc...', isLeft: true }, ... ]
   * //             }
   * //           },
   * //           '1': {
   * //             txHash: '0xdef...',
   * //             txBytes: '0x456...',
   * //             merkleProof: {
   * //               root: '0x321...',
   * //               siblings: [ { hash: '0xd3f...', isLeft: true }, ... ]
   * //             }
   * //           }
   * //         },
   * //         '123458': {
   * //           '0': {
   * //             txHash: '0x789...',
   * //             txBytes: '0x789...',
   * //             merkleProof: {
   * //               root: '0x7a3...',
   * //               siblings: [ { hash: '0x5b2...', isLeft: true }, ... ]
   * //             }
   * //           }
   * //         }
   * //       },
   * //       cached: false,
   * //       generatedAt: '2024-01-01T00:00:00Z'
   * //     }
   * //   },
   * // ]
   * ```
   */
  public async getBatchProof(transactionHashes: string[]): Promise<BatchProofResult> {
    try {
      const continuityProof = await this.client.queryProofBatchFor(this.chainKey, transactionHashes);

      return { success: true, data: continuityProof };
    } catch (error) {
      return { success: false, error: `Failed to generate batch proof via API: ${error}` };
    }
  }

  /**
   * Waits until a specific block height is attested *and available in the proof builder*.
   *
   * This method polls the proof builder (`/api/v1/attested-height/{chainKey}`) until the
   * requested `targetHeight` has been attested and ingested into the service's in-memory cache.
   *
   * ⚠️ This should be called before submitting proof requests. Attempting to generate a proof
   * for a block that has not yet been attested (or fully indexed by the service) may result in
   * failures or retriable errors.
   *
   * @param chainKey - The unique identifier for the source chain on the Creditcoin network
   * @param targetHeight - The block height to wait for
   * @param pollIntervalMs - Interval between polling attempts (default: 15 seconds)
   * @param waitTimeoutMs - Maximum time to wait before timing out (default: 15 minutes)
   * @param extraDelayMs - Extra wait time to ensure consistency in case we request the proof from a different proof builder service due to load balancing
   *
   * @returns A Promise that resolves once the target height is attested and available
   *
   * @throws Error if the timeout is exceeded before the height becomes available
   *
   * @example
   * ```typescript
   * const chainKey = 11;
   * const targetHeight = 10_000;
   *
   * const proofBuilder = new proofProvider.service.ProofBuilder(chainKey, apiUrl);
   *
   * // Wait until the proof builder service is ready to serve proofs at this height
   * await proofBuilder.waitUntilHeightAttested(chainKey, targetHeight);
   *
   * // Safe to request proofs at or below targetHeight
   * const proof = await proofBuilder.getProof(txHash);
   * ```
   *
   * @remarks
   * - This method relies on the proof builder service’s internal attestation cache,
   *   not directly on-chain data or precompiles.
   * - There may be a delay between on-chain finalization and availability via this API.
   * - The polling interval and timeout should be tuned based on expected network conditions.
   */
  public async waitUntilHeightAttested(
    chainKey: number,
    targetHeight: number,
    pollIntervalMs: number = 15000,
    waitTimeoutMs: number = 900000, // 15 minutes
    extraDelayMs: number = 5000,
  ): Promise<void> {
    const startTime = Date.now();

    while (true) {
      if (Date.now() - startTime > waitTimeoutMs) {
        throw new Error(`Timeout waiting for height ${targetHeight} to be attested on chain key ${chainKey}`);
      }

      const latestAttestedHeight = await this.client.queryAttestedHeight(chainKey);
      if (latestAttestedHeight == null) {
        console.warn(`⚠️ No attested height in prover cache for chain key ${chainKey}. Retrying...`);
      } else if (latestAttestedHeight >= targetHeight) {
        // Add delay in case of inconsistency between proof builder services
        await new Promise((resolve) => setTimeout(resolve, extraDelayMs));
        return;
      } else {
        console.debug(
          `Height ${targetHeight} not yet attested and in proof builder service cache for chain key ${chainKey}. Latest height: ${latestAttestedHeight}. Retrying in ${pollIntervalMs}ms...`,
        );
      }

      await new Promise((resolve) => setTimeout(resolve, pollIntervalMs));
    }
  }
}
