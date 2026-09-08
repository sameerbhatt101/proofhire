import { Contract, InterfaceAbi, JsonRpcApiProvider } from 'ethers';
import { backOff, BackoffOptions } from 'exponential-backoff';

import ChainInfoABI from './chain_info.json';

const contractABI = ChainInfoABI as unknown as InterfaceAbi;

/**
 * Continuity bounds structure
 * @member parentHeight - The block number of the lower bound
 * @member parentHash - The block digest of the lower bound
 * @member parentIsAttestation - true if the lower bound is an attestation, false if it's a checkpoint
 * @member childHeight - The block number of the upper bound
 * @member childHash - The block digest of the upper bound
 * @member childIsAttestation - true if the upper bound is an attestation, false if it's a checkpoint
 * @member isAttested - true if the requested height is attested, false otherwise
 */
export interface ContinuityBounds {
  parentHeight: number;
  parentHash: string;
  parentIsAttestation: boolean;
  childHeight: number;
  childHash: string;
  childIsAttestation: boolean;
  isAttested: boolean;
}

/**
 * Individual chain information structure
 * @member chainKey - Unique identifier for the source chain on the creditcoin network
 * @member chainId - Native chain ID of the source chain
 * @member chainName - Human-readable name of the source chain on the creditcoin network
 * @member chainEncoding - Encoding version used by the source chain, used for transaction
 * encoding/decoding in the `abiEncode` function from `encoding/abi`
 */
export interface ChainInfo {
  chainKey: number;
  chainId: number;
  chainName: string;
  chainEncoding: number;
}

/**
 * Information about a specific query height.
 *
 * @member height - The height result
 * @member exists - Whether the height exists on the chain
 *
 */
export interface HeightResult {
  height: number;
  exists: boolean;
}

/**
 * Information about a specific query hash.
 *
 * @member hash - The hash result
 * @member exists - Whether the hash exists on the chain
 *
 */
export interface HashResult {
  hash: string;
  exists: boolean;
}

/**
 * Information about the latest attested block height and hash for a specific chain.
 *
 * If `exists` is false, it indicates that there are no attestations for the specified chain,
 * and the values of `height`, `hash` and `isAttestation` should not be considered usable.
 *
 * @member height - Block number of the latest attested block
 * @member hash - Block digest of the latest attested block
 * @member isAttestation - true if the digest corresponds to an attestation, false if it's a checkpoint
 * @member exists - Whether any attestation exists for the chain
 */
export interface HeightHash {
  height: number;
  hash: string;
  isAttestation: boolean;
  exists: boolean;
}

export interface ChainInfoProvider {
  getSupportedChains(): Promise<ChainInfo[]>;
  getSupportedChainByKey(chainKey: number): Promise<ChainInfo | null>;
  getLatestAttestedHeightAndHash(chainKey: number): Promise<HeightHash>;
  getAttestationGenesisHeight(chainKey: number): Promise<number>;
  getContinuityBounds(chainKey: number, height: number): Promise<ContinuityBounds>;
  waitUntilHeightAttested(
    chainKey: number,
    targetHeight: number,
    pollIntervalMs?: number,
    waitTimeoutMs?: number,
    extraDelayMs?: number,
  ): Promise<void>;
  getAttestationHeightForDigest(chainKey: number, digest: string): Promise<HeightResult>;
  getCheckpointForHeight(chainKey: number, height: number): Promise<HashResult>;
}

/**
 * Default address for the ChainInfo precompile contract
 */
export const CHAIN_INFO_PRECOMPILE_ADDRESS = '0x0000000000000000000000000000000000000fd3';

/**
 * Implementation of ChainInfoProvider using the ChainInfo precompile contract deployed on Creditcoin.
 *
 * This provider interacts with the precompile contract to fetch chain information, attestation bounds,
 * and other relevant data needed for proof generation and verification.
 *
 * Unless specified otherwise, it uses the default precompile address.
 */
export class PrecompileChainInfoProvider implements ChainInfoProvider {
  private chainInfoContract: Contract;

  /**
   * Creates a new PrecompileChainInfoProvider instance
   * @param rpc - The JSON-RPC API provider for blockchain communication
   * @param chainInfoPrecompile - The address of the ChainInfo precompile contract (defaults to standard address)
   */
  constructor(rpc: JsonRpcApiProvider, chainInfoPrecompile: string = CHAIN_INFO_PRECOMPILE_ADDRESS) {
    this.chainInfoContract = new Contract(chainInfoPrecompile, contractABI, rpc);
  }

  /**
   * Retrieves information about all supported source chains on the creditcoin network
   * @returns Promise resolving to an array of ChainInfo objects containing chain details
   * @throws Error if the contract call fails or returns invalid data
   *
   * @example
   * ```typescript
   * const chainInfoProvider = new PrecompileChainInfoProvider(rpcProvider);
   *
   * const supportedChains = await chainInfoProvider.getSupportedChains();
   * // Results in:
   * // [
   * //   { chainKey: 1, chainId: 1, chainName: 'Ethereum Mainnet', chainEncoding: 1 },
   * //   { chainKey: 2, chainId: 56, chainName: 'Binance Smart Chain', chainEncoding: 1 },
   * //   ...
   * // ]
   * ```
   */
  public async getSupportedChains(): Promise<ChainInfo[]> {
    try {
      const chains = await this.chainInfoContract.get_supported_chains({
        blockTag: 'finalized',
      });

      // Validate contract output structure before casting
      if (!chains || typeof chains !== 'object') {
        throw new Error('Invalid bounds returned from contract: expected object');
      }

      if (chains.length === 0) {
        return [];
      }

      const chainInfo: ChainInfo[] = chains.map((chainEntry: any) => {
        // Validate entry structure try to extract fields
        if (!chainEntry || typeof chainEntry !== 'object') {
          throw new Error('Invalid chain info entry: expected object');
        }

        if (chainEntry.length !== 4) {
          throw new Error(
            `Invalid chain info entry returned from contract: expected 4 fields, got ${chainEntry.length}`,
          );
        }

        return {
          chainKey: Number(chainEntry[0]),
          chainId: Number(chainEntry[1]),
          chainName: chainEntry[2], // TODO: Name decoding seems to be failing, investigate (you get all zeros currently)
          chainEncoding: Number(chainEntry[3]),
        };
      });

      return chainInfo;
    } catch (error: any) {
      throw new Error(`Error calling contract method: ${error}`);
    }
  }

  /**
   * Retrieves information about a specific supported source chain by its chain key
   * if the chain is not supported, returns null.
   *
   * @param chainKey - The unique identifier for the source chain on the creditcoin network
   * @returns Promise resolving to a ChainInfo object or null if the chain is not supported
   *
   * @throws Error if the contract call fails or returns invalid data
   * @example
   * ```typescript
   * const chainInfoProvider = new PrecompileChainInfoProvider(rpcProvider);
   * const chainKey = 2; // Example chain key
   * const chainInfo = await chainInfoProvider.getSupportedChainByKey(chainKey);
   * // Results in:
   * // { chainKey: 2, chainId: 31338, chainName: '0x416e76696c32', chainEncoding: 1 }
   * ```
   */
  public async getSupportedChainByKey(chainKey: number): Promise<ChainInfo | null> {
    try {
      const chainResult = await this.chainInfoContract.get_chain_by_key(chainKey, {
        blockTag: 'finalized',
      });

      // Validate contract output structure before casting
      if (!chainResult || typeof chainResult !== 'object') {
        throw new Error('Invalid bounds returned from contract: expected object');
      }

      if (chainResult.length !== 2) {
        return null;
      }

      const rawChainInfo = chainResult[0];
      const exists = chainResult[1];

      if (!exists) {
        return null;
      }

      if (!rawChainInfo || typeof rawChainInfo !== 'object') {
        throw new Error('Invalid chain info entry: expected object');
      }

      if (rawChainInfo.length !== 4) {
        throw new Error(
          `Invalid chain info entry returned from contract: expected 4 fields, got ${rawChainInfo.length}`,
        );
      }

      return {
        chainKey: Number(rawChainInfo[0]),
        chainId: Number(rawChainInfo[1]),
        chainName: rawChainInfo[2],
        chainEncoding: Number(rawChainInfo[3]),
      };
    } catch (error: any) {
      throw new Error(`Error calling contract method: ${error}`);
    }
  }

  /**
   * Retrieves the genesis height for attestations on a specific chain. **If the chain is not supported or
   * it has no configured genesis height, the method will return 0.**
   *
   * To check if a chain is supported, use the `getSupportedChains` method.
   *
   * @param chainKey - The unique identifier for the source chain on the creditcoin network
   * @returns Promise resolving to the genesis height as a bigint
   * @throws Error if the contract call fails or returns invalid data
   * @example
   * ```typescript
   * const chainInfoProvider = new PrecompileChainInfoProvider(rpcProvider);
   *
   * const chainKey = 2; // Example chain key
   *
   * const genesisHeight = await chainInfoProvider.getAttestationGenesisHeight(chainKey);
   * // Results in:
   * // 100
   * ```
   */
  public async getAttestationGenesisHeight(chainKey: number): Promise<number> {
    try {
      const genesisHeight = await this.chainInfoContract.get_attestation_genesis_height(chainKey, {
        blockTag: 'finalized',
      });

      // Validate output structure before returning
      if (typeof genesisHeight !== 'bigint') {
        throw new Error('Invalid data returned from contract: expected genesis height');
      }

      return Number(genesisHeight);
    } catch (error: any) {
      throw new Error(`Error calling contract method: ${error}`);
    }
  }

  /**
   * Gets the latest attested block height and hash for a specific chain
   * @param chainKey - The unique identifier for the source chain on the creditcoin network
   * @returns Promise resolving to HeightHash object containing height, hash, and existence status
   * @throws Error if the contract call fails or returns invalid data
   *
   * @example
   * ```typescript
   * const chainInfoProvider = new PrecompileChainInfoProvider(rpcProvider);
   *
   * const chainKey = 2; // Example chain key
   *
   * const latestAttestation = await chainInfoProvider.getLatestAttestedHeightAndHash(chainKey);
   * // Results in:
   * // {
   * //   height: 150,
   * //   hash: '0xabc123...',
   * //   exists: true
   * // }
   * ```
   */
  public async getLatestAttestedHeightAndHash(chainKey: number): Promise<HeightHash> {
    try {
      const heightHash = await this.chainInfoContract.get_latest_attestation_height_and_hash(chainKey, {
        blockTag: 'finalized',
      });

      // Validate bounds structure before casting
      if (!heightHash || typeof heightHash !== 'object') {
        throw new Error('Invalid data returned from contract: expected object');
      }

      if (heightHash.length !== 4) {
        throw new Error(`Invalid data returned from contract: expected 4 fields, got ${heightHash.length}`);
      }

      const heightHashObj: HeightHash = {
        height: Number(heightHash[0]),
        hash: heightHash[1],
        isAttestation: heightHash[2],
        exists: heightHash[3],
      };

      return heightHashObj;
    } catch (error: any) {
      throw new Error(`Error calling contract method: ${error}`);
    }
  }

  /**
   * Retrieves the continuity bounds for a specific chain and block height
   * @param chainKey - The unique identifier for the source chain on the creditcoin network
   * @param height - The block height to query
   * @returns Promise resolving to ContinuityBounds object containing the bounds details
   * @throws Error if the contract call fails or returns invalid data
   *
   * @example
   * ```typescript
   * const chainInfoProvider = new PrecompileChainInfoProvider(rpcProvider);
   *
   * const chainKey = 2; // Example chain key
   * const height = 100; // Example block height
   *
   * const continuityBounds = await chainInfoProvider.getContinuityBounds(chainKey, height);
   * // Results in:
   * // {
   * //   parentHeight: 95,
   * //   parentHash: '0xabc123...',
   * //   parentIsAttestation: true,
   * //   childHeight: 105,
   * //   childHash: '0xdef456...',
   * //   childIsAttestation: false,
   * //   isAttested: true
   * // }
   * ```
   */
  public async getContinuityBounds(chainKey: number, height: number): Promise<ContinuityBounds> {
    try {
      const bounds = await this.chainInfoContract.get_attestation_bounds(chainKey, height, {
        blockTag: 'finalized',
      });

      // Validate bounds structure before casting
      if (!bounds || typeof bounds !== 'object') {
        throw new Error('Invalid data returned from contract: expected object');
      }

      if (bounds.length !== 7) {
        throw new Error(`Invalid data returned from contract: expected 7 fields, got ${bounds.length}`);
      }

      const continuityBounds: ContinuityBounds = {
        parentHeight: Number(bounds[0]),
        parentHash: bounds[1],
        parentIsAttestation: bounds[2],
        childHeight: Number(bounds[3]),
        childHash: bounds[4],
        childIsAttestation: bounds[5],
        isAttested: bounds[6],
      };

      return continuityBounds;
    } catch (error: any) {
      throw new Error(`Error calling contract method: ${error}`);
    }
  }

  /**
   * This is a legacy implementation! Left unchanged to avoid impacting
   * existing users. For determining when to submit a proving request
   * at a particular height, use the implementation of
   * `waitUntilHeightAttested` in src/proof-provider/service/index.ts
   *
   * Waits until a specific block height is attested on a chain.
   * @param chainKey - The unique identifier for the source chain on the creditcoin network
   * @param targetHeight - The block height to wait for attestation
   * @param pollIntervalMs - How often to check for attestation (default: 5000ms)
   * @param waitTimeoutMs - Maximum time to wait before timing out (default: 60000ms)
   * @param extraDelayMs - Additional delay after attestation is detected to ensure data availability (default: 15000ms)
   * @returns Promise that resolves when the target height is attested
   * @throws Error if the timeout is exceeded before the height is attested
   *
   * @example
   * ```typescript
   * const chainInfoProvider = new PrecompileChainInfoProvider(rpcProvider);
   *
   * const supportedChains = await chainInfoProvider.getSupportedChains();
   * const chainKey = supportedChains[0].chainKey;
   * const targetHeight = 10;
   *
   * // Wait until the target height is attested on the specified chain before proving
   * await chainInfoProvider.waitUntilHeightAttested(chainKey, targetHeight);
   * // After the method resolves, transactions up to targetHeight can be safely proven
   * // with the block prover, using either the provided `PrecompileBlockProver`
   * // or through direct calls to the precompile contract.
   * console.log(`Height ${targetHeight} is now attested on chain key ${chainKey}`);
   * ```
   */
  public async waitUntilHeightAttested(
    chainKey: number,
    targetHeight: number,
    pollIntervalMs: number = 5000,
    waitTimeoutMs: number = 60000,
    extraDelayMs: number = 15000,
  ): Promise<void> {
    const startTime = Date.now();

    const backOffOptions = {
      delayFirstAttempt: true,
      jitter: 'full',
      numOfAttempts: 5,
      startingDelay: 100, // 100ms
    } as BackoffOptions;

    while (true) {
      const heightHash = await backOff(() => this.getLatestAttestedHeightAndHash(chainKey), backOffOptions);
      if (heightHash.exists && heightHash.height >= targetHeight) {
        await new Promise((resolve) => setTimeout(resolve, extraDelayMs));

        return;
      }

      console.debug(
        `Height ${targetHeight} not yet attested on chain key ${chainKey}. Latest attested height is ${heightHash.exists ? heightHash.height : 'N/A'}. Retrying in ${pollIntervalMs}ms...`,
      );

      if (Date.now() - startTime > waitTimeoutMs) {
        throw new Error(`Timeout waiting for height ${targetHeight} to be attested on chain key ${chainKey}`);
      }

      await new Promise((resolve) => setTimeout(resolve, pollIntervalMs));
    }
  }

  /**
   * Retrieves the attestation height for a specific block digest on a chain
   *
   * @param chainKey - The unique identifier for the source chain on the creditcoin network
   * @param digest - The block digest to query attestation height for
   * @returns A Promise that resolves to a HeightResult object containing the attestation height and existence flag
   * @throws Error if the contract call fails or returns invalid data
   *
   * @example
   * ```typescript
   * const chainInfoProvider = new PrecompileChainInfoProvider(rpcProvider);
   *
   * const chainKey = 2; // Example chain key
   * const digest = '0xabc123...'; // Example block digest
   *
   * const heightResult = await chainInfoProvider.getAttestationHeightForDigest(chainKey, digest);
   * // Results in:
   * // {
   * //   height: 150,
   * //   exists: true
   * // }
   * ```
   */
  public async getAttestationHeightForDigest(chainKey: number, digest: string): Promise<HeightResult> {
    try {
      const heightResult = await this.chainInfoContract.get_attestation_height_for_digest(chainKey, digest, {
        blockTag: 'finalized',
      });

      // Validate bounds structure before casting
      if (!heightResult || typeof heightResult !== 'object') {
        throw new Error('Invalid data returned from contract: expected object');
      }

      if (heightResult.length !== 2) {
        throw new Error(`Invalid data returned from contract: expected 2 fields, got ${heightResult.length}`);
      }

      const heightResultObj: HeightResult = {
        height: Number(heightResult[0]),
        exists: heightResult[1],
      };

      return heightResultObj;
    } catch (error: any) {
      throw new Error(`Error calling contract method: ${error}`);
    }
  }

  /**
   * Retrieves the checkpoint information for a specific block height on a chain
   *
   * @param chainKey - The unique identifier for the source chain on the creditcoin network
   * @param height - The block height to query checkpoint for
   * @returns A Promise that resolves to a HashResult object containing the checkpoint hash and existence flag
   * @throws Error if the contract call fails or returns invalid data
   *
   * @example
   * ```typescript
   * const chainInfoProvider = new PrecompileChainInfoProvider(rpcProvider);
   *
   * const chainKey = 2; // Example chain key
   * const height = 100; // Example block height
   *
   * const checkpoint = await chainInfoProvider.getCheckpointForHeight(chainKey, height);
   * // Results in:
   * // {
   * //   hash: '0xabc123...',
   * //   exists: true
   * // }
   * ```
   */
  public async getCheckpointForHeight(chainKey: number, height: number): Promise<HashResult> {
    try {
      const hashResult = await this.chainInfoContract.get_checkpoint_for_height(chainKey, height, {
        blockTag: 'finalized',
      });

      // Validate bounds structure before casting
      if (!hashResult || typeof hashResult !== 'object') {
        throw new Error('Invalid data returned from contract: expected object');
      }

      if (hashResult.length !== 2) {
        throw new Error(`Invalid data returned from contract: expected 2 fields, got ${hashResult.length}`);
      }

      const hashResultObj: HashResult = {
        hash: hashResult[0],
        exists: hashResult[1],
      };

      return hashResultObj;
    } catch (error: any) {
      throw new Error(`Error calling contract method: ${error}`);
    }
  }
}
