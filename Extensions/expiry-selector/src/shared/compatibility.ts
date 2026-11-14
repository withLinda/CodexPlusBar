// Exact runtime versions validated by the isolated native compatibility suite.
// A patch release still needs transport, retry, refresh and lifecycle evidence.
export const verifiedRuntimes = [
  { openchamber: '2.7.0', opencode: '2.2.6' },
  { openchamber: '2.7.1', opencode: '2.2.7' },
] as const;

export const supportedVersions = {
  openchamber: verifiedRuntimes.map(runtime => runtime.openchamber).join(', '),
  opencode: verifiedRuntimes.map(runtime => runtime.opencode).join(', '),
};

export const supportsRuntime = (version: string): boolean => verifiedRuntimes.some(runtime => runtime.opencode === version);
