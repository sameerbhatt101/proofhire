import { ContinuityProof } from '..';
import { ChainInfoProvider, ContinuityBounds } from '../../chain-info';

import { EncodingVersion } from '../../encoding';

import { computeDigestOf, computeMerkleRootOfBlock } from '../merkle';
import { BlockProvider } from './block-provider';

export class AttestationBlock {
  public blockNumber: number;
  public root: string;
  public digest: string;
  public prevDigest: string;

  constructor(blockNumber: number, root: string, digest: string, prevDigest: string) {
    this.blockNumber = blockNumber;
    this.root = root;
    this.digest = digest;
    this.prevDigest = prevDigest;
  }
}

export class ContinuityProofBuilder {
  private blockProvider: BlockProvider;
  private chainInfoProvider: ChainInfoProvider;

  private chainKey: number;
  private encoding: EncodingVersion;

  constructor(
    blockProvider: BlockProvider,
    chainInfoProvider: ChainInfoProvider,
    chainKey: number,
    encoding: EncodingVersion,
  ) {
    this.blockProvider = blockProvider;
    this.chainInfoProvider = chainInfoProvider;

    this.chainKey = chainKey;
    this.encoding = encoding;
  }

  /**
   * Creates a ContinuityProof from an array of AttestationBlocks.
   *
   * Blocks are expected to be in order from **lowest to highest block number** and to be contiguous.
   *
   * @param blocks Array of AttestationBlocks to convert, ordered by block number
   * @returns ContinuityProof object with lowerEndpointDigest and merkle roots
   * @throws Error if blocks are not ordered or contiguous
   *
   * @example
   * ```typescript
   * const blocks = [
   *   new AttestationBlock(100, '0xroot1', '0xdigest1', '0xprev1'),
   *   new AttestationBlock(101, '0xroot2', '0xdigest2', '0xdigest1'),
   *   new AttestationBlock(102, '0xroot3', '0xdigest3', '0xdigest2')
   * ];
   *
   * const proof = ContinuityProofBuilder.createFrom(blocks);
   * // Result: {
   * //   lowerEndpointDigest: '0xprev1',
   * //   roots: ['0xroot1', '0xroot2', '0xroot3']
   * // }
   * ```
   */
  public static createFrom(blocks: AttestationBlock[]): ContinuityProof {
    if (blocks.length === 0) {
      return { lowerEndpointDigest: '', roots: [] };
    }

    // Validate blocks are ordered and contiguous
    for (let i = 1; i < blocks.length; i++) {
      const prev = blocks[i - 1];
      const curr = blocks[i];

      if (curr.blockNumber !== prev.blockNumber + 1) {
        throw new Error(`Blocks are not contiguous: gap between ${prev.blockNumber} and ${curr.blockNumber}`);
      }

      if (curr.prevDigest !== prev.digest) {
        throw new Error(`Block digest chain broken at block ${curr.blockNumber}`);
      }
    }

    // The lowerEndpointDigest is the prev_digest of the first block
    const lowerEndpointDigest = blocks[0].prevDigest;

    // Extract merkle roots from blocks
    const continuityRoots: string[] = blocks.map((b) => b.root);

    return {
      lowerEndpointDigest,
      roots: continuityRoots,
    };
  }

  /**
   * Builds a ContinuityProof for a block height range.
   *
   * Building the proof requires fetching attestations and checkpoints from the chain,
   * determining the appropriate bounds, and constructing the continuity blocks.
   *
   * Because of this, the method is asynchronous and may take some time to complete.
   *
   * Additionally, the method performs various validations to ensure the proof can be built.
   *
   * If the proof cannot be built (e.g. no attestations exist, bounds cannot be found, etc),
   * **the method will throw an error**.
   *
   * @param fromHeight The starting block height for which to build the continuity proof (must be >= attestation genesis height)
   * @param toHeight The ending block height for which to build the continuity proof (must be > fromHeight) or null to build only for fromHeight
   * @returns A Promise that resolves to a ContinuityProof object representing the proof for the given height range
   * @throws Error if fromHeight is below genesis height, bounds cannot be found, or chain data is unavailable
   *
   * @example
   * ```typescript
   * const builder = new ContinuityProofBuilder(
   *   blockProvider,
   *   chainInfoProvider,
   *   chainKey,
   *   EncodingVersion.V1
   * );
   *
   * try {
   *   const proof = await builder.createForHeights(12345);
   *   console.log('Proof created:', proof);
   *   // Use proof for verification or submission
   * } catch (error) {
   *   console.error('Failed to build proof:', error.message);
   * }
   * ```
   */
  public async createForHeights(fromHeight: number, toHeight: number | null = null): Promise<ContinuityProof> {
    const genesisHeight = await this.chainInfoProvider.getAttestationGenesisHeight(this.chainKey);
    if (fromHeight < genesisHeight) {
      throw new Error(
        `Cannot build continuity proof for height ${fromHeight} below attestation genesis height ${genesisHeight}`,
      );
    }

    if (toHeight !== null && toHeight <= fromHeight) {
      throw new Error(`toHeight ${toHeight} must be greater than fromHeight ${fromHeight}`);
    }

    // Fetch attestation bounds from the attestation provider
    const fromBounds = await this.chainInfoProvider.getContinuityBounds(this.chainKey, fromHeight);
    if (!fromBounds.isAttested) {
      throw new Error(
        `Cannot build continuity proof for height ${fromHeight} without both lower and upper continuity bounds`,
      );
    }
    console.log(
      `Found attestation bounds for height ${fromHeight}: lower=${fromBounds.parentHeight}, upper=${fromBounds.childHeight}`,
    );

    if (toHeight !== null) {
      const toBounds = await this.chainInfoProvider.getContinuityBounds(this.chainKey, toHeight);
      if (!toBounds.isAttested) {
        throw new Error(
          `Cannot build continuity proof for height ${toHeight} without both lower and upper continuity bounds`,
        );
      }
      console.log(
        `Found attestation bounds for height ${toHeight}: lower=${toBounds.parentHeight}, upper=${toBounds.childHeight}`,
      );

      const combinedBounds: ContinuityBounds = {
        parentHeight: fromBounds.parentHeight,
        parentHash: fromBounds.parentHash,
        parentIsAttestation: fromBounds.parentIsAttestation,
        childHeight: toBounds.childHeight,
        childHash: toBounds.childHash,
        childIsAttestation: toBounds.childIsAttestation,
        isAttested: fromBounds.isAttested && toBounds.isAttested,
      };

      // Using those bounds build the continuity blocks
      const blocks: AttestationBlock[] = await this.buildAndTrimContinuityFor(fromHeight, combinedBounds);
      console.log(`Built ${blocks.length} continuity blocks for height ${fromHeight}`);
      // Finally convert to ContinuityProof
      return ContinuityProofBuilder.createFrom(blocks);
    } else {
      // Using those bounds build the continuity blocks
      const blocks: AttestationBlock[] = await this.buildAndTrimContinuityFor(fromHeight, fromBounds);
      console.log(`Built ${blocks.length} continuity blocks for height ${fromHeight}`);
      // Finally convert to ContinuityProof
      return ContinuityProofBuilder.createFrom(blocks);
    }
  }

  private async buildAndTrimContinuityFor(queryHeight: number, bounds: ContinuityBounds): Promise<AttestationBlock[]> {
    const latestBlockNumber = await this.blockProvider.getBlockNumber();

    // If latest block number is less than query height, we cannot build the proof since we should not
    // have attestations for future blocks
    if (latestBlockNumber < queryHeight) {
      throw new Error(`Latest block number ${latestBlockNumber} is less than query height ${queryHeight}`);
    }

    // If upper bound is beyond latest block number, we cannot build the proof since we'll not be able
    // to get continuity blocks up to that height
    if (bounds.childHeight > latestBlockNumber) {
      throw new Error(
        `Cannot build continuity proof up to attestation/checkpoint at height ${bounds.childHeight} greater than latest block number ${latestBlockNumber}`,
      );
    }

    // Use upper bound as end height
    const endHeight = bounds.childHeight;

    // Build from attestation/checkpoint lower bound + 1 up to endHeight
    const buildStartHeight = bounds.parentHeight + 1;

    // Query and build continuity blocks
    const blocks = await this.buildContinuityBlocks(buildStartHeight, endHeight, bounds.parentHash);

    // Trim blocks to start from queryHeight
    const filteredBlocks = blocks.filter((b) => b.blockNumber >= queryHeight);

    if (filteredBlocks.length === 0) {
      throw new Error(`No continuity blocks found after trimming to query height ${queryHeight}`);
    }

    // Validate that trimmed blocks end at the upper attestation block
    const lastBlock = filteredBlocks[filteredBlocks.length - 1];
    if (lastBlock.blockNumber !== endHeight) {
      throw new Error(
        `Trimmed blocks don't end at upper attestation block: expected ${endHeight}, got ${lastBlock.blockNumber}`,
      );
    }

    return filteredBlocks;
  }

  private async buildContinuityBlocks(
    buildStartHeight: number,
    endHeight: number,
    lowerDigest: string,
  ): Promise<AttestationBlock[]> {
    const blockCount = endHeight - buildStartHeight + 1;

    if (blockCount < 1) {
      throw new Error('No blocks to build continuity proof for');
    }

    const blockNumbers = Array.from({ length: blockCount }, (_, i) => buildStartHeight + i);

    let blocksRetrieved = 0;
    let blockPromises = [];

    // Add delay between request batches to avoid overwhelming the provider
    const blocksWithReceipt = [];
    for (const blockNumber of blockNumbers) {
      blockPromises.push(this.blockProvider.getBlockWithReceipts(blockNumber));
      blocksRetrieved++;

      if (blockPromises.length % 20 === 0) {
        console.log(`Retrieved ${blocksRetrieved}/${blockCount} blocks for continuity proof...`);

        const blocks = await Promise.all(blockPromises);

        for (const block of blocks) {
          if (block) {
            blocksWithReceipt.push(block);
          }
        }

        blockPromises = [];

        // Small delay to prevent rate limiting
        await new Promise((resolve) => setTimeout(resolve, 200));
      }
    }

    if (blockPromises.length > 0) {
      console.log(`Retrieved ${blocksRetrieved}/${blockCount} blocks for continuity proof...`);

      const blocks = await Promise.all(blockPromises);

      for (const block of blocks) {
        if (block) {
          blocksWithReceipt.push(block);
        }
      }
    }

    let prevDigest = lowerDigest;
    // Now we need to get the continuity proof for the blocks
    const continuityBlocks = blocksWithReceipt.map(({ block, transactions, receipts }) => {
      const orderedReceipts = receipts.sort((a, b) => a.index - b.index);
      const orderedTransactions = transactions.sort((a, b) => a!.formatted.index - b!.formatted.index);
      const merkleRoot = computeMerkleRootOfBlock(orderedTransactions, orderedReceipts, this.encoding);
      const digest = computeDigestOf(block.number, merkleRoot, prevDigest);
      const continuityBlock = new AttestationBlock(block.number, merkleRoot, digest, prevDigest);

      prevDigest = digest;

      return continuityBlock;
    });

    return continuityBlocks;
  }
}
