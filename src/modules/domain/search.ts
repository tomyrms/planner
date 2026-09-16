/** Search normalization shared with the iPhone (03_Data_Model.md §9).
 * NFKD, diacritics removed, lowercase, whitespace collapsed; '#', '+', '-', '.' kept so "C#" stays findable.
 */
export function normalizeSearchText(...parts: ReadonlyArray<string | null | undefined>): string {
  return parts
    .filter((part): part is string => typeof part === 'string' && part.length > 0)
    .join(' ')
    .normalize('NFKD')
    .replace(/\p{M}+/gu, '')
    .toLowerCase()
    .replace(/[^\p{L}\p{N}#+\-.]+/gu, ' ')
    .trim()
    .replace(/\s+/g, ' ');
}
