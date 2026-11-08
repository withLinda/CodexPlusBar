import { createHash } from 'node:crypto';

export type Identity = { identityKey: string; accountID: string };

/** Local consistency evidence only; this does not verify a JWT signature. */
export function tokenIdentity(authorization: string | null): Identity | null {
  if (!authorization || !/^Bearer [^\s]+$/i.test(authorization)) return null;
  const parts = authorization.slice(7).split('.');
  if (parts.length !== 3 || !parts[1] || parts[1].length > 32_768) return null;
  try {
    const claims = JSON.parse(Buffer.from(parts[1], 'base64url').toString('utf8'));
    const auth = claims?.['https://api.openai.com/auth'];
    const accountID: unknown = auth?.chatgpt_account_id;
    const userID: unknown = auth?.chatgpt_user_id;
    if (typeof accountID !== 'string' || !accountID || accountID.includes('\n') ||
        typeof userID !== 'string' || !userID || userID.includes('\n')) return null;
    return { accountID, identityKey: createHash('sha256').update(`${accountID}\n${userID}`).digest('hex') };
  } catch { return null; }
}
