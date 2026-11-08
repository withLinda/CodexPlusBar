import { expect, test } from 'vitest';
import type { Plugin } from '@opencode/plugin';
import { NativeAdapter } from '../src/plugin/native-adapter.js';
import { registerSelectionHooks } from '../src/plugin/hooks.js';
import { SelectorCoordinator } from '../src/plugin/coordinator.js';
import { RequestObserver } from '../src/plugin/request-observer.js';
import { initialState } from '../src/plugin/state-store.js';
import { credential, accounts } from './runtime/fixtures.js';
import { tokenIdentity } from '../src/shared/identity.js';
import type { SelectorExportV1 } from '../src/shared/contracts.js';

function nativeFixture() {
  let active = accounts.B.id as string, provider: string | null = 'openai';
  let plugins: unknown = { data: [], location: { directory: '/fixture' } };
  const values: Record<string, any> = { [accounts.A.id]: credential('A'), [accounts.B.id]: credential('B') };
  const hooks = new Map<string, (event: any) => Promise<void>>();
  const activations: string[] = [];
  const ctx = {
    app: { version: '2.2.6' }, location: { directory: '/fixture' },
    plugin: { list: async () => plugins },
    session: { get: async () => ({ model: provider ? { providerID: provider, id: 'fixture' } : undefined }),
      hook: async (name: string, callback: (event: any) => Promise<void>) => {
        hooks.set(name, callback); return { dispose: async () => { hooks.delete(name); } };
      } },
    integration: { get: async () => ({ data: { id: 'openai', connections: Object.entries(values).map(([id, value]) =>
      ({ type: 'credential', id, label: id, method: value.type, ...(value.status ? { status: value.status } : {}) })) } }),
      connection: { active: async () => ({ type: 'credential', id: active }), resolve: async (row: { id: string }) => values[row.id] } },
    credential: { activate: async ({ credentialID }: { credentialID: string }) => { activations.push(credentialID); active = credentialID; } },
  } as unknown as Plugin.Context;
  return { ctx, values, hooks, activations, setProvider(value: string | null) { provider = value; }, setPlugins(value: unknown) { plugins = value; } };
}

test('native validation returns only identity and rejects unsupported method/status/metadata conflicts', async () => {
  const h = nativeFixture(), adapter = new NativeAdapter(h.ctx);
  expect(await adapter.validateIdentity(accounts.A.id)).toEqual({ ...tokenIdentity(`Bearer ${credential('A').access}`), methodID: 'chatgpt-browser' });
  for (const value of [{ ...credential('A'), methodID: 'other' }, { ...credential('A'), metadata: { accountID: 'different' } },
    { ...credential('A'), status: { status: 'needs_auth', message: 'fixture' } }, { ...credential('A'), access: 'opaque' }]) {
    h.values[accounts.A.id] = value;
    await expect(adapter.validateIdentity(accounts.A.id)).rejects.toThrow();
  }
});

test('native plugin list requires its location envelope; malformed absence never enables auto', async () => {
  const h = nativeFixture(), adapter = new NativeAdapter(h.ctx);
  h.setPlugins({ data: [{ id: 'openchamber-limit-failover', state: 'active', features: {}, source: {} }] });
  expect(await adapter.pluginIDs()).toContain('openchamber-limit-failover');
  for (const invalid of [[], { items: [] }, { data: null }, { data: [{}] }]) {
    h.setPlugins(invalid); await expect(adapter.pluginIDs()).rejects.toThrow();
  }
});

test('prompt hook preserves unrelated/unknown admission and retry hook uses actual attribution', async () => {
  const h = nativeFixture(), adapter = new NativeAdapter(h.ctx), observer = new RequestObserver();
  const now = Date.now();
  const snapshot: SelectorExportV1 = { schemaVersion: 1, sequence: 1, sourceInstanceID: crypto.randomUUID(), generatedAtMs: now, catalogTrusted: true,
    accounts: (['A', 'B'] as const).map((name, index) => {
      const identity = tokenIdentity(`Bearer ${credential(name).access}`)!;
      return { ...identity, profileID: crypto.randomUUID(), credentialID: accounts[name].id, label: name, bindingObservedAtMs: now,
        usage: { observedAtMs: now, identityKey: identity.identityKey, allowed: true, limitReached: false,
          fiveHour: { remainingPercent: 20, resetAtMs: now + 3600000 }, sevenDay: { state: 'not-applicable' } },
        entitlement: { observedAtMs: now, accountID: identity.accountID, expiresAtMs: now + (index + 1) * 86400000, active: true, usable: true, deactivated: false, match: 'canonical' }, unavailableReasons: [] };
    }) };
  const coordinator = new SelectorCoordinator({ now: () => now, owns: () => true, readSnapshot: async () => ({ ok: true, snapshot, exclusions: [] }), loadState: async () => initialState(), saveState: async () => {} });
  await coordinator.initialize(); const detach = coordinator.attach(adapter);
  const dispose = await registerSelectionHooks(h.ctx, adapter, coordinator, observer);
  try {
    await coordinator.setMode('auto', 'enable');
    const prompt = { sessionID: 'session', prompt: { text: 'unchanged' } };
    for (const provider of ['anthropic', null]) { h.setProvider(provider); await h.hooks.get('prompt')!(prompt); }
    expect(h.activations).toEqual([]);
    h.setProvider('openai'); await h.hooks.get('prompt')!(prompt);
    expect(h.activations).toEqual([accounts.A.id]); expect(prompt.prompt.text).toBe('unchanged');
    const scope = { locationKey: '/fixture', sessionID: 'session', modelID: 'fixture', providerID: 'openai', agent: 'build', kind: 'primary' as const };
    const observe = () => {
      const generation = observer.beginPrimary(scope);
      observer.observeTransport({ ...scope, generation, transport: 'http', identity: tokenIdentity(`Bearer ${credential('A').access}`), observedAtMs: now });
    };
    const event = { sessionID: 'session', agent: 'build', model: { providerID: 'openai', id: 'fixture' }, attempt: 2,
      error: { type: 'provider.quota', response: { body: '{"error":{"retry_after":120},"access_token":"must-not-retain"}' } }, decision: { retry: false } };
    await h.hooks.get('retry')!(event); expect(event.decision).toEqual({ retry: false });
    observe(); event.error.type = 'provider.auth'; await h.hooks.get('retry')!(event); expect(event.decision).toEqual({ retry: false });
    observe(); event.error.type = 'provider.quota'; await h.hooks.get('retry')!(event);
    expect(event.decision).toEqual({ retry: true, delay: 0 });
    expect(h.activations).toEqual([accounts.A.id, accounts.B.id]);
    expect(JSON.stringify(coordinator.status())).not.toContain('must-not-retain');
  } finally { await detach(); await dispose(); }
  expect(h.hooks.size).toBe(0);
});
