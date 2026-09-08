import { TransactionReceipt } from 'ethers';
import { abiEncode as abiEncodeV1 } from './v1';
import { TransactionWithRaw } from '../common';

export enum EncodingVersion {
  V1 = 1,
}

export type EncodingResult = {
  types: string[];
  abi: string;
};

export function abiEncode(
  tx: TransactionWithRaw,
  rx: TransactionReceipt,
  encoding: EncodingVersion = EncodingVersion.V1,
): EncodingResult {
  switch (encoding) {
    case EncodingVersion.V1:
      return abiEncodeV1(tx, rx);
    default:
      return abiEncodeV1(tx, rx);
  }
}
