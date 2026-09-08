/**
 * Returns the byte length of a hex string (with or without the `0x` prefix).
 * Returns 0 for nullish values or the empty hex string `"0x"`.
 */
export function bytesInHexString(hex?: string | null): number {
  if (!hex || hex === '0x') return 0;
  return (hex.length - 2) / 2;
}
