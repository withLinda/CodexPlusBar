import { tokenIdentity, type Identity } from '../shared/identity.js';

/** Only repairs the account header to agree with the actual native token. */
export function cohereAccountHeader(url: string, headers: Headers, managed: ReadonlySet<string>): Identity | null {
  let route: URL;
  try { route = new URL(url); } catch { return null; }
  if (!['https:', 'wss:'].includes(route.protocol) || route.hostname !== 'chatgpt.com' ||
      route.port || route.username || route.password || !route.pathname.startsWith('/backend-api/codex/')) return null;
  const identity = tokenIdentity(headers.get('authorization'));
  if (!identity || !managed.has(identity.identityKey)) return null;
  headers.set('chatgpt-account-id', identity.accountID);
  return identity;
}
