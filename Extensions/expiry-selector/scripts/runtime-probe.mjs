import { spawnSync } from 'node:child_process';
import { readFileSync } from 'node:fs';

for (const args of [['scripts/build.mjs'], ['node_modules/vitest/vitest.mjs', 'run', 'tests/runtime/selector.integration.test.ts', 'tests/runtime/production.integration.test.ts']]) {
  const result = spawnSync(process.execPath, args, { stdio: 'inherit' });
  if (result.status !== 0) process.exit(result.status ?? 1);
}

// A green subset must never be reported as the complete feasibility gate.
const gate = JSON.parse(readFileSync(new URL('../docs/compatibility-gate.json', import.meta.url), 'utf8'));
const incomplete = gate.proofs.filter(proof => proof.status !== 'passed');
if (incomplete.length) {
  console.error('COMPATIBILITY GATE BLOCKED (the executed runtime subset passed).');
  for (const proof of incomplete) console.error(`${proof.id}: ${proof.status} — ${proof.reason}`);
  process.exitCode = 1;
}
