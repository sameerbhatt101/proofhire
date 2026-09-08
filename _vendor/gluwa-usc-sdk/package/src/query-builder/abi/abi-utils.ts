import { ParamType, BytesLike, hexlify, toNumber } from 'ethers';
import { FieldMetadata } from './models';
import { ForkedReader } from '../common/ForkedReader';
import { isDynamic } from '../common/is-dynamic';

export const WORD_SIZE = 32;

/**
 * Computes ABI field offsets by encoding, decoding, and analyzing offsets recursively.
 */
export function computeAbiOffsets(paramTypes: ParamType[], encodedData: BytesLike): FieldMetadata[] {
  const reader = new ForkedReader(encodedData, false);
  return decodeRecursive(reader, paramTypes);
}

function decodeRecursive(reader: ForkedReader, paramTypes: ParamType[], baseOffset = 0): FieldMetadata[] {
  let result: FieldMetadata[] = [];

  // current offset at this level.
  for (let i = 0; i < paramTypes.length; i++) {
    const currentParam = paramTypes[i];
    const field: FieldMetadata = {
      type: currentParam.format('full'),
      offset: baseOffset + reader.consumed,
      isDynamic: isDynamic(currentParam),
      children: [],
    };

    if (currentParam.isTuple()) {
      if (isDynamic(currentParam)) {
        const value = hexlify(reader.readBytes(WORD_SIZE));
        const offset = toNumber(value);
        const subReader = reader.subReaderAbsolute(offset);
        field.children = decodeRecursive(subReader, currentParam.components as ParamType[], offset);
      } else {
        // if you have a tuple
        // that has no dynamic element
        // the sequence must be treated like they are children
        // but must be read from the current reader..
        // this was detected from the RUST CODE
        // the reason the baseOffset passed is 0, is because it'll use already
        // baseOffset+reader.consumed
        // not sure what happens if hmm its nested :'(
        field.children = decodeRecursive(reader, currentParam.components as ParamType[], baseOffset);
      }
    } else if (!field.isDynamic) {
      if (currentParam.isArray()) {
        // this is a fixed size array :)
        let numberOfElements = currentParam.arrayLength;
        field.children = Array(numberOfElements)
          .fill(0)
          .map((_) => {
            return decodeRecursive(reader, [currentParam.arrayChildren], baseOffset)[0];
          });
      } else {
        field.value = hexlify(reader.readBytes(WORD_SIZE));
        field.size = WORD_SIZE;
      }
    } else {
      const value = hexlify(reader.readBytes(WORD_SIZE));
      const fieldDynamicOffset = toNumber(value);
      field.offset = baseOffset + fieldDynamicOffset;

      if (currentParam.isArray()) {
        // we know the size..
        if (currentParam.arrayLength !== -1) {
          // we know the size..
          // this means its a fixed array with a dynamic child.
          const subReader = reader.subReaderAbsolute(fieldDynamicOffset);
          let componentTypes = Array(currentParam.arrayLength)
            .fill(0)
            .map((_) => currentParam.arrayChildren);
          field.children = decodeRecursive(subReader, componentTypes, field.offset);
        } else {
          // its a dynamic array
          // the next thing to know is the number of elements.
          const subReader = reader.subReaderAbsolute(fieldDynamicOffset);
          const numberOfElements = subReader.readIndex();

          if (isDynamic(currentParam.arrayChildren)) {
            const dynamicArrayRelativeOffsets: number[] = [];
            for (let i = 0; i < numberOfElements; i++) {
              dynamicArrayRelativeOffsets.push(toNumber(subReader.readBytes(WORD_SIZE)));
            }

            // now we can start decoding the children :)
            const sizeOfOffsets = numberOfElements * WORD_SIZE;
            field.children = dynamicArrayRelativeOffsets.map((arrayElementOffset, index) => {
              // at the moment whats important is to take the arrayElementOffset which is the position mimus the number of size offsets * WORD_SIZE
              // this is then creating a new buffer from current subReader.consumed + offset of array element - (sizeOfOffsets)
              const relativeStart = arrayElementOffset - sizeOfOffsets;
              const arrayItemSubReader = subReader.subReader(relativeStart);

              // STRICT FIX: Only handle bytes/string arrays differently
              if (currentParam.arrayChildren.type === 'bytes' || currentParam.arrayChildren.type === 'string') {
                // For bytes/string in arrays, arrayElementOffset is relative to the start of offsets array
                // Offsets array starts at fieldDynamicOffset + WORD_SIZE (after array length prefix)
                // So absolute position is: baseOffset + fieldDynamicOffset + WORD_SIZE + arrayElementOffset
                const absoluteDataOffset = baseOffset + fieldDynamicOffset + WORD_SIZE + arrayElementOffset;
                const dataSubReader = reader.subReaderAbsolute(absoluteDataOffset);
                const length = dataSubReader.readIndex();

                if (length === 0) {
                  console.warn(`Warning: Chunk ${index} has length 0 at offset ${absoluteDataOffset}`);
                }

                return <FieldMetadata>{
                  type: currentParam.arrayChildren.format('full'),
                  offset: absoluteDataOffset + WORD_SIZE, // Absolute position of data start (after length prefix)
                  isDynamic: true,
                  size: length,
                  value: hexlify(dataSubReader.readBytes(length)),
                  children: [],
                };
              }

              // Original code path for tuples and other types (unchanged)
              // the only problem is to calculate the absolute position
              // its a bit more complicated you need to consider the offset since the begining
              // so hmm at this point the sub reader has already read all the offset so its cursor is kind of already at the right place.
              // so the position is hmm
              const position = baseOffset + fieldDynamicOffset + arrayElementOffset + WORD_SIZE;
              const children = decodeRecursive(
                arrayItemSubReader,
                currentParam.arrayChildren.components as ParamType[],
                position,
              );
              return <FieldMetadata>{
                type: currentParam.format('full'),
                offset: position,
                isDynamic: true,
                children: children,
              };
            });
          } else {
            // its a more simple type, so should be able to just read them sequentially :)
            field.children = Array(numberOfElements)
              .fill(0)
              .map((_) => {
                // this was important because
                // if the child was a tuple it would not work
                // this ensures we recursive for sub types as well
                return decodeRecursive(subReader, [currentParam.arrayChildren], field.offset)[0];
              });
          }
        }
      } else if (currentParam.type == 'string' || currentParam.type == 'bytes') {
        const subReader = reader.subReaderAbsolute(fieldDynamicOffset);
        const length = subReader.readIndex();
        field.offset = baseOffset + fieldDynamicOffset + WORD_SIZE;
        field.size = length;
        field.value = hexlify(subReader.readBytes(length));
      }
    }

    result.push(field);
  }

  return result;
}
