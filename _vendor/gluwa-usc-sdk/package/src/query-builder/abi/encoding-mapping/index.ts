import { MappedEncodedFields } from '../models';
import { EncodingVersion } from '../../../encoding/abi';
import { getMappedFieldsForType as getMappedFieldsForTypeV1 } from './v1';

export function getAllFieldsForTransaction(type: number, encoding: EncodingVersion): MappedEncodedFields {
  switch (encoding) {
    case EncodingVersion.V1:
      return getMappedFieldsForTypeV1(type);
    default:
      return getMappedFieldsForTypeV1(type);
  }
}
