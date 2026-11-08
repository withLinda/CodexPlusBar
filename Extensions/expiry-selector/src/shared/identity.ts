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
    const userID: unknown = auth?.chatgpt_user_id ?? auth?.user_id;
    if (auth?.chatgpt_user_id !== undefined && auth?.user_id !== undefined && auth.chatgpt_user_id !== auth.user_id) return null;
    const canonical = (value: unknown): value is string => typeof value === 'string' && value.length > 0 && value.length <= 512 &&
      value.trim() === value && !/[\x00-\x1f\x7f]/.test(value);
    if (!canonical(accountID) || !canonical(userID)) return null;
    return { accountID, identityKey: createHash('sha256').update(`${accountID}\n${userID}`).digest('hex') };
  } catch { return null; }
}
