// Loaded only in CodexPlusBar's private bridge location. OpenCode owns all
// credential persistence and broadcasts its normal account-switch events.
// Plain Plugin/Rpc definition objects need no runtime npm dependencies.
const integrationID = 'openai';
const methodID = 'codexplusbar-import';
const object = { type: 'object' };
const rpc = {
  id: 'codexplusbar.openai',
  methods: {
    read: { input: object, output: object },
    import: { input: object, output: object },
  },
  events: {},
};

function legacy(value) {
  if (value?.type !== 'oauth' || !['chatgpt-browser', 'chatgpt-headless'].includes(value.methodID)) {
    throw new Error('unsupported_credential');
  }
  const auth = {
    type: 'oauth', access: value.access, refresh: value.refresh,
    expires: value.expires, accountId: value.metadata?.accountID,
  };
  validate(auth);
  return auth;
}

function validate(auth) {
  if (auth?.type !== 'oauth' || typeof auth.access !== 'string' || !auth.access ||
      typeof auth.refresh !== 'string' || !auth.refresh ||
      !Number.isSafeInteger(auth.expires) || auth.expires < 0) throw new Error('invalid_credential');
  let claims;
  try { claims = JSON.parse(Buffer.from(auth.access.split('.')[1], 'base64url').toString()); }
  catch { throw new Error('invalid_credential'); }
  const identity = claims?.['https://api.openai.com/auth'];
  if (!auth.accountId || identity?.chatgpt_account_id !== auth.accountId ||
      !identity?.chatgpt_user_id || !claims?.['https://api.openai.com/profile']?.email) {
    throw new Error('invalid_credential');
  }
  return claims['https://api.openai.com/profile'].email;
}

function same(left, right) {
  return left?.id === right?.id && ['type', 'access', 'refresh', 'expires', 'accountId']
    .every(key => left?.auth?.[key] === right?.auth?.[key]);
}

export default {
  id: 'codexplusbar.openai',
  async setup(ctx) {
    // A one-use in-memory capability, never a token in a URL, log, or config.
    let pending;
    let busy = false;
    async function read(id) {
      const connection = id
        ? (await ctx.integration.get({ integrationID })).data.connections
          .find(item => item.type === 'credential' && item.id === id)
        : await ctx.integration.connection.active(integrationID);
      if (!connection || connection.type !== 'credential') throw new Error('credential_missing');
      const value = await ctx.integration.connection.resolve(connection);
      return { id: connection.id, auth: legacy(value) };
    }

    await ctx.integration.transform(editor => editor.method.update({
      integrationID,
      method: { id: methodID, type: 'oauth', label: 'Saved sign-in from CodexPlusBar' },
      async authorize() {
        if (!pending) throw new Error('import_not_started');
        const operation = pending;
        return {
          mode: 'code', url: 'https://chatgpt.com', instructions: 'Return to CodexPlusBar.',
          async callback(code) {
            if (pending !== operation || code !== operation.nonce) throw new Error('import_not_started');
            if (!same(await read(), operation.expected)) throw new Error('changed_externally');
            pending = undefined;
            const auth = operation.auth;
            // Retain OpenCode's built-in ChatGPT method, including token refresh.
            return { type: 'oauth', methodID: 'chatgpt-browser', access: auth.access,
              refresh: auth.refresh, expires: auth.expires, metadata: { accountID: auth.accountId } };
          },
        };
      },
    }));

    await ctx.rpc.register(rpc, {
      async read(input) {
        try { return await read(typeof input?.id === 'string' ? input.id : undefined); }
        catch { throw new Error('credential_read_failed'); }
      },
      async import(input) {
        if (busy) throw new Error('busy');
        busy = true;
        let attemptID;
        try {
          const label = validate(input?.auth);
          if (!same(await read(), input?.expected)) throw new Error('changed_externally');
          pending = { auth: input.auth, expected: input.expected, nonce: crypto.randomUUID() };
          const nonce = pending.nonce;
          const attempt = await ctx.integration.oauth.connect({
            integrationID, methodID, label,
          });
          attemptID = attempt.data.attemptID;
          await ctx.integration.oauth.complete({ integrationID, attemptID, code: nonce });
          const status = await ctx.integration.oauth.status({ integrationID, attemptID });
          if (status.data.status !== 'complete') throw new Error('import_failed');
          const installed = await read();
          if (!same(installed, { id: installed.id, auth: input.auth })) throw new Error('changed_externally');
          return installed;
        } catch {
          // SDK/decoder errors may contain secrets; expose only fixed copy.
          throw new Error('credential_import_failed');
        } finally {
          pending = undefined;
          if (attemptID) await ctx.integration.oauth.cancel({ integrationID, attemptID }).catch(() => {});
          busy = false;
        }
      },
    });
  },
};
