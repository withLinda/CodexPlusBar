export const accounts = {
  A: { id: 'cred_expiry_fixture_a', accountID: 'account-fixture-a', userID: 'user-fixture-a' },
  B: { id: 'cred_expiry_fixture_b', accountID: 'account-fixture-b', userID: 'user-fixture-b' },
} as const;

export function credential(name: keyof typeof accounts) {
  const identity = accounts[name];
  const claims = {
    exp: 4_000_000_000,
    'https://api.openai.com/auth': {
      chatgpt_account_id: identity.accountID, chatgpt_user_id: identity.userID,
    },
  };
  return {
    type: 'oauth', methodID: 'chatgpt-browser',
    access: `fixture.${Buffer.from(JSON.stringify(claims)).toString('base64url')}.signature`,
    refresh: `fixture-refresh-${name}`, expires: 4_000_000_000_000,
    metadata: { accountID: identity.accountID },
  };
}

export function fixtureAccount(authorization: string | undefined | null): string {
  if (!authorization?.startsWith('Bearer fixture.')) throw new Error('Nonfixture authorization refused');
  const payload = authorization.split('.')[1];
  if (!payload) throw new Error('Fixture claims missing');
  const claims = JSON.parse(Buffer.from(payload, 'base64url').toString()) as Record<string, any>;
  const accountID: unknown = claims['https://api.openai.com/auth']?.chatgpt_account_id;
  if (![accounts.A.accountID, accounts.B.accountID].includes(accountID as any)) throw new Error('Unknown fixture');
  return String(accountID);
}
