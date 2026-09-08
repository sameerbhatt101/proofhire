// Define queryable fields
export enum QueryableFields {
  Type = 'type',
  TxChainId = 'chainId',
  TxNonce = 'nonce',
  TxGasPrice = 'gasPrice',
  TxGasLimit = 'gasLimit',
  TxFrom = 'from',
  TxToIsNull = 'toIsNull',
  TxTo = 'to',
  TxValue = 'value',
  TxData = 'data',
  TxV = 'v',
  TxR = 'r',
  TxS = 's',
  TxYParity = 'yParity',
  TxAccessList = 'accessList',
  TxAuthorizationList = 'authorizationList',
  TxMaxPriorityFeePerGas = 'maxPriorityFeePerGas',
  TxMaxFeePerGas = 'maxFeePerGas',
  TxMaxFeePerBlobGas = 'maxFeePerBlobGas',
  TxBlobVersionedHashes = 'blobVersionedHashes',
  RxStatus = 'rxStatus',
  RxGasUsed = 'rxGasUsed',
  RxLogBlooms = 'rxLogBlooms',
  RxLogs = 'rxLogs',
}

export type Field = {
  name: QueryableFields;
  type: string;
};

export interface Chunk {
  fields: Field[];
}

export interface MappedEncodedFields {
  chunks: Chunk[]; // Explicit chunks - primary structure
  fields?: Field[]; // Optional flat array for backward compatibility
}

export interface FieldMetadata {
  type: string;
  offset: number;
  size?: number;
  isDynamic: boolean;
  //dynamicOffset?: number;
  //dynamicSize?: number;
  //dynamicArrayCount?: number;
  //dynamicArrayRelativeOffsets?: number[];
  value?: any;
  children: FieldMetadata[]; // Nested fields for tuples and arrays
}
