// Keep the status wire shape stable; these describe the contract, not an allowlist.
export const supportedVersions = {
  openchamber: '2.7.0+ (extension API 1)',
  opencode: 'required APIs and hooks; no version pin',
};

export type CompatibilityIssue = 'native-api-unavailable' | 'hooks-unavailable' | 'hooks-not-ready' | 'lifecycle-unavailable';

export function requireHookRegistration(value: unknown): { dispose(): Promise<void> } {
  if (!value || typeof value !== 'object' || !('dispose' in value) || typeof value.dispose !== 'function') {
    throw new Error('hooks-unavailable');
  }
  return value as { dispose(): Promise<void> };
}
