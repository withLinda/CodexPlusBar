import type { Plugin } from '@opencode/plugin';

// An independent test plugin redirects only synthetic traffic after the built selector hooks.
export default {
  id: 'codexplusbar-expiry-selector-probe',
  async setup(ctx) {
    let websocket = false, effects = 0, prompts = 0, skipTitle = true;
    let titleGate: ReturnType<typeof Promise.withResolvers<void>> | null = null, titleWaiting = false;
    let heldHeader: string | null = null, headerCase = 'chatgpt-account-id', delayedReloads = 0;
    await ctx.provider.transform(editor => {
      const header = editor.get('openai')?.provider.headers?.['chatgpt-account-id'];
      if (!heldHeader || header === heldHeader) return;
      delayedReloads++;
      editor.update('openai', provider => {
        const headers = { ...provider.headers };
        for (const key of Object.keys(headers)) if (key.toLowerCase() === 'chatgpt-account-id') delete headers[key];
        headers[headerCase] = heldHeader!; provider.headers = headers;
      });
    });
    await ctx.rpc.register({ id: 'expiry.probe', methods: {
      control: { input: { type: 'object' }, output: { type: 'object' } },
      status: { input: { type: 'object' }, output: { type: 'object' } },
      resolve: { input: { type: 'object' }, output: { type: 'object' } },
    }, events: {} }, {
      async control(input) {
        const value = input as { websocket?: boolean; skipTitle?: boolean; holdTitle?: boolean; releaseTitle?: boolean; holdHeader?: boolean; headerCase?: string };
        if (value.websocket !== undefined) websocket = value.websocket;
        if (value.skipTitle !== undefined) skipTitle = value.skipTitle;
        if (value.holdTitle) { titleWaiting = false; titleGate = Promise.withResolvers<void>(); }
        if (value.releaseTitle) { titleGate?.resolve(); titleGate = null; }
        if (value.headerCase) headerCase = value.headerCase;
        if (value.holdHeader === true) {
          heldHeader = (await ctx.provider.get({ providerID: 'openai' })).data.headers?.['chatgpt-account-id'] ?? null;
          if (!heldHeader) throw new Error('Synthetic provider header missing');
        }
        if (value.holdHeader === false) { heldHeader = null; await ctx.provider.reload(); }
        return {};
      },
      async status() { return { effects, prompts, titleWaiting, delayedReloads }; },
      async resolve(input) {
        const id = (input as { credentialID: string }).credentialID;
        const { data } = await ctx.integration.get({ integrationID: 'openai' });
        const connection = data.connections.find(row => row.type === 'credential' && row.id === id);
        if (!connection) throw new Error('Synthetic connection missing');
        const value = await ctx.integration.connection.resolve(connection);
        return { rotated: value?.type === 'oauth' && value.refresh === 'fixture-refresh-new' };
      },
    });
    await ctx.tool.transform(editor => editor.add({ name: 'expiry_fixture_effect', description: 'Synthetic acceptance counter.', options: { codemode: false }, input: { type: 'object', properties: {}, additionalProperties: false },
      async execute() { effects++; return { content: 'Fixture tool complete.' }; } }));
    await ctx.session.hook('prompt', () => { prompts++; });
    await ctx.session.hook('title', async event => {
      if (skipTitle) event.result = 'Fixture';
      else if (titleGate) { titleWaiting = true; await titleGate.promise; }
    });
    await ctx.session.hook('http.request', event => {
      if (new URL(event.request.url).origin !== 'https://chatgpt.com') throw new Error('Unexpected fixture route');
      event.request.headers.set('x-fixture-kind', event.kind);
      event.request = new Request(String(ctx.options.fixtureOrigin) + new URL(event.request.url).pathname, event.request);
    }, { providerID: 'openai' });
    await ctx.session.hook('experimental.ws.handshake', event => {
      event.url = String(ctx.options.fixtureOrigin).replace('http:', 'ws:') + (websocket ? '/responses' : '/refuse');
    }, { providerID: 'openai' });
  },
} satisfies Plugin.Plugin;
