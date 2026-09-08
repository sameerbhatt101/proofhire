import { MappedEncodedFields, QueryableFields } from '../models';

function getMappedFieldsForType0(): MappedEncodedFields {
  // type_ is encoded separately as the first uint8 parameter, so we skip it here
  return {
    chunks: [
      // Chunk 1: Common fields (nonce, gasLimit, from, toIsNull, to, value, data)
      {
        fields: [
          { name: QueryableFields.TxNonce, type: 'uint64' },
          { name: QueryableFields.TxGasLimit, type: 'uint64' },
          { name: QueryableFields.TxFrom, type: 'address' },
          { name: QueryableFields.TxToIsNull, type: 'bool' },
          { name: QueryableFields.TxTo, type: 'address' },
          { name: QueryableFields.TxValue, type: 'uint256' },
          { name: QueryableFields.TxData, type: 'bytes' },
        ],
      },
      // Chunk 2: Type-specific fields (gasPrice, v, r, s)
      {
        fields: [
          { name: QueryableFields.TxGasPrice, type: 'uint128' },
          { name: QueryableFields.TxV, type: 'uint256' },
          { name: QueryableFields.TxR, type: 'bytes32' },
          { name: QueryableFields.TxS, type: 'bytes32' },
        ],
      },
      // Chunk 3: Receipt fields (receiptStatus, receiptGasUsed, receiptLogs, receiptLogsBloom)
      {
        fields: [
          { name: QueryableFields.RxStatus, type: 'uint8' },
          { name: QueryableFields.RxGasUsed, type: 'uint64' },
          { name: QueryableFields.RxLogs, type: 'tuple(address, bytes32[], bytes)[]' },
          { name: QueryableFields.RxLogBlooms, type: 'bytes' },
        ],
      },
    ],
  };
}

function getMappedFieldsForType1(): MappedEncodedFields {
  // type_ is encoded separately as the first uint8 parameter, so we skip it here
  return {
    chunks: [
      // Chunk 1: Common fields (nonce, gasLimit, from, toIsNull, to, value, data)
      {
        fields: [
          { name: QueryableFields.TxNonce, type: 'uint64' },
          { name: QueryableFields.TxGasLimit, type: 'uint64' },
          { name: QueryableFields.TxFrom, type: 'address' },
          { name: QueryableFields.TxToIsNull, type: 'bool' },
          { name: QueryableFields.TxTo, type: 'address' },
          { name: QueryableFields.TxValue, type: 'uint256' },
          { name: QueryableFields.TxData, type: 'bytes' },
        ],
      },
      // Chunk 2: Type-specific fields (chainId, gasPrice, accessList, yParity, r, s)
      {
        fields: [
          { name: QueryableFields.TxChainId, type: 'uint64' },
          { name: QueryableFields.TxGasPrice, type: 'uint128' },
          { name: QueryableFields.TxAccessList, type: 'tuple(address,bytes32[])[]' },
          { name: QueryableFields.TxYParity, type: 'uint8' },
          { name: QueryableFields.TxR, type: 'bytes32' },
          { name: QueryableFields.TxS, type: 'bytes32' },
        ],
      },
      // Chunk 3: Receipt fields (receiptStatus, receiptGasUsed, receiptLogs, receiptLogsBloom)
      {
        fields: [
          { name: QueryableFields.RxStatus, type: 'uint8' },
          { name: QueryableFields.RxGasUsed, type: 'uint64' },
          { name: QueryableFields.RxLogs, type: 'tuple(address, bytes32[], bytes)[]' },
          { name: QueryableFields.RxLogBlooms, type: 'bytes' },
        ],
      },
    ],
  };
}

function getMappedFieldsForType2(): MappedEncodedFields {
  // type_ is encoded separately as the first uint8 parameter, so we skip it here
  return {
    chunks: [
      // Chunk 1: Common fields (nonce, gasLimit, from, toIsNull, to, value, data)
      {
        fields: [
          { name: QueryableFields.TxNonce, type: 'uint64' },
          { name: QueryableFields.TxGasLimit, type: 'uint64' },
          { name: QueryableFields.TxFrom, type: 'address' },
          { name: QueryableFields.TxToIsNull, type: 'bool' },
          { name: QueryableFields.TxTo, type: 'address' },
          { name: QueryableFields.TxValue, type: 'uint256' },
          { name: QueryableFields.TxData, type: 'bytes' },
        ],
      },
      // Chunk 2: Type-specific fields (chainId, maxPriorityFeePerGas, maxFeePerGas, accessList, yParity, r, s)
      {
        fields: [
          { name: QueryableFields.TxChainId, type: 'uint64' },
          { name: QueryableFields.TxMaxPriorityFeePerGas, type: 'uint128' },
          { name: QueryableFields.TxMaxFeePerGas, type: 'uint128' },
          { name: QueryableFields.TxAccessList, type: 'tuple(address,bytes32[])[]' },
          { name: QueryableFields.TxYParity, type: 'uint8' },
          { name: QueryableFields.TxR, type: 'bytes32' },
          { name: QueryableFields.TxS, type: 'bytes32' },
        ],
      },
      // Chunk 3: Receipt fields (receiptStatus, receiptGasUsed, receiptLogs, receiptLogsBloom)
      {
        fields: [
          { name: QueryableFields.RxStatus, type: 'uint8' },
          { name: QueryableFields.RxGasUsed, type: 'uint64' },
          { name: QueryableFields.RxLogs, type: 'tuple(address, bytes32[], bytes)[]' },
          { name: QueryableFields.RxLogBlooms, type: 'bytes' },
        ],
      },
    ],
  };
}

function getMappedFieldsForType3(): MappedEncodedFields {
  // type_ is encoded separately as the first uint8 parameter, so we skip it here
  return {
    chunks: [
      // Chunk 1: Common fields (nonce, gasLimit, from, toIsNull, to, value, data)
      {
        fields: [
          { name: QueryableFields.TxNonce, type: 'uint64' },
          { name: QueryableFields.TxGasLimit, type: 'uint64' },
          { name: QueryableFields.TxFrom, type: 'address' },
          { name: QueryableFields.TxToIsNull, type: 'bool' },
          { name: QueryableFields.TxTo, type: 'address' },
          { name: QueryableFields.TxValue, type: 'uint256' },
          { name: QueryableFields.TxData, type: 'bytes' },
        ],
      },
      // Chunk 2: Type-specific fields part 1 (chainId, maxPriorityFeePerGas, maxFeePerGas, accessList)
      {
        fields: [
          { name: QueryableFields.TxChainId, type: 'uint64' },
          { name: QueryableFields.TxMaxPriorityFeePerGas, type: 'uint128' },
          { name: QueryableFields.TxMaxFeePerGas, type: 'uint128' },
          { name: QueryableFields.TxAccessList, type: 'tuple(address,bytes32[])[]' },
        ],
      },
      // Chunk 3: Type-specific fields part 2 (maxFeePerBlobGas, blobVersionedHashes, yParity, r, s)
      {
        fields: [
          { name: QueryableFields.TxMaxFeePerBlobGas, type: 'uint256' },
          { name: QueryableFields.TxBlobVersionedHashes, type: 'bytes32[]' },
          { name: QueryableFields.TxYParity, type: 'uint8' },
          { name: QueryableFields.TxR, type: 'bytes32' },
          { name: QueryableFields.TxS, type: 'bytes32' },
        ],
      },
      // Chunk 4: Receipt fields (receiptStatus, receiptGasUsed, receiptLogs, receiptLogsBloom)
      {
        fields: [
          { name: QueryableFields.RxStatus, type: 'uint8' },
          { name: QueryableFields.RxGasUsed, type: 'uint64' },
          { name: QueryableFields.RxLogs, type: 'tuple(address, bytes32[], bytes)[]' },
          { name: QueryableFields.RxLogBlooms, type: 'bytes' },
        ],
      },
    ],
  };
}

function getMappedFieldsForType4(): MappedEncodedFields {
  // type_ is encoded separately as the first uint8 parameter, so we skip it here
  return {
    chunks: [
      // Chunk 1: Common fields (nonce, gasLimit, from, toIsNull, to, value, data)
      {
        fields: [
          { name: QueryableFields.TxNonce, type: 'uint64' },
          { name: QueryableFields.TxGasLimit, type: 'uint64' },
          { name: QueryableFields.TxFrom, type: 'address' },
          { name: QueryableFields.TxToIsNull, type: 'bool' },
          { name: QueryableFields.TxTo, type: 'address' },
          { name: QueryableFields.TxValue, type: 'uint256' },
          { name: QueryableFields.TxData, type: 'bytes' },
        ],
      },
      // Chunk 2: Type-specific fields part 1 (chainId, maxPriorityFeePerGas, maxFeePerGas, accessList)
      {
        fields: [
          { name: QueryableFields.TxChainId, type: 'uint64' },
          { name: QueryableFields.TxMaxPriorityFeePerGas, type: 'uint128' },
          { name: QueryableFields.TxMaxFeePerGas, type: 'uint128' },
          { name: QueryableFields.TxAccessList, type: 'tuple(address,bytes32[])[]' },
        ],
      },
      // Chunk 3: Type-specific fields part 2 (authorizationList, yParity, r, s)
      {
        fields: [
          { name: QueryableFields.TxAuthorizationList, type: 'tuple(uint256,address,uint64,uint8,uint256,uint256)[]' },
          { name: QueryableFields.TxYParity, type: 'uint8' },
          { name: QueryableFields.TxR, type: 'bytes32' },
          { name: QueryableFields.TxS, type: 'bytes32' },
        ],
      },
      // Chunk 4: Receipt fields (receiptStatus, receiptGasUsed, receiptLogs, receiptLogsBloom)
      {
        fields: [
          { name: QueryableFields.RxStatus, type: 'uint8' },
          { name: QueryableFields.RxGasUsed, type: 'uint64' },
          { name: QueryableFields.RxLogs, type: 'tuple(address, bytes32[], bytes)[]' },
          { name: QueryableFields.RxLogBlooms, type: 'bytes' },
        ],
      },
    ],
  };
}

export function getMappedFieldsForType(type: number): MappedEncodedFields {
  switch (type) {
    case 0:
      return getMappedFieldsForType0();
    case 1:
      return getMappedFieldsForType1();
    case 2:
      return getMappedFieldsForType2();
    case 3:
      return getMappedFieldsForType3();
    case 4:
      return getMappedFieldsForType4();
    default:
      throw new Error('Unsupported transaction type');
  }
}

/**
 * @deprecated Receipt fields are now distributed across chunks in getMappedFieldsForType* functions.
 * This function is kept for backward compatibility but returns an empty chunks array.
 * Use getMappedFieldsForType() instead, which includes receipt fields in their proper chunks.
 */
export function getMappedReceiptFields(): MappedEncodedFields {
  return {
    chunks: [], // Receipt fields are now part of transaction type chunks
    fields: [
      { name: QueryableFields.RxStatus, type: 'uint8' },
      { name: QueryableFields.RxGasUsed, type: 'uint64' },
      { name: QueryableFields.RxLogs, type: 'tuple(address, bytes32[], bytes)[]' },
      { name: QueryableFields.RxLogBlooms, type: 'bytes' },
    ],
  };
}
