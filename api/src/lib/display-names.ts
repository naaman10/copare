/** User-facing display name from profiles only. Null when unset or blank. */
export function profileDisplayName(profileAlias = 'p'): string {
  return `NULLIF(TRIM(${profileAlias}.display_name), '')`;
}
