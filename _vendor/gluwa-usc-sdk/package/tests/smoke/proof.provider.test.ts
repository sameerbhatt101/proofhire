import { test, expect } from '@jest/globals';
import { Block, JsonRpcProvider, TransactionReceipt, TransactionResponse } from 'ethers';

import { proofProvider, chainInfo, blockProver } from '../../src';
import { EncodingVersion, TransactionWithRaw } from '../../src/encoding';

import { keccak256 } from 'ethers';

interface MockTransaction {
  index: number;
  blockNumber: number;
  blockHash: string;
  type: number;
  nonce: number;
  gasLimit: bigint;
  from: string;
  to: string;
  value: bigint;
  data: string;
  chainId: number;
  gasPrice: bigint;
  accessList: any[];
  signature: {
    yParity: number;
    r: string;
    s: string;
  };
}

interface MockTransactionReceipt {
  index: number;
  blockNumber: number;
  blockHash: string;
  status: number;
  gasUsed: bigint;
  logs: MockReceiptLog[];
  logsBloom: string;
}

interface MockReceiptLog {
  address: string;
  topics: string[];
  data: string;
}

interface MockBlock extends Block {
  transactions: string[];
  receipts: TransactionReceipt[];
  prefetchedTransactions: TransactionResponse[];
  getTransaction(indexOrHash: number | string): Promise<TransactionResponse>;
}

class MockBlockProvider implements proofProvider.raw.blockProvider.BlockProvider {
  private blockNumber: number = 1;

  private transactions: Map<string, TransactionWithRaw> = new Map();
  private blocks: Map<number, { block: Block; transactions: TransactionWithRaw[]; receipts: TransactionReceipt[] }> =
    new Map();

  constructor() {}

  public setBlockNumber(blockNumber: number) {
    this.blockNumber = blockNumber;
  }

  public async getBlockNumber(): Promise<number> {
    return this.blockNumber;
  }

  public async getTransaction(transactionHash: string): Promise<TransactionWithRaw | null> {
    return this.transactions.get(transactionHash) || null;
  }

  public addBlocks(startBlockNumber: number, count: number) {
    for (let i = 0; i <= count; i++) {
      const blockNumber = startBlockNumber + i;
      const blockHash = keccak256(Buffer.from(`block${blockNumber}`));
      const transactionHash = keccak256(Buffer.from(`tx${blockNumber}_0`));
      const transactions: string[] = [transactionHash];
      const receipts: MockTransactionReceipt[] = [
        {
          index: 0,
          blockNumber: blockNumber,
          blockHash: blockHash,
          status: 1,
          gasUsed: BigInt(21000),
          logs: [
            {
              address: keccak256(Buffer.from(`block${blockNumber}_0_log_address`)).slice(0, 42),
              topics: [
                keccak256(Buffer.from(`block${blockNumber}_0_log_topic1`)),
                keccak256(Buffer.from(`block${blockNumber}_0_log_topic2`)),
              ],
              data: keccak256(Buffer.from(`block${blockNumber}_0_log_data`)),
            },
          ],
          logsBloom: keccak256(Buffer.from(`block${blockNumber}_0_logs`)),
        },
      ];

      const transaction: TransactionResponse = {
        index: 0,
        blockNumber: blockNumber,
        blockHash: blockHash,
        type: 1,
        nonce: 0,
        gasLimit: BigInt(21000),
        from: keccak256(Buffer.from(`block${blockNumber}_0_from`)).slice(0, 42),
        to: keccak256(Buffer.from(`block${blockNumber}_0_to`)).slice(0, 42),
        value: BigInt(0),
        data: '0x',
        chainId: 0,
        gasPrice: BigInt(23),
        accessList: [],
        signature: {
          yParity: 0,
          r: '0x' + '00'.repeat(32),
          s: '0x' + '00'.repeat(32),
        },
      } as MockTransaction as unknown as TransactionResponse;
      const raw = { authorizationList: [] };
      const transactionWithRaw = new TransactionWithRaw(transaction, raw);
      this.transactions.set(transactionHash, transactionWithRaw);

      const block: MockBlock = {
        number: blockNumber,
        transactions: transactions,
        receipts: receipts as unknown as TransactionReceipt[],
        prefetchedTransactions: [transaction],
        getTransaction: async (indexOrHash: number | string): Promise<TransactionResponse> => {
          if (typeof indexOrHash === 'number') {
            const txHash = transactions[indexOrHash];
            return this.transactions.get(txHash)!.formatted;
          } else {
            return this.transactions.get(indexOrHash)!.formatted;
          }
        },
      } as MockBlock;

      this.blocks.set(blockNumber, { block, transactions: [transactionWithRaw], receipts: block.receipts });
    }
  }

  public async getBlockWithReceipts(
    blockNumber: number,
  ): Promise<{ block: Block; transactions: TransactionWithRaw[]; receipts: TransactionReceipt[] }> {
    const data = this.blocks.get(blockNumber);
    if (!data) {
      throw new Error(`Block ${blockNumber} not found`);
    }
    return data;
  }
}

class MockContinuityProvider implements chainInfo.ChainInfoProvider {
  private bound: chainInfo.ContinuityBounds | null = null;

  public setBound(bound: chainInfo.ContinuityBounds) {
    this.bound = bound;
  }

  public async getContinuityBounds(_chainKey: number, _height: number): Promise<chainInfo.ContinuityBounds> {
    return this.bound!;
  }

  public async getSupportedChains(): Promise<chainInfo.ChainInfo[]> {
    throw new Error('Method not implemented.');
  }

  public async getSupportedChainByKey(chainKey: number): Promise<chainInfo.ChainInfo | null> {
    throw new Error('Method not implemented.');
  }

  public async getLatestAttestedHeightAndHash(chainKey: number): Promise<chainInfo.HeightHash> {
    throw new Error('Method not implemented.');
  }
  public async getAttestationGenesisHeight(chainKey: number): Promise<number> {
    return 0;
  }

  public async waitUntilHeightAttested(
    _chainKey: number,
    _targetHeight: number,
    _pollIntervalMs: number = 1000,
    _waitTimeoutMs: number = 60000,
  ): Promise<void> {
    return;
  }

  public async getAttestationHeightForDigest(_chainKey: number, _digest: string): Promise<chainInfo.HeightResult> {
    throw new Error('Method not implemented.');
  }

  public async getCheckpointForHeight(_chainKey: number, _height: number): Promise<chainInfo.HeightHash> {
    throw new Error('Method not implemented.');
  }
}

test('RawProofBuilder: should return proof', async () => {
  // We create a bunch of mock blocks and transactions along with continuity bounds
  // Using those we will be able to generate a proof for a transaction

  const blockProvider = new MockBlockProvider();
  const continuityProvider = new MockContinuityProvider();

  blockProvider.addBlocks(0, 20);
  blockProvider.setBlockNumber(20);

  continuityProvider.setBound({
    parentHeight: 0,
    parentHash: '',
    parentIsAttestation: true,
    childHeight: 20,
    childHash: '',
    childIsAttestation: true,
    isAttested: true,
  });

  const block = await blockProvider.getBlockWithReceipts(11);
  const txHash = block.block.transactions[0];

  const rawBuilder = new proofProvider.raw.RawProofBuilder(1, blockProvider, continuityProvider, EncodingVersion.V1);

  const transactionHash = txHash;
  const result = await rawBuilder.getProof(transactionHash);

  // We expect a successful proof generation
  expect(result.success).toBe(true);
  expect(result.error).toBeUndefined();
});

test('RawProofBuilder: should return error for non-existent transaction', async () => {
  const blockProvider = new MockBlockProvider();
  const continuityProvider = new MockContinuityProvider();

  const rawBuilder = new proofProvider.raw.RawProofBuilder(1, blockProvider, continuityProvider, EncodingVersion.V1);

  const transactionHash = '0xac0974bec39a17e36ba4a6b4d238ff944bacb478cbed5efcae784d7bf4f2ff80';
  const result = await rawBuilder.getProof(transactionHash);

  // Expect an error since transaction does not exist
  expect(result.success).toBe(false);
  expect(result.error).toBe(`Failed to generate merkle proof: Transaction ${transactionHash} not found`);
});

test('RawProofBuilder: return error if no lower bound', async () => {
  // If no lower bound is found, we cannot build the continuity proof
  // so an error will be returned

  const blockProvider = new MockBlockProvider();
  const continuityProvider = new MockContinuityProvider();

  // We create blocks up to 10 and set current block number to 10
  blockProvider.addBlocks(0, 10);
  blockProvider.setBlockNumber(10);

  // We set only upper bound to 20
  continuityProvider.setBound({
    parentHeight: 0,
    parentHash: '',
    parentIsAttestation: false,
    childHeight: 20,
    childHash: '',
    childIsAttestation: true,
    isAttested: false,
  });

  // We try to generate a proof for the first transaction in block 10
  const block = await blockProvider.getBlockWithReceipts(10);
  const txHash = block.block.transactions[0];

  const rawBuilder = new proofProvider.raw.RawProofBuilder(1, blockProvider, continuityProvider, EncodingVersion.V1);

  const transactionHash = txHash;
  const result = await rawBuilder.getProof(transactionHash);

  // Expect an error since lower bound is missing
  expect(result.success).toBe(false);
  expect(result.error).toBe(
    'Failed to build continuity proof: Cannot build continuity proof for height 10 without both lower and upper continuity bounds',
  );
});

test('RawProofBuilder: return error if no upper bound', async () => {
  // If no upper bound is found, we cannot build the continuity proof
  // so an error will be returned

  const blockProvider = new MockBlockProvider();
  const continuityProvider = new MockContinuityProvider();

  // We create blocks up to 10 and set current block number to 10
  blockProvider.addBlocks(0, 10);
  blockProvider.setBlockNumber(10);

  // We set only lower bound to 0
  continuityProvider.setBound({
    parentHeight: 0,
    parentHash: '',
    parentIsAttestation: true,
    childHeight: 0,
    childHash: '',
    childIsAttestation: false,
    isAttested: false,
  });

  // We try to generate a proof for the first transaction in block 10
  const block = await blockProvider.getBlockWithReceipts(10);
  const txHash = block.block.transactions[0];

  const rawBuilder = new proofProvider.raw.RawProofBuilder(1, blockProvider, continuityProvider, EncodingVersion.V1);

  const transactionHash = txHash;
  const result = await rawBuilder.getProof(transactionHash);

  // Expect an error since upper bound is missing
  expect(result.success).toBe(false);
  expect(result.error).toBe(
    'Failed to build continuity proof: Cannot build continuity proof for height 10 without both lower and upper continuity bounds',
  );
});

test('RawProofBuilder: return error if upper bound is above current block height', async () => {
  // If latest block number is 10, but upper bound is 20 that means we cannot build the proof
  // since we won't be able to fetch the required blocks to build it, so an error will be returned

  const blockProvider = new MockBlockProvider();
  const continuityProvider = new MockContinuityProvider();

  // We create blocks up to 10 and set current block number to 10
  blockProvider.addBlocks(0, 10);
  blockProvider.setBlockNumber(10);

  // We set lower bound to 0 and upper bound to 20 meaning that we have attestations/checkpoints
  // all the way from block 0 to block 20
  continuityProvider.setBound({
    parentHeight: 0,
    parentHash: '',
    parentIsAttestation: true,
    childHeight: 20,
    childHash: '',
    childIsAttestation: true,
    isAttested: true,
  });

  // We try to generate a proof for the first transaction in block 10
  const block = await blockProvider.getBlockWithReceipts(10);
  const txHash = block.block.transactions[0];

  const rawBuilder = new proofProvider.raw.RawProofBuilder(1, blockProvider, continuityProvider, EncodingVersion.V1);

  const transactionHash = txHash;
  const result = await rawBuilder.getProof(transactionHash);

  // Expect an error since upper bound is above latest block number
  expect(result.success).toBe(false);
  expect(result.error).toBe(
    'Failed to build continuity proof: Cannot build continuity proof up to attestation/checkpoint at height 20 greater than latest block number 10',
  );
});

test.skip('E2E ProofProvider integration test', async () => {
  // Initialize block provider connected to local source ethereum chain
  const sourceChainRpc = 'http://localhost:8545';
  const ethProvider = new JsonRpcProvider(sourceChainRpc);
  const blockProvider = new proofProvider.raw.blockProvider.SimpleBlockProvider(ethProvider);

  // Continuity provider using precompile contract from local creditcoin chain
  const ccRpc = 'http://localhost:9944';
  const ccProvider = new JsonRpcProvider(ccRpc);
  const chainInfoProvider = new chainInfo.PrecompileChainInfoProvider(ccProvider);

  const chainKey = 2; // NOTE: Replace with your test chain key

  const chainInfos = await chainInfoProvider.getSupportedChains();
  console.log('Supported chains from continuity provider:', chainInfos);

  const chainResult = await chainInfoProvider.getSupportedChainByKey(chainKey);
  console.log(`Chain info for chain key ${chainKey}:`, chainResult);

  const genesisHeight = await chainInfoProvider.getAttestationGenesisHeight(chainKey);
  console.log(`Genesis attestation height for chain key ${chainKey}:`, genesisHeight);

  const latestHeightHash = await chainInfoProvider.getLatestAttestedHeightAndHash(chainKey);
  console.log(`Latest attested height and hash for chain key ${chainKey}:`, latestHeightHash);

  const continuityBounds = await chainInfoProvider.getContinuityBounds(chainKey, latestHeightHash.height);
  console.log(`Continuity bounds for latest attested height for chain key ${chainKey}:`, continuityBounds);

  const attestationHeightResult = await chainInfoProvider.getAttestationHeightForDigest(
    chainKey,
    latestHeightHash.hash,
  );
  console.log(`Attestation height result for latest attested hash for chain key ${chainKey}:`, attestationHeightResult);

  const checkpointDigest = await chainInfoProvider.getCheckpointForHeight(chainKey, genesisHeight);
  console.log(`Checkpoint digest for genesis height for chain key ${chainKey}:`, checkpointDigest);

  // Initialize BlockProver contract instance from local creditcoin chain
  const prover = new blockProver.PrecompileBlockProver(ccProvider);

  // NOTE: Replace with valid transaction hashes from your local source chain
  const txHash1 = '0x1fd15cc75e4ef16c7e4cec1d2b73e80a599aaa174e44e220fa14143da8ad76be';
  const txBlock1 = await ethProvider.getTransaction(txHash1).then((tx) => tx?.blockNumber);
  const txHash2 = '0x6fe777442b70a5511f3c443176ae860e50445bd93b663711717996a70c5022ab';
  const txBlock2 = await ethProvider.getTransaction(txHash2).then((tx) => tx?.blockNumber);

  console.log(`Transaction 1 is in block ${txBlock1}`);
  console.log(`Transaction 2 is in block ${txBlock2}`);

  // We await the highest block to be attested before generating proofs
  const blockToWait = Math.max(txBlock1!, txBlock2!);
  console.log(`Waiting for block ${blockToWait} to be attestated...`);
  await chainInfoProvider.waitUntilHeightAttested(chainKey, blockToWait);

  // First we test with the raw proof builder
  const rawproofProvider = new proofProvider.raw.RawProofBuilder(
    chainKey,
    blockProvider,
    chainInfoProvider,
    EncodingVersion.V1,
  );
  const rawProofResult = await rawproofProvider.getProof(txHash1);
  expect(rawProofResult.success).toBe(true);

  const proofData = rawProofResult.data!;

  const txIndex = await prover.computeTransactionIndex(proofData.merkleProof);
  console.log(`Calculated transaction index from merkle proof: ${txIndex}`);

  const proveResultRaw = await prover.verifySingle(
    proofData.chainKey,
    proofData.headerNumber,
    proofData.txBytes,
    proofData.merkleProof,
    proofData.continuityProof,
  );
  expect(proveResultRaw).toBe(true);

  // Then we test with the proof builder service
  const apiServerUrl = 'http://localhost:3100';
  const requestTimeout = 5000; // 5 seconds
  const apiProvider = new proofProvider.service.ProofBuilder(chainKey, apiServerUrl, requestTimeout);
  const apiProofResult_1 = await apiProvider.getProof(txHash1);
  expect(apiProofResult_1.success).toBe(true);

  const apiProofData_1 = apiProofResult_1.data!;
  const proveResultApi_1 = await prover.verifySingle(
    apiProofData_1.chainKey,
    apiProofData_1.headerNumber,
    apiProofData_1.txBytes,
    apiProofData_1.merkleProof,
    apiProofData_1.continuityProof,
  );
  expect(proveResultApi_1).toBe(true);

  const apiProofBatchResult = await apiProvider.getBatchProof([txHash1, txHash2]);
  expect(apiProofBatchResult.success).toBe(true);
  const batchProofData = apiProofBatchResult.data!;

  // Prepare batch proof data for verification by organizing it into arrays of headers, txBytes, and merkleProofs
  // corresponding to each transaction in the batch
  const headers = [];
  const txBytes = [];
  const merkleProofs = [];
  for (const [headerNumber, proofsMap] of batchProofData.merkleProofs.entries()) {
    for (const [_txIndex, proofEntry] of proofsMap.entries()) {
      headers.push(headerNumber);
      txBytes.push(proofEntry.txBytes);
      merkleProofs.push(proofEntry.merkleProof);
    }
  }

  const proveResultBatch = await prover.verifyBatch(
    batchProofData.chainKey,
    headers,
    txBytes,
    merkleProofs,
    batchProofData.continuityProof,
  );
  expect(proveResultBatch).toBe(true);
}, 120_000);
