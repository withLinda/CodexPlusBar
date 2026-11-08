import type { Plugin } from '@opencode/plugin';
import { credential } from './fixtures.js';

// Native integration callbacks must be registered before the selector's context
// is created. Transport redirection remains a separate plugin loaded after it.
export default {
  id: 'expiry-fixture-refresh',
  async setup(ctx) {
    await ctx.integration.transform(editor => editor.method.update({
      integrationID: 'openai', method: { id: 'chatgpt-browser', type: 'oauth', label: 'Synthetic native refresh' },
      async authorize() { throw new Error('Synthetic authorization disabled'); },
      async refresh(value) {
        if (value.refresh !== 'fixture-refresh-old') throw new Error('Unexpected synthetic refresh');
        const response = await fetch(String(ctx.options.fixtureOrigin) + '/refresh');
        if (!response.ok) throw new Error('Synthetic refresh failed');
        return { ...value, access: credential('A').access, refresh: 'fixture-refresh-new', expires: 4_000_000_000_000 };
      },
    }));
  },
} satisfies Plugin.Plugin;
