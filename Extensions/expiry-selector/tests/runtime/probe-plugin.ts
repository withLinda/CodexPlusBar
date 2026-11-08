import type { Plugin } from '@opencode/plugin';
import { fixtureAccount } from './fixtures.js';
import { accounts, credential } from './fixtures.js';
import { NativeAdapter } from '../../src/plugin/native-adapter.js';
import { cohereAccountHeader } from '../../src/plugin/request-observer.js';
import { tokenIdentity } from '../../src/shared/identity.js';

const object = { type: 'object' } as const;
const rpc = { id: 'expiry.probe', methods: {
  control: { input: object, output: object }, status: { input: object, output: object },
}, events: {} };
const key = Symbol.for('codexplusbar.expiry-selector.probe.v1');
type Owner = { epoch: string; locations: Set<string> };
const globals = globalThis as typeof globalThis & { [key]?: Owner };

// This entire module is test-only; no credential endpoint or interceptor ships.
export default {
  id: 'codexplusbar-expiry-selector-probe',
  async setup(ctx) {
    const origin = ctx.options.fixtureOrigin;
    if (typeof origin !== 'string' || !/^http:\/\/127\.0\.0\.1:\d+$/.test(origin)) throw new Error('Fixture origin required');
    const native = new NativeAdapter(ctx);
    const managed = new Set(['A', 'B'].map(name => tokenIdentity(`Bearer ${credential(name as 'A' | 'B').access}`)!.identityKey));
    const owner = globals[key] ??= { epoch: crypto.randomUUID(), locations: new Set() };
    owner.locations.add(ctx.location.directory);
    let promptTarget: string | null = accounts.B.id;
    let retryTarget: string | null = null;
    let racedHeader: string | null = null;
    let httpOnly = true;
    const observed: { kind: string; transport: string; accountID: string; header: string | null }[] = [];
    const exhausted: string[] = [];
    const primary = new Map<string, string>();
    await ctx.rpc.register(rpc, {
      async control(input) {
        const value = input as { promptTarget?: string | null; retryTarget?: string | null; racedHeader?: string | null; httpOnly?: boolean; activate?: string };
        if ('promptTarget' in value) promptTarget = value.promptTarget ?? null;
        if ('retryTarget' in value) retryTarget = value.retryTarget ?? null;
        if ('racedHeader' in value) racedHeader = value.racedHeader ?? null;
        if (typeof value.httpOnly === 'boolean') httpOnly = value.httpOnly;
        if (value.activate) await native.activate(value.activate);
        return { activeID: await native.activeID() };
      },
      async status() { return { epoch: owner.epoch, locations: owner.locations.size, observed, exhausted, activeID: await native.activeID() }; },
    });
    await ctx.session.hook('prompt', async () => {
      if (!promptTarget) return;
      await native.activate(promptTarget);
      if (await native.activeID() !== promptTarget) throw new Error('Fixture activation unconfirmed');
    });
    await ctx.session.hook('title', event => { event.result = 'Fixture'; });
    await ctx.session.hook('model.request', event => {
      if (racedHeader) event.headers['ChatGPT-Account-ID'] = racedHeader;
    }, { providerID: 'openai' });
    await ctx.session.hook('http.request', event => {
      cohereAccountHeader(event.request.url, event.request.headers, managed);
      const accountID = fixtureAccount(event.request.headers.get('authorization'));
      observed.push({ kind: event.kind, transport: 'http', accountID, header: event.request.headers.get('chatgpt-account-id') });
      if (event.kind === 'primary') primary.set(event.sessionID, accountID);
      const url = new URL(event.request.url);
      if (url.origin !== 'https://chatgpt.com' || !url.pathname.startsWith('/backend-api/codex/')) throw new Error('Unexpected route');
      event.request = new Request(origin + url.pathname, event.request);
    }, { providerID: 'openai' });
    await ctx.session.hook('experimental.ws.handshake', event => {
      const headers = new Headers(event.headers);
      cohereAccountHeader(event.url, headers, managed);
      event.headers = Object.fromEntries(headers.entries());
      const accountID = fixtureAccount(headers.get('authorization'));
      observed.push({ kind: event.kind, transport: 'websocket', accountID, header: headers.get('chatgpt-account-id') });
      if (event.kind === 'primary') primary.set(event.sessionID, accountID);
      const url = new URL(event.url);
      if (url.origin !== 'wss://chatgpt.com' || !url.pathname.startsWith('/backend-api/codex/')) throw new Error('Unexpected WS route');
      event.url = origin.replace('http:', 'ws:') + (httpOnly ? '/refuse' : url.pathname);
    }, { providerID: 'openai' });
    await ctx.session.hook('retry', async event => {
      if (!retryTarget) return;
      const identity = primary.get(event.sessionID);
      if (identity) exhausted.push(identity);
      await native.activate(retryTarget);
      if (await native.activeID() === retryTarget) event.decision = { retry: true, delay: 0 };
    }, { providerID: 'openai' });
    return () => { owner.locations.delete(ctx.location.directory); if (!owner.locations.size) delete globals[key]; };
  },
} satisfies Plugin.Plugin;
