import type { Plugin } from '@opencode/plugin';
import { fixtureAccount } from './fixtures.js';
import { accounts, credential } from './fixtures.js';
import { NativeAdapter } from '../../src/plugin/native-adapter.js';
import { cohereAccountHeader } from '../../src/plugin/request-observer.js';
import { tokenIdentity } from '../../src/shared/identity.js';
import { createProbeOwner } from './probe-owner.js';

const object = { type: 'object' } as const;
const rpc = { id: 'expiry.probe', methods: {
  control: { input: object, output: object }, status: { input: object, output: object },
  resolve: { input: object, output: object },
  queuedActivate: { input: object, output: object }, maintenance: { input: object, output: object },
}, events: {} };
const key = Symbol.for('codexplusbar.expiry-selector.probe.v1');
type Owner = Awaited<ReturnType<typeof createProbeOwner>> & { resolvesStarted: number; refreshCalls: number;
  refreshGate: ReturnType<typeof Promise.withResolvers<void>> };
const globals = globalThis as typeof globalThis & { [key]?: Promise<Owner> };

// This entire module is test-only; no credential endpoint or interceptor ships.
export default {
  id: 'codexplusbar-expiry-selector-probe',
  async setup(ctx) {
    const origin = ctx.options.fixtureOrigin;
    if (typeof origin !== 'string' || !/^http:\/\/127\.0\.0\.1:\d+$/.test(origin)) throw new Error('Fixture origin required');
    const native = new NativeAdapter(ctx);
    const managed = new Set(['A', 'B'].map(name => tokenIdentity(`Bearer ${credential(name as 'A' | 'B').access}`)!.identityKey));
    const owner = await (globals[key] ??= createProbeOwner(Number(ctx.options.coordinatorPort)).then(owner => Object.assign(owner,
      { resolvesStarted: 0, refreshCalls: 0, refreshGate: Promise.withResolvers<void>() })));
    owner.locations.add(ctx.location.directory);
    const allowed = async () => !(await ctx.plugin.list()).data.some(plugin => plugin.id === 'openchamber-limit-failover');
    const queuedActivate = (id: string) => owner.activate(ctx.location.directory, id, () => native.activate(id), allowed);
    await ctx.integration.transform(editor => {
      editor.method.update({
        integrationID: 'openai', method: { id: 'expiry-fixture-refresh', type: 'oauth', label: 'Fixture refresh' },
        async authorize() { throw new Error('Fixture authorization is not supported'); },
        async refresh(value) {
          if (value.refresh !== 'fixture-refresh-old') throw new Error('Unexpected fixture refresh');
          owner.refreshCalls++;
          await owner.refreshGate.promise;
          return { ...value, access: credential('A').access, refresh: 'fixture-refresh-new', expires: 4_000_000_000_000 };
        },
      });
    });
    let promptTarget: string | null = accounts.B.id;
    let retryTarget: string | null = null;
    let racedHeader: string | null = null;
    let httpOnly = true;
    let skipTitle = true;
    let titleGate: ReturnType<typeof Promise.withResolvers<void>> | null = null;
    let titleWaiting = false;
    let toolEffects = 0;
    let promptCalls = 0;
    let heldProviderHeader: string | null = null;
    let providerHeaderCase = 'chatgpt-account-id';
    let delayedReloads = 0;
    let transportGate: ReturnType<typeof Promise.withResolvers<void>> | null = null;
    let transportWaiting = false;
    // Hold publication of the native plugin's derived account header while the
    // real credential activation/reload proceeds. No credential is replaced.
    await ctx.provider.transform(editor => {
      const header = editor.get('openai')?.provider.headers?.['chatgpt-account-id'];
      if (!heldProviderHeader || header === heldProviderHeader) return;
      delayedReloads++;
      editor.update('openai', provider => {
        const headers = { ...provider.headers };
        for (const key of Object.keys(headers)) if (key.toLowerCase() === 'chatgpt-account-id') delete headers[key];
        headers[providerHeaderCase] = heldProviderHeader!;
        provider.headers = headers;
      });
    });
    await ctx.tool.transform(editor => editor.add({
      name: 'expiry_fixture_effect', description: 'Increment a synthetic effect counter.',
      options: { codemode: false },
      input: { type: 'object', properties: {}, additionalProperties: false },
      async execute() { toolEffects++; return { content: 'Fixture effect complete.' }; },
    }));
    const observed: { kind: string; transport: string; accountID: string; header: string | null; before: string | null }[] = [];
    const exhausted: string[] = [];
    const primary = new Map<string, string>();
    await ctx.rpc.register(rpc, {
      async control(input) {
        const value = input as { promptTarget?: string | null; retryTarget?: string | null; racedHeader?: string | null; httpOnly?: boolean; activate?: string; releaseRefresh?: boolean; skipTitle?: boolean;
          holdProviderHeader?: boolean; providerHeaderCase?: string; holdTransport?: boolean; releaseTransport?: boolean;
          holdActivation?: boolean; releaseActivation?: boolean; holdTitle?: boolean; releaseTitle?: boolean };
        if ('promptTarget' in value) promptTarget = value.promptTarget ?? null;
        if ('retryTarget' in value) retryTarget = value.retryTarget ?? null;
        if ('racedHeader' in value) racedHeader = value.racedHeader ?? null;
        if (typeof value.httpOnly === 'boolean') httpOnly = value.httpOnly;
        if (typeof value.skipTitle === 'boolean') skipTitle = value.skipTitle;
        if (value.holdTitle) { titleWaiting = false; titleGate = Promise.withResolvers<void>(); }
        if (value.releaseTitle) { titleGate?.resolve(); titleGate = null; }
        if (value.providerHeaderCase) providerHeaderCase = value.providerHeaderCase;
        if (value.holdProviderHeader === true) {
          const provider = await ctx.provider.get({ providerID: 'openai' });
          heldProviderHeader = provider.data.headers?.['chatgpt-account-id'] ?? null;
          if (!heldProviderHeader) throw new Error('Native provider header missing');
        }
        if (value.holdProviderHeader === false) { heldProviderHeader = null; await ctx.provider.reload(); }
        if (value.holdTransport) { transportWaiting = false; transportGate = Promise.withResolvers<void>(); }
        if (value.releaseTransport) { transportGate?.resolve(); transportGate = null; }
        if (value.holdActivation) owner.holdActivation();
        if (value.releaseActivation) owner.releaseActivation();
        if (value.activate) await native.activate(value.activate);
        if (value.releaseRefresh) owner.refreshGate.resolve();
        return { activeID: await native.activeID() };
      },
      async resolve(input) {
        const { credentialID } = input as { credentialID: string };
        const integration = await ctx.integration.get({ integrationID: 'openai' });
        const connection = integration.data.connections.find(connection => connection.type === 'credential' && connection.id === credentialID);
        if (!connection) throw new Error('Fixture connection missing');
        owner.resolvesStarted++;
        const result = await ctx.integration.connection.resolve(connection);
        return { rotated: result?.type === 'oauth' && result.refresh === 'fixture-refresh-new' && result.access === credential('A').access };
      },
      async queuedActivate(input) { return { activated: await queuedActivate((input as { id: string }).id) }; },
      async maintenance(input) {
        const { action } = input as { action: string };
        if (action === 'begin') await owner.beginMaintenance();
        else if (action === 'end') await owner.endMaintenance();
        else if (action === 'resume') await owner.resume();
        return owner.status();
      },
      async status() { return { ...owner.status(), observed, exhausted,
        resolvesStarted: owner.resolvesStarted, refreshCalls: owner.refreshCalls, toolEffects, promptCalls,
        delayedReloads, transportWaiting, titleWaiting,
        fixtureTools: (await ctx.tool.list()).filter(tool => tool.name.includes('expiry')).map(tool => ({ id: tool.id, name: tool.name })),
        activeID: await native.activeID() }; },
    });
    await ctx.session.hook('prompt', async () => {
      promptCalls++;
      if (!promptTarget) return;
      if (!await queuedActivate(promptTarget)) return;
      if (await native.activeID() !== promptTarget) throw new Error('Fixture activation unconfirmed');
    });
    await ctx.session.hook('title', async event => {
      if (skipTitle) event.result = 'Fixture';
      else if (titleGate) { titleWaiting = true; await titleGate.promise; }
    });
    await ctx.session.hook('model.request', async event => {
      if (racedHeader) event.headers['ChatGPT-Account-ID'] = racedHeader;
      if (transportGate) { transportWaiting = true; await transportGate.promise; }
    }, { providerID: 'openai' });
    await ctx.session.hook('http.request', event => {
      const before = event.request.headers.get('chatgpt-account-id');
      cohereAccountHeader(event.request.url, event.request.headers, managed);
      const accountID = fixtureAccount(event.request.headers.get('authorization'));
      observed.push({ kind: event.kind, transport: 'http', accountID, header: event.request.headers.get('chatgpt-account-id'), before });
      if (event.kind === 'primary') primary.set(event.sessionID, accountID);
      const url = new URL(event.request.url);
      if (url.origin !== 'https://chatgpt.com' || !url.pathname.startsWith('/backend-api/codex/')) throw new Error('Unexpected route');
      event.request.headers.set('x-fixture-kind', event.kind);
      event.request = new Request(origin + url.pathname, event.request);
    }, { providerID: 'openai' });
    await ctx.session.hook('experimental.ws.handshake', event => {
      const headers = new Headers(event.headers);
      const before = headers.get('chatgpt-account-id');
      cohereAccountHeader(event.url, headers, managed);
      event.headers = Object.fromEntries(headers.entries());
      const accountID = fixtureAccount(headers.get('authorization'));
      observed.push({ kind: event.kind, transport: 'websocket', accountID, header: headers.get('chatgpt-account-id'), before });
      if (event.kind === 'primary') primary.set(event.sessionID, accountID);
      const url = new URL(event.url);
      if (url.origin !== 'wss://chatgpt.com' || !url.pathname.startsWith('/backend-api/codex/')) throw new Error('Unexpected WS route');
      event.url = origin.replace('http:', 'ws:') + (httpOnly ? '/refuse' : url.pathname);
    }, { providerID: 'openai' });
    await ctx.session.hook('retry', async event => {
      if (!retryTarget) return;
      const identity = primary.get(event.sessionID);
      if (identity) exhausted.push(identity);
      if (!await queuedActivate(retryTarget)) return;
      if (await native.activeID() === retryTarget) event.decision = { retry: true, delay: 0 };
    }, { providerID: 'openai' });
    return async () => {
      owner.locations.delete(ctx.location.directory);
      if (!owner.locations.size) { await owner.close(); delete globals[key]; }
    };
  },
} satisfies Plugin.Plugin;
