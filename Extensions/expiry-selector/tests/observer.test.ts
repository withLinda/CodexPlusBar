import { expect, test } from 'vitest';
import { RequestObserver, cohereAccountHeader, repairTransportHeaders, type RequestScope } from '../src/plugin/request-observer.js';
import { tokenIdentity } from '../src/shared/identity.js';
import { credential } from './runtime/fixtures.js';
const auth = (name: 'A' | 'B') => `Bearer ${credential(name).access}`;
const a = tokenIdentity(auth('A'))!, b = tokenIdentity(auth('B'))!;
const managed = new Set([a.identityKey, b.identityKey]);
const scope: RequestScope = { locationKey: '/fixture', sessionID: 'session', providerID: 'openai', modelID: 'model', agent: 'build', kind: 'primary' };

test.each(['chatgpt-account-id', 'ChatGPT-Account-ID'])('%s coherence changes only account header, never authorization', casing => {
  const headers = new Headers({ Authorization: auth('B'), [casing]: a.accountID, 'x-fixture': 'same' });
  expect(cohereAccountHeader('https://chatgpt.com/backend-api/codex/responses', headers, managed)).toEqual(b);
  expect(headers.get('authorization')).toBe(auth('B'));
  expect(headers.get('chatgpt-account-id')).toBe(b.accountID);
  expect([...headers.keys()].filter(key => key.toLowerCase() === 'chatgpt-account-id')).toHaveLength(1);
  expect(headers.get('x-fixture')).toBe('same');
  const before = [...headers];
  cohereAccountHeader('wss://chatgpt.com/backend-api/codex/responses', headers, managed);
  expect([...headers]).toEqual(before);
});
test.each([
  'https://evil.test/backend-api/codex/responses', 'https://chatgpt.com.evil.test/backend-api/codex/responses',
  'https://user@chatgpt.com/backend-api/codex/responses', 'https://chatgpt.com:123/backend-api/codex/responses',
  'http://chatgpt.com/backend-api/codex/responses', 'https://chatgpt.com/v1/responses',
])('unsupported route %s stays untouched', url => {
  const headers = new Headers({ authorization: auth('B'), 'chatgpt-account-id': a.accountID });
  expect(repairTransportHeaders({ url, headers, managed }).reason).toBe('unsupported-route');
  expect(headers.get('chatgpt-account-id')).toBe(a.accountID);
});
test.each(['Bearer sk-fixture', 'not-a-bearer', 'Bearer x.invalid.y', '', 'Bearer fixture.e30.signature'])('unattributable authorization remains untouched', authorization => {
  const headers = new Headers({ authorization, 'ChatGPT-Account-ID': a.accountID });
  expect(cohereAccountHeader('https://chatgpt.com/backend-api/codex/responses', headers, managed)).toBeNull();
  expect(headers.get('chatgpt-account-id')).toBe(a.accountID);
});
test('conflicting canonical JWT user claims are rejected', () => {
  const claims = { 'https://api.openai.com/auth': { chatgpt_account_id: 'a', chatgpt_user_id: 'u', user_id: 'different' } };
  expect(tokenIdentity(`Bearer fixture.${Buffer.from(JSON.stringify(claims)).toString('base64url')}.signature`)).toBeNull();
});
test('unmanaged identities cannot repair a header', () => {
  const headers = new Headers({ authorization: auth('B'), 'chatgpt-account-id': a.accountID });
  expect(cohereAccountHeader('https://chatgpt.com/backend-api/codex/responses', headers, new Set([a.identityKey]))).toBeNull();
  expect(headers.get('chatgpt-account-id')).toBe(a.accountID);
});

test('auxiliary work and late active switch cannot replace actual primary identity', () => {
  const observer = new RequestObserver();
  const generation = observer.beginPrimary(scope);
  observer.observeTransport({ ...scope, generation, identity: a, transport: 'websocket', observedAtMs: 1 });
  for (const kind of ['title', 'generate', 'compaction'] as const) {
    observer.beginPrimary({ ...scope, kind });
    observer.observeTransport({ ...scope, kind, generation, identity: b, transport: 'http', observedAtMs: 2 });
  }
  observer.observeTransport({ ...scope, generation, identity: a, transport: 'http', observedAtMs: 3 });
  expect(observer.takeRetryAttribution(scope)).toMatchObject({ identity: a, generation });
  expect(observer.takeRetryAttribution(scope)).toBeNull();
});

test('different identities within a fallback attempt are ambiguous, and stale generations cannot revive it', () => {
  const observer = new RequestObserver();
  const old = observer.beginPrimary(scope);
  observer.observeTransport({ ...scope, generation: old, identity: a, transport: 'websocket', observedAtMs: 1 });
  observer.observeTransport({ ...scope, generation: old, identity: b, transport: 'http', observedAtMs: 2 });
  expect(observer.takeRetryAttribution(scope)).toBeNull();
  const generation = observer.beginPrimary(scope);
  observer.observeTransport({ ...scope, generation, identity: b, transport: 'http', observedAtMs: 3 });
  observer.observeTransport({ ...scope, generation: old, identity: a, transport: 'http', observedAtMs: 4 });
  observer.forgetSession(scope.locationKey, scope.sessionID, old);
  expect(observer.takeRetryAttribution(scope)).toMatchObject({ identity: b, generation });
});

test('same-transport duplication, missing identity and mismatched model cannot yield attribution', () => {
  for (const failure of ['duplicate', 'missing', 'model']) {
    const observer = new RequestObserver(); const generation = observer.beginPrimary(scope);
    observer.observeTransport({ ...scope, generation, identity: a, transport: 'http', observedAtMs: 1 });
    if (failure !== 'model') observer.observeTransport({ ...scope, generation, identity: failure === 'missing' ? null : a, transport: 'http', observedAtMs: 2 });
    expect(observer.takeRetryAttribution(failure === 'model' ? { ...scope, modelID: 'other' } : scope)).toBeNull();
  }
});

test('attribution memory is bounded and session completion does not clear newer work', () => {
  let now = 100;
  const observer = new RequestObserver(10_000, () => now);
  for (let index = 0; index <= 10_000; index++) observer.beginPrimary({ ...scope, sessionID: String(index) });
  expect(observer.size).toBe(10_000);
  expect(observer.generation({ ...scope, sessionID: '0' })).toBeNull();
  now = 200;
  observer.beginPrimary(scope);
  observer.handleLifecycle({ type: 'session.execution.succeeded', created: 150, location: { directory: scope.locationKey }, data: { sessionID: scope.sessionID } });
  expect(observer.generation(scope)).not.toBeNull();
  observer.handleLifecycle({ type: 'session.execution.interrupted', created: 201, location: { directory: scope.locationKey }, data: { sessionID: scope.sessionID } });
  expect(observer.generation(scope)).toBeNull();
  observer.beginPrimary(scope);
  observer.handleLifecycle({ type: 'session.execution.succeeded', created: 201, data: { sessionID: scope.sessionID } });
  expect(observer.generation(scope)).toBeNull();
  observer.forgetLocation(scope.locationKey);
  expect(observer.size).toBe(0);
});
