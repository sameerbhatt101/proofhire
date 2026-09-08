import { Block, JsonRpcApiProvider, TransactionReceipt } from 'ethers';
import { getTransactionWithRaw, RawTransactionResponse, TransactionWithRaw } from '../../encoding';

export interface BlockWithReceipts {
  block: Block;
  transactions: TransactionWithRaw[];
  receipts: TransactionReceipt[];
}

/**
 * Abstract interface for an Ethereum-based block provider.
 */
export interface BlockProvider {
  getBlockNumber(): Promise<number>;
  getTransaction(transactionHash: string): Promise<TransactionWithRaw | null>;
  getBlockWithReceipts(blockNumber: number): Promise<BlockWithReceipts | null>;
}

/**
 * Simple implementation of BlockProvider using an implementation of ethers JsonRpcApiProvider.
 *
 * Has no caching or optimizations.
 */
export class SimpleBlockProvider implements BlockProvider {
  private rpc: JsonRpcApiProvider;

  constructor(rpc: JsonRpcApiProvider) {
    this.rpc = rpc;
  }

  public getBlockNumber(): Promise<number> {
    return this.rpc.getBlockNumber();
  }

  public async getTransaction(transactionHash: string): Promise<TransactionWithRaw | null> {
    return getTransactionWithRaw(this.rpc, transactionHash);
  }

  public async getBlockWithReceipts(blockNumber: number): Promise<BlockWithReceipts | null> {
    // just slow down a bit to let the RPC cool down.
    await new Promise((resolve) => setTimeout(resolve, 500));

    // Not in cache, fetch from RPC
    // Get raw block data with transactions prefetched
    let blockDataRaw: any;
    try {
      blockDataRaw = await this.rpc.send('eth_getBlockByNumber', [`0x${blockNumber.toString(16)}`, true]);

      if (!blockDataRaw) {
        console.error(`Block ${blockNumber} not found`);
        return null;
      }
    } catch (e) {
      console.error(`Error fetching block ${blockNumber}: ${(e as Error).message}`);
      return null;
    }

    // Wrap transactions into TransactionWithRaw objects
    const transactions = await Promise.all(
      blockDataRaw.transactions.map(async (transaction: any) => {
        const formattedTx = this.rpc._wrapTransactionResponse(transaction, await this.rpc.getNetwork());
        // We map the raw yParity values from the JSON response
        // to a numeric value in RawAuthorization array
        const mappendList =
          transaction.authorizationList?.map((auth: any) => ({
            yParity: Number(auth.yParity),
          })) || null;
        const rawTx = new RawTransactionResponse(mappendList);

        return new TransactionWithRaw(formattedTx, rawTx);
      }),
    );

    // just slow down a bit to let the RPC cool down.
    await new Promise((resolve) => setTimeout(resolve, 500));

    // Get raw receipts data
    let recepitsRaw: any;
    try {
      recepitsRaw = await this.rpc.send('eth_getBlockReceipts', [`0x${blockNumber.toString(16)}`]);

      if (!recepitsRaw) {
        console.error(`Receipts for block ${blockNumber} not found`);
        return null;
      }
    } catch (e) {
      console.error(`Error fetching receipts for block ${blockNumber}: ${(e as Error).message}`);
      return null;
    }

    // Wrap into ethers objects for use using provider's wrap methods
    const block = (this.rpc as any)._wrapBlock(blockDataRaw, true);
    const receipts = recepitsRaw.map((r: any) => this.rpc._wrapTransactionReceipt(r, this.rpc._network));

    return { block, transactions, receipts };
  }
}
