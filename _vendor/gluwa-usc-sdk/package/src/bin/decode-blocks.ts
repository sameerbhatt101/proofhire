import { readdirSync, readFileSync, statSync } from 'fs';
import { glob } from 'glob';
import { Contract, WebSocketProvider } from 'ethers';
import type { InterfaceAbi } from 'ethers';
import { abiEncode } from '../encoding/abi';
import { getTransactionWithRaw } from '../encoding';
import { decoder } from '../utils';
import EvmV1DecoderABI from '../utils/evmV1DecoderAbi.json';

const sleep = (ms: number) => new Promise((resolve) => setTimeout(resolve, ms));

async function decodeFromDisk(pathToTxn: string, contract: Contract) {
  const encodedData = readFileSync(pathToTxn, {
    encoding: 'utf8',
    flag: 'r',
  }).trim();

  const decoded = await decoder.decodeEvmV1Transaction(encodedData, contract);
  console.log(`     decoded as type ${decoded.type}`);
}

async function decodeBlocks(creditcoinUrl: string, decoderLibraryAddress: string, pathToStore: string): Promise<void> {
  const contract = new Contract(
    decoderLibraryAddress,
    EvmV1DecoderABI as InterfaceAbi,
    new WebSocketProvider(creditcoinUrl),
  );

  const txnFiles = await glob('*/**.txt', { cwd: pathToStore, absolute: true });
  txnFiles.sort();
  const numFiles = txnFiles.length;
  console.log(`INFO: found ${numFiles} transactions to decode`);

  if (numFiles === 0) {
    throw new Error('0 files found to decode. Something is wrong. Please investigate');
  }

  for (const [idx, txFile] of txnFiles.entries()) {
    console.log(`>>>> ${idx}/${numFiles} decoding ${txFile}`);
    await decodeFromDisk(txFile, contract);
    // await sleep(50); // rate-limit ourselves
  }
  console.log(`DONE`);
  process.exit(0);
}

if (process.argv.length < 5) {
  console.error('node dist/bin/decode-blocks.js <ws://creditcoinRpcUrl> <evmV1DecoderAddress> <pathToStore>');
  process.exit(1);
}

const rpcUrl = process.argv[2] || 'ws://127.0.0.1:9944';
const evmV1DecoderAddress = process.argv[3];
const pathToStore = process.argv[4];

decodeBlocks(rpcUrl, evmV1DecoderAddress, pathToStore).catch((reason) => {
  console.error(reason);
  process.exit(1);
});
