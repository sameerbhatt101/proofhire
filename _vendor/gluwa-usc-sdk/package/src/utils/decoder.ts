import { Contract } from 'ethers';

/**
 * Reusable utility for decoding EVM v1 encoded transactions using the on-chain EvmV1Decoder library.
 * The library decodes (uint8, bytes[]) format where the first byte is the transaction type (0-4).
 *
 * @see EvmV1Decoder Solidity library - decodes ABI-encoded EVM transactions (types 0-4) and receipts
 */

// --- Type definitions matching the ABI structures ---

export interface CommonTxFields {
  nonce: bigint;
  gasLimit: bigint;
  from: string;
  toIsNull: boolean;
  to: string;
  value: bigint;
  data: string;
}

export interface LogEntry {
  address_: string;
  topics: string[];
  data: string;
}

export interface ReceiptFields {
  receiptStatus: number;
  receiptGasUsed: bigint;
  receiptLogs: LogEntry[];
  receiptLogsBloom: string;
}

export interface AccessListEntry {
  account: string;
  storageKeys: string[];
}

export interface AuthorizationListEntry {
  chainId: bigint;
  account: string;
  nonce: bigint;
  yParity: number;
  r: bigint;
  s: bigint;
}

export interface LegacyFields {
  gasPrice: bigint;
  v: bigint;
  r: string;
  s: string;
}

export interface Type1Fields {
  chainId: bigint;
  gasPrice: bigint;
  accessList: AccessListEntry[];
  yParity: number;
  r: string;
  s: string;
}

export interface Type2Fields {
  chainId: bigint;
  maxPriorityFeePerGas: bigint;
  maxFeePerGas: bigint;
  accessList: AccessListEntry[];
  yParity: number;
  r: string;
  s: string;
}

export interface Type3Fields {
  chainId: bigint;
  maxPriorityFeePerGas: bigint;
  maxFeePerGas: bigint;
  accessList: AccessListEntry[];
  maxFeePerBlobGas: bigint;
  blobVersionedHashes: string[];
  yParity: number;
  r: string;
  s: string;
}

export interface Type4Fields {
  chainId: bigint;
  maxPriorityFeePerGas: bigint;
  maxFeePerGas: bigint;
  accessList: AccessListEntry[];
  authorizationList: AuthorizationListEntry[];
  yParity: number;
  r: string;
  s: string;
}

export interface DecodedTransactionType0 {
  commonTx: CommonTxFields;
  type0: LegacyFields;
  receipt: ReceiptFields;
}

export interface DecodedTransactionType1 {
  commonTx: CommonTxFields;
  type1: Type1Fields;
  receipt: ReceiptFields;
}

export interface DecodedTransactionType2 {
  commonTx: CommonTxFields;
  type2: Type2Fields;
  receipt: ReceiptFields;
}

export interface DecodedTransactionType3 {
  commonTx: CommonTxFields;
  type3: Type3Fields;
  receipt: ReceiptFields;
}

export interface DecodedTransactionType4 {
  commonTx: CommonTxFields;
  type4: Type4Fields;
  receipt: ReceiptFields;
}

export type DecodedTransaction =
  | { type: 0; data: DecodedTransactionType0; gasUsed?: bigint }
  | { type: 1; data: DecodedTransactionType1; gasUsed?: bigint }
  | { type: 2; data: DecodedTransactionType2; gasUsed?: bigint }
  | { type: 3; data: DecodedTransactionType3; gasUsed?: bigint }
  | { type: 4; data: DecodedTransactionType4; gasUsed?: bigint };

/**
 * Options for {@link decodeEvmV1Transaction}.
 */
export interface DecodeOptions {
  /**
   * When true, the decoder will call `estimateGas` alongside each underlying
   * eth_call (`getTransactionType`, `isValidTransactionType`, and the
   * type-specific decoder), and accumulate the totals into
   * {@link DecodedTransaction.gasUsed}. Defaults to false.
   *
   * NOTE: enabling this roughly doubles the number of RPC round-trips since
   * each step issues a paired `estimateGas` request. The value/estimate pairs
   * are dispatched in parallel so the wall-clock impact is closer to 1× than
   * 2× when the RPC supports concurrent requests.
   */
  trackGas?: boolean;
}

function ensureHexPrefix(hex: string): string {
  if (!hex || typeof hex !== 'string') return '0x';
  return hex.startsWith('0x') ? hex : `0x${hex}`;
}

/**
 * Decodes EVM v1 encoded transaction bytes using the on-chain EvmV1Decoder library.
 *
 * @param txBytes - Hex string of encoded transaction (with or without 0x prefix)
 * @param contract - The deployed EvmV1Decoder library contract
 * @param opts - Optional behaviour flags; see {@link DecodeOptions}
 * @returns Decoded transaction with type and full data structure. When
 *          `opts.trackGas` is true the returned object also carries the
 *          aggregate `gasUsed` (sum of estimateGas across all underlying
 *          contract calls).
 */
export async function decodeEvmV1Transaction(
  txBytes: string,
  contract: Contract,
  opts: DecodeOptions = {},
): Promise<DecodedTransaction> {
  const encodedBytes = ensureHexPrefix(txBytes);
  if (encodedBytes === '0x' || encodedBytes.length < 4) {
    throw new Error('EvmV1Decoder: Empty or invalid txBytes');
  }

  const trackGas = opts.trackGas === true;
  let gasUsed = BigInt(0);

  // Helper: optionally pair a contract call with its estimateGas and
  // accumulate the estimate into the running total. When tracking is off,
  // behaviour is identical to the previous implementation (single eth_call).
  const callTracked = async <T>(fnName: string, ...args: unknown[]): Promise<T> => {
    if (!trackGas) {
      return (await contract.getFunction(fnName)(...args)) as T;
    }
    const fn = contract.getFunction(fnName);
    const [value, estimate] = await Promise.all([fn(...args), fn.estimateGas(...args)]);
    gasUsed += BigInt(estimate);
    return value as T;
  };

  // 1. Get transaction type (first byte of encoding)
  const txType = await callTracked<bigint>('getTransactionType', encodedBytes);
  const typeNum = Number(txType);

  if (typeNum < 0 || typeNum > 4) {
    throw new Error(`EvmV1Decoder: Invalid transaction type ${typeNum}`);
  }

  const isValid = await callTracked<boolean>('isValidTransactionType', typeNum);
  if (!isValid) {
    throw new Error(`EvmV1Decoder: Invalid transaction type ${typeNum}`);
  }

  // 2. Decode based on type
  switch (typeNum) {
    case 0: {
      const result = await callTracked<unknown>('decodeTransactionType0', encodedBytes);
      return { type: 0, data: normalizeType0(result), ...(trackGas ? { gasUsed } : {}) };
    }
    case 1: {
      const result = await callTracked<unknown>('decodeTransactionType1', encodedBytes);
      return { type: 1, data: normalizeType1(result), ...(trackGas ? { gasUsed } : {}) };
    }
    case 2: {
      const result = await callTracked<unknown>('decodeTransactionType2', encodedBytes);
      return { type: 2, data: normalizeType2(result), ...(trackGas ? { gasUsed } : {}) };
    }
    case 3: {
      const result = await callTracked<unknown>('decodeTransactionType3', encodedBytes);
      return { type: 3, data: normalizeType3(result), ...(trackGas ? { gasUsed } : {}) };
    }
    case 4: {
      const result = await callTracked<unknown>('decodeTransactionType4', encodedBytes);
      return { type: 4, data: normalizeType4(result), ...(trackGas ? { gasUsed } : {}) };
    }
    default:
      throw new Error(`EvmV1Decoder: Unsupported transaction type ${typeNum}`);
  }
}

// --- Normalizers for standalone type-specific field results ---

function normalizeAccessList(raw: unknown): AccessListEntry[] {
  return ((raw ?? []) as Array<{ account?: string; storageKeys?: string[] }>).map((e) => ({
    account: String(e.account ?? ''),
    storageKeys: Array.isArray(e.storageKeys) ? e.storageKeys.map(String) : [],
  }));
}

function normalizeAuthorizationList(raw: unknown): AuthorizationListEntry[] {
  return ((raw ?? []) as Array<Record<string, unknown>>).map((e) => ({
    chainId: BigInt(String(e.chainId ?? 0)),
    account: String(e.account ?? ''),
    nonce: BigInt(String(e.nonce ?? 0)),
    yParity: Number(e.yParity ?? 0),
    r: BigInt(String(e.r ?? 0)),
    s: BigInt(String(e.s ?? 0)),
  }));
}

function normalizeLegacyFields(t: Record<string, unknown>): LegacyFields {
  return {
    gasPrice: BigInt(String(t.gasPrice ?? 0)),
    v: BigInt(String(t.v ?? 0)),
    r: String(t.r ?? '0x'),
    s: String(t.s ?? '0x'),
  };
}

function normalizeType1Fields(t: Record<string, unknown>): Type1Fields {
  return {
    chainId: BigInt(String(t.chainId ?? 0)),
    gasPrice: BigInt(String(t.gasPrice ?? 0)),
    accessList: normalizeAccessList(t.accessList),
    yParity: Number(t.yParity ?? 0),
    r: String(t.r ?? '0x'),
    s: String(t.s ?? '0x'),
  };
}

function normalizeType2Fields(t: Record<string, unknown>): Type2Fields {
  return {
    chainId: BigInt(String(t.chainId ?? 0)),
    maxPriorityFeePerGas: BigInt(String(t.maxPriorityFeePerGas ?? 0)),
    maxFeePerGas: BigInt(String(t.maxFeePerGas ?? 0)),
    accessList: normalizeAccessList(t.accessList),
    yParity: Number(t.yParity ?? 0),
    r: String(t.r ?? '0x'),
    s: String(t.s ?? '0x'),
  };
}

function normalizeType3Fields(t: Record<string, unknown>): Type3Fields {
  return {
    chainId: BigInt(String(t.chainId ?? 0)),
    maxPriorityFeePerGas: BigInt(String(t.maxPriorityFeePerGas ?? 0)),
    maxFeePerGas: BigInt(String(t.maxFeePerGas ?? 0)),
    accessList: normalizeAccessList(t.accessList),
    maxFeePerBlobGas: BigInt(String(t.maxFeePerBlobGas ?? 0)),
    blobVersionedHashes: Array.isArray(t.blobVersionedHashes) ? t.blobVersionedHashes.map(String) : [],
    yParity: Number(t.yParity ?? 0),
    r: String(t.r ?? '0x'),
    s: String(t.s ?? '0x'),
  };
}

function normalizeType4Fields(t: Record<string, unknown>): Type4Fields {
  return {
    chainId: BigInt(String(t.chainId ?? 0)),
    maxPriorityFeePerGas: BigInt(String(t.maxPriorityFeePerGas ?? 0)),
    maxFeePerGas: BigInt(String(t.maxFeePerGas ?? 0)),
    accessList: normalizeAccessList(t.accessList),
    authorizationList: normalizeAuthorizationList(t.authorizationList),
    yParity: Number(t.yParity ?? 0),
    r: String(t.r ?? '0x'),
    s: String(t.s ?? '0x'),
  };
}

// --- Normalizers for full transaction results ---

function getCommonTx(common: Record<string, unknown>): CommonTxFields {
  return {
    nonce: BigInt(String(common.nonce ?? 0)),
    gasLimit: BigInt(String(common.gasLimit ?? 0)),
    from: String(common.from ?? ''),
    toIsNull: Boolean(common.toIsNull),
    to: String(common.to ?? ''),
    value: BigInt(String(common.value ?? 0)),
    data: String(common.data ?? '0x'),
  };
}

function getReceipt(receipt: Record<string, unknown>): ReceiptFields {
  const logs = (receipt.receiptLogs ?? []) as Array<{ address_?: string; topics?: string[]; data?: string }>;
  return {
    receiptStatus: Number(receipt.receiptStatus ?? 0),
    receiptGasUsed: BigInt(String(receipt.receiptGasUsed ?? 0)),
    receiptLogs: logs.map((l) => ({
      address_: String(l.address_ ?? ''),
      topics: Array.isArray(l.topics) ? l.topics.map(String) : [],
      data: String(l.data ?? '0x'),
    })),
    receiptLogsBloom: String(receipt.receiptLogsBloom ?? '0x'),
  };
}

function extractTuple(result: unknown): {
  common: Record<string, unknown>;
  typeFields: Record<string, unknown>;
  receipt: Record<string, unknown>;
} {
  const r = result as Record<string, unknown>;
  const common = (r.commonTx ?? r[0] ?? {}) as Record<string, unknown>;
  const typeFields = (r.type0 ?? r.type1 ?? r.type2 ?? r.type3 ?? r.type4 ?? r[1] ?? {}) as Record<string, unknown>;
  const receipt = (r.receipt ?? r[2] ?? {}) as Record<string, unknown>;
  return { common, typeFields, receipt };
}

function normalizeType0(result: unknown): DecodedTransactionType0 {
  const { common, typeFields, receipt } = extractTuple(result);
  return {
    commonTx: getCommonTx(common),
    type0: normalizeLegacyFields(typeFields),
    receipt: getReceipt(receipt),
  };
}

function normalizeType1(result: unknown): DecodedTransactionType1 {
  const { common, typeFields, receipt } = extractTuple(result);
  return {
    commonTx: getCommonTx(common),
    type1: normalizeType1Fields(typeFields),
    receipt: getReceipt(receipt),
  };
}

function normalizeType2(result: unknown): DecodedTransactionType2 {
  const { common, typeFields, receipt } = extractTuple(result);
  return {
    commonTx: getCommonTx(common),
    type2: normalizeType2Fields(typeFields),
    receipt: getReceipt(receipt),
  };
}

function normalizeType3(result: unknown): DecodedTransactionType3 {
  const { common, typeFields, receipt } = extractTuple(result);
  return {
    commonTx: getCommonTx(common),
    type3: normalizeType3Fields(typeFields),
    receipt: getReceipt(receipt),
  };
}

function normalizeType4(result: unknown): DecodedTransactionType4 {
  const { common, typeFields, receipt } = extractTuple(result);
  return {
    commonTx: getCommonTx(common),
    type4: normalizeType4Fields(typeFields),
    receipt: getReceipt(receipt),
  };
}

/**
 * Formats a decoded transaction for display (e.g. JSON string).
 */
export function formatDecodedTransaction(decoded: DecodedTransaction): string {
  const toJson = (obj: unknown): unknown => {
    if (obj === null || obj === undefined) return obj;
    if (typeof obj === 'bigint') return obj.toString();
    if (Array.isArray(obj)) return obj.map(toJson);
    if (typeof obj === 'object') {
      const out: Record<string, unknown> = {};
      for (const [k, v] of Object.entries(obj)) {
        out[k] = toJson(v);
      }
      return out;
    }
    return obj;
  };
  return JSON.stringify({ type: decoded.type, data: toJson(decoded.data) }, null, 2);
}
