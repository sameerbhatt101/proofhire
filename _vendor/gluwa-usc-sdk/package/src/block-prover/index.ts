import {
  Contract,
  ContractMethod,
  ContractTransactionResponse,
  InterfaceAbi,
  JsonRpcApiProvider,
  Overrides,
  Signer,
} from 'ethers';

import BlockProverABI from './block_prover.json';
import { ContinuityProof } from '../proof-provider';
import { TransactionMerkleProof } from '../proof-provider/merkle';

const contractABI = BlockProverABI as unknown as InterfaceAbi;

export interface BlockProvingProvider {
  computeTransactionIndex(merkleProof: TransactionMerkleProof): Promise<number>;
  verifySingle(
    chainKey: number,
    height: number,
    encodedTransaction: string,
    merkleProof: TransactionMerkleProof,
    continuityProof: ContinuityProof,
  ): Promise<boolean>;
  verifyAndEmitSingle(
    signer: Signer,
    chainKey: number,
    height: number,
    encodedTransaction: string,
    merkleProof: TransactionMerkleProof,
    continuityProof: ContinuityProof,
    overrides?: Overrides,
  ): Promise<ContractTransactionResponse>;
  verifyBatch(
    chainKey: number,
    heights: number[],
    encodedTransaction: string[],
    merkleProofs: TransactionMerkleProof[],
    sharedProof: ContinuityProof,
  ): Promise<boolean>;
  verifyAndEmitBatch(
    signer: Signer,
    chainKey: number,
    heights: number[],
    encodedTransaction: string[],
    merkleProofs: TransactionMerkleProof[],
    sharedProof: ContinuityProof,
    overrides?: Overrides,
  ): Promise<ContractTransactionResponse>;
}

/**
 * Default address for the ChainInfo precompile contract
 */
export const BLOCK_PROVER_PRECOMPILE_ADDRESS = '0x0000000000000000000000000000000000000FD2';

const CALCULATE_TX_INDEX = 'calculateTxIndex((bytes32,(bytes32,bool)[]))';
const VERIFY_SINGLE = 'verify(uint64,uint64,bytes,(bytes32,(bytes32,bool)[]),(bytes32,bytes32[]))';
const VERIFY_AND_EMIT_SINGLE = 'verifyAndEmit(uint64,uint64,bytes,(bytes32,(bytes32,bool)[]),(bytes32,bytes32[]))';
const VERIFY_BATCH = 'verify(uint64,uint64[],bytes[],(bytes32,(bytes32,bool)[])[],(bytes32,bytes32[]))';
const VERIFY_AND_EMIT_BATCH = 'verifyAndEmit(uint64,uint64[],bytes[],(bytes32,(bytes32,bool)[])[],(bytes32,bytes32[]))';

/**
 * Implementation of BlockProvingProvider using the precompile contract on Creditcoin.
 *
 * The prover allows verifying transaction inclusion and block continuity proofs on-chain.
 *
 * It provides two main methods: `verifySingle` for single transaction proofs and `verifyBatch` for batch proofs.
 * Both additionally support an `emitEvent` flag to trigger event emission upon successful verification.
 *
 */
export class PrecompileBlockProver implements BlockProvingProvider {
  public blockProverContract: Contract;

  /**
   * Creates a new PrecompileBlockProver instance
   * @param rpc - The JSON-RPC API provider for blockchain communication
   * @param blockProverPrecompile - The address of the BlockProver precompile contract (defaults to standard address)
   */
  constructor(rpc: JsonRpcApiProvider, blockProverPrecompile: string = BLOCK_PROVER_PRECOMPILE_ADDRESS) {
    this.blockProverContract = new Contract(blockProverPrecompile, contractABI, rpc);
  }

  /**
   * Calculates the transaction index within a block using the provided Merkle proof.
   *
   * @param merkleProof - The Merkle proof for the transaction inclusion
   * @returns The index of the transaction within the block
   * @throws Error if the computation call fails
   *
   * @example
   * ```typescript
   * const apiServerUrl = 'https://prover.cc3-testnet.creditcoin.network';
   * const proofBuilder = new proofProvider.service.ProofBuilder(chainKey, apiServerUrl);
   * const proofResult = await proofBuilder.getProof(transactionHash);
   * expect(proofResult.success).toBe(true);
   *
   * // Proof generation was successful, extract data and compute transaction index
   * const proofData = proofResult.data!;
   * const blockProver = new proofProvider.blockProver.PrecompileBlockProver(rpcProvider);
   * const txIndex = await blockProver.computeTransactionIndex(proofData.merkleProof);
   * console.log(`Transaction index within block: ${txIndex}`);
   * ```
   */
  public async computeTransactionIndex(merkleProof: TransactionMerkleProof): Promise<number> {
    const method: ContractMethod = this.blockProverContract.getFunction(CALCULATE_TX_INDEX);

    try {
      return await method.staticCall(merkleProof);
    } catch (error: any) {
      console.error(`Error trying to compute transaction index: ${error.shortMessage}`);
      throw error;
    }
  }

  /**
   * Verifies a single transaction proof on-chain.
   *
   * @param chainKey - The unique identifier for the source chain on the creditcoin network
   * @param height - The block height of the transaction being verified
   * @param encodedTransaction - The ABI-encoded transaction data using the `abiEncode` function or equivalent.
   * @param merkleProof - The Merkle proof for the transaction inclusion
   * @param continuityProof - The continuity proof for the block
   * @returns A promise resolving to true if verification succeeds, false otherwise
   * @throws Error if the verification call fails
   *
   * @example
   * ```typescript
   * const chainKey = 2; // Example chain key
   * const apiServerUrl = 'https://prover.cc3-testnet.creditcoin.network';
   * const proofBuilder = new proofProvider.service.ProofBuilder(chainKey, apiServerUrl);
   * const proofResult = await proofBuilder.getProof(transactionHash);
   * expect(proofResult.success).toBe(true);
   *
   * // Proof generation was successful, extract data and verify on-chain
   * const proofData = proofResult.data!;
   * const provingResult = await blockProver.verifySingle(
   *   proofData.chainKey,
   *   proofData.headerNumber,
   *   proofData.txBytes,
   *   proofData.merkleProof,
   *   proofData.continuityProof,
   * );
   * expect(provingResult).toBe(true);
   * ```
   */
  public async verifySingle(
    chainKey: number,
    height: number,
    encodedTransaction: string,
    merkleProof: TransactionMerkleProof,
    continuityProof: ContinuityProof,
  ): Promise<boolean> {
    const method: ContractMethod = this.blockProverContract.getFunction(VERIFY_SINGLE);

    try {
      return await method.staticCall(chainKey, height, encodedTransaction, merkleProof, continuityProof);
    } catch (error: any) {
      console.error(`Error trying to verify transaction: ${error.shortMessage}`);
      throw error;
    }
  }

  /**
   * Verifies a single transaction proof on-chain in a state-changing transaction
   * that emits a `TransactionVerified(uint64,uint64,uint64)` event on success.
   *
   * Unlike {@link verifySingle}, this method submits an actual transaction signed
   * by the provided signer. The returned {@link ContractTransactionResponse} can be
   * awaited via `.wait()` to obtain the receipt and parse the emitted event.
   *
   * The precompile reverts on failed verification, so a successful receipt implies
   * the proof was valid.
   *
   * @param signer - The signer used to submit the on-chain transaction
   * @param chainKey - The unique identifier for the source chain on the creditcoin network
   * @param height - The block height of the transaction being verified
   * @param encodedTransaction - The ABI-encoded transaction data using the `abiEncode` function or equivalent.
   * @param merkleProof - The Merkle proof for the transaction inclusion
   * @param continuityProof - The continuity proof for the block
   * @param overrides - Optional ethers `Overrides` (e.g. `nonce`, `gasLimit`, `maxFeePerGas`) forwarded to the contract call
   * @returns A promise resolving to the pending transaction response
   * @throws Error if the transaction submission fails
   *
   * @example
   * ```typescript
   * const wallet = new Wallet(privateKey, rpcProvider);
   * const tx = await blockProver.verifyAndEmitSingle(
   *   wallet,
   *   proofData.chainKey,
   *   proofData.headerNumber,
   *   proofData.txBytes,
   *   proofData.merkleProof,
   *   proofData.continuityProof,
   * );
   * const receipt = await tx.wait();
   * // Receipt contains the `TransactionVerified(chainKey, height, transactionIndex)` event log
   * ```
   */
  public async verifyAndEmitSingle(
    signer: Signer,
    chainKey: number,
    height: number,
    encodedTransaction: string,
    merkleProof: TransactionMerkleProof,
    continuityProof: ContinuityProof,
    overrides: Overrides = {},
  ): Promise<ContractTransactionResponse> {
    const contractWithSigner = this.blockProverContract.connect(signer) as Contract;
    const method: ContractMethod = contractWithSigner.getFunction(VERIFY_AND_EMIT_SINGLE);

    try {
      return await method(chainKey, height, encodedTransaction, merkleProof, continuityProof, overrides);
    } catch (error: any) {
      console.error(`Error trying to verify and emit transaction: ${error.shortMessage}`);
      throw error;
    }
  }

  /**
   * Verifies a batch of transaction proofs on-chain using a shared continuity proof.
   *
   * @param chainKey - The unique identifier for the source chain on the creditcoin network
   * @param heights - An array of block heights for each transaction being verified
   * @param encodedTransaction - An array of ABI-encoded transaction data using the `abiEncode` function or equivalent.
   * @param merkleProofs - An array of Merkle proofs for each transaction inclusion
   * @param sharedProof - A shared continuity proof for the batch of blocks
   * @returns A promise resolving to true if all verifications succeed, false otherwise
   * @throws Error if the verification call fails
   * @example
   * ```typescript
   * const chainKey = 2; // Example chain key
   * const apiServerUrl = 'https://prover.cc3-testnet.creditcoin.network';
   * const proofBuilder = new proofProvider.service.ProofBuilder(chainKey, apiServerUrl);
   * const transactionHashes = [
   *   '0xabc123...', // Example transaction hash 1
   *   '0xdef456...', // Example transaction hash 2
   * ];
   * const proofResults = await Promise.all(
   *   transactionHashes.map((txHash) => proofBuilder.getProof(txHash)),
   * );
   * proofResults.forEach((result) => expect(result.success).toBe(true));
   * const proofDatas = proofResults.map((res) => res.data!);
   *
   * // Extract proof data for batch verification
   * const heights = proofDatas.map((data) => data.headerNumber);
   * const encodedTransactions = proofDatas.map((data) => data.txBytes);
   * const merkleProofs = proofDatas.map((data) => data.merkleProof);
   *
   * // We merged together the continuity proofs into a single shared proof
   * const continuityProofs: [number, proofProvider.ContinuityProof][] = proofDatas.map((data) => [data.headerNumber, data.continuityProof]);
   * const mergedProof: ContinuityProof = ContinuityProofBuilder.mergeProofs(continuityProofs);
   *
   * const provingResult = await blockProver.verifyBatch(
   *   chainKey,
   *   heights,
   *   encodedTransactions,
   *   merkleProofs,
   *   mergedProof,
   * );
   * expect(provingResult).toBe(true);
   * ```
   * @returns
   */
  public async verifyBatch(
    chainKey: number,
    heights: number[],
    encodedTransaction: string[],
    merkleProofs: TransactionMerkleProof[],
    sharedProof: ContinuityProof,
  ): Promise<boolean> {
    const method: ContractMethod = this.blockProverContract.getFunction(VERIFY_BATCH);

    try {
      return await method.staticCall(chainKey, heights, encodedTransaction, merkleProofs, sharedProof);
    } catch (error: any) {
      console.error(`Error trying to verify transaction: ${error.shortMessage}`);
      throw error;
    }
  }

  /**
   * Verifies a batch of transaction proofs on-chain in a state-changing transaction
   * that emits a `TransactionVerified(uint64,uint64,uint64)` event for each successfully
   * verified transaction.
   *
   * Unlike {@link verifyBatch}, this method submits an actual transaction signed by the
   * provided signer. The returned {@link ContractTransactionResponse} can be awaited via
   * `.wait()` to obtain the receipt and parse the emitted events.
   *
   * The precompile reverts on failed verification, so a successful receipt implies all
   * proofs were valid.
   *
   * @param signer - The signer used to submit the on-chain transaction
   * @param chainKey - The unique identifier for the source chain on the creditcoin network
   * @param heights - An array of block heights for each transaction being verified
   * @param encodedTransaction - An array of ABI-encoded transaction data using the `abiEncode` function or equivalent.
   * @param merkleProofs - An array of Merkle proofs for each transaction inclusion
   * @param sharedProof - A shared continuity proof for the batch of blocks
   * @param overrides - Optional ethers `Overrides` (e.g. `nonce`, `gasLimit`, `maxFeePerGas`) forwarded to the contract call
   * @returns A promise resolving to the pending transaction response
   * @throws Error if the transaction submission fails
   *
   * @example
   * ```typescript
   * const wallet = new Wallet(privateKey, rpcProvider);
   * const tx = await blockProver.verifyAndEmitBatch(
   *   wallet,
   *   chainKey,
   *   heights,
   *   encodedTransactions,
   *   merkleProofs,
   *   mergedProof,
   * );
   * const receipt = await tx.wait();
   * // Receipt contains one `TransactionVerified(chainKey, height, transactionIndex)`
   * // event log per verified transaction.
   * ```
   */
  public async verifyAndEmitBatch(
    signer: Signer,
    chainKey: number,
    heights: number[],
    encodedTransaction: string[],
    merkleProofs: TransactionMerkleProof[],
    sharedProof: ContinuityProof,
    overrides: Overrides = {},
  ): Promise<ContractTransactionResponse> {
    const contractWithSigner = this.blockProverContract.connect(signer) as Contract;
    const method: ContractMethod = contractWithSigner.getFunction(VERIFY_AND_EMIT_BATCH);

    try {
      return await method(chainKey, heights, encodedTransaction, merkleProofs, sharedProof, overrides);
    } catch (error: any) {
      console.error(`Error trying to verify and emit transaction: ${error.shortMessage}`);
      throw error;
    }
  }
}
