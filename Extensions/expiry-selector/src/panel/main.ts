import { connectHost } from '@openchamber/sdk';
import { applyHostReady, mountButton } from '@openchamber/sdk/ui';
import { PanelControl, type PanelState } from './control.js';

const host = connectHost();
const node = (id: string) => document.getElementById(id)!;
const set = (id: string, value: string) => { if (node(id).textContent !== value) node(id).textContent = value; };
const age = (time: number | null) => time === null ? 'unknown' : Date.now() - time < 60_000 ? 'just now' : `${Math.floor(Math.max(0, Date.now() - time) / 60_000)}m ago`;
const expiryText = (time: number | null) => {
  if (time === null) return 'Unknown expiry';
  const remaining = time - Date.now();
  if (remaining <= 0) return 'Expired';
  const hours = Math.floor(remaining / 3_600_000), days = Math.floor(hours / 24);
  return days > 0 ? `Expires in ${days}d ${hours % 24}h` : hours > 0 ? `Expires in ${hours}h` : 'Expires in less than 1h';
};
const messages: Record<string, string> = {
  paused: 'Auto is paused. Your native account stays selected.', maintenance: 'Sign-in maintenance holds Auto paused. Finish the operation in CodexPlusBar before resuming.',
  'competing-switcher': 'Native limit switching or fallback is still enabled in a location. Disable those settings in OpenChamber before enabling Auto.',
  'publisher-stale': 'CodexPlusBar evidence is stale. Open CodexPlusBar and refresh its accounts.',
  'snapshot-missing': 'Open CodexPlusBar to publish account evidence.', 'snapshot-invalid': 'Account evidence could not be verified. Refresh CodexPlusBar.',
  'catalog-untrusted': 'The account catalog is not trusted yet. Check CodexPlusBar.', 'ownership-unavailable': 'Another process owns the selector port. Auto cannot run here.',
  'unsupported-runtime': 'This OpenCode version has not passed compatibility checks. Auto is blocked.',
  'no-eligible-account': 'No account qualifies. Your native account stays selected.', 'unsupported-route': 'This provider route is unsupported. Auto is blocked.',
  'persistence-unavailable': 'Selector state could not be saved or verified. Auto is blocked.', 'activation-unconfirmed': 'Native activation could not be confirmed. Check the selected account in OpenChamber.',
  'native-unavailable': 'The native account could not be verified.', 'checking-cancelled': 'Selection was interrupted. Recheck for the latest state.',
  'snapshot-changed': 'Account evidence changed during checking. Recheck to try again.', 'binding-missing': 'Native connection is missing.',
  'binding-conflict': 'Conflicting account bindings.', 'expiry-unknown': 'Expiry is unknown.', 'expiry-stale': 'Expiry evidence is stale.',
  expired: 'Subscription has expired.', inactive: 'Subscription is inactive.', unusable: 'Subscription is not usable.',
  'usage-unknown': 'Quota is unknown.', 'usage-stale': 'Quota evidence is stale.', 'usage-denied': 'Quota is unavailable.',
  'five-hour-empty': 'Five-hour quota is exhausted.', 'seven-day-empty': 'Weekly quota is exhausted.',
  'reset-unconfirmed': 'Waiting for fresh quota after reset.', cooldown: 'Waiting for reset and fresh positive quota.', activated: 'Native account selected.',
};
const reason = (code: string) => messages[code] ?? code.replaceAll('-', ' ');
const model = new PanelControl(input => host.serviceRequest(input), render);
const modeButton = mountButton(node('mode-control'), { label: 'Enable Auto', disabled: true, onClick: () => {
  void model.command('mode', model.state.status?.mode === 'auto' ? 'paused' : 'auto');
} });
const recheck = mountButton(node('recheck-control'), { label: 'Recheck', variant: 'outline', onClick: () => {
  if (model.state.phase === 'unavailable') void model.load(); else void model.command('recheck');
} });
const retry = mountButton(node('retry-control'), { label: 'Retry acknowledgement', variant: 'outline', onClick: () => { void model.retry(); } });

function render(state: PanelState) {
  const s = state.status, pending = state.pending !== null;
  const unverified = state.phase === 'unavailable' || state.phase === 'loading';
  const blocked = s?.blockedReason && s.blockedReason !== 'paused';
  const stale = s?.snapshotGeneratedAtMs != null && Date.now() - s.snapshotGeneratedAtMs > 90_000;
  set('mode', state.phase === 'pending' ? 'Waiting for acknowledgement' : state.phase === 'unconfirmed' ? 'Unconfirmed' : unverified ? 'Unavailable' : blocked ? 'Blocked' : s?.mode === 'auto' ? 'Auto' : 'Paused');
  modeButton.update({ label: s?.mode === 'auto' ? 'Pause Auto' : s?.lastSwitch || s?.holdsCount ? 'Resume Auto' : 'Enable Auto',
    disabled: pending || unverified || (!s || (s.holdsCount > 0 && s.mode !== 'auto')), loading: state.phase === 'pending' && state.pending?.route === 'mode' });
  recheck.update({ label: state.phase === 'unavailable' ? 'Reconnect' : 'Recheck', disabled: pending || state.phase === 'loading',
    loading: state.phase === 'pending' && state.pending?.route === 'recheck' });
  node('retry-control').hidden = state.phase !== 'unconfirmed'; retry.update({ disabled: state.phase === 'pending' });
  set('notice', state.error ?? (state.phase === 'pending' ? 'Waiting for the selector to finish outstanding work. The control is not acknowledged yet.' :
    stale ? reason('publisher-stale') : s?.blockedReason ? reason(s.blockedReason) : s ? 'Auto uses verified expiry and quota. Native OAuth refresh remains managed by OpenCode.' : 'Connecting to the local selector…'));
  node('notice').dataset.tone = state.error || blocked || stale ? 'warning' : 'neutral';
  const label = (id: string | null) => s?.accounts.find(row => row.credentialID === id)?.label || (id ? 'Unmapped native account' : 'None verified');
  set('active', s ? `${s.activeLabel || label(s.activeCredentialID)} · checked ${age(s.nativeObservedAtMs)}` : 'Not yet verified');
  set('next', s && !stale && !unverified ? label(s.nextCredentialID) : 'Not yet verified');
  set('freshness', s ? `Published ${age(s.snapshotGeneratedAtMs)}` : 'Waiting for CodexPlusBar');
  set('count', s ? String(s.accounts.length) : '');
  const rows = (s?.accounts ?? []).map(account => {
    const item = document.createElement('li'); item.className = 'account';
    const heading = document.createElement('div'); heading.className = 'account-heading';
    const name = document.createElement('span'); name.className = 'account-name'; name.textContent = account.label || 'Unnamed account'; heading.append(name);
    const tags = [account.credentialID === s?.activeCredentialID ? 'Native active' : null,
      account.credentialID === s?.nextCredentialID && !stale && !unverified ? 'Next eligible' : null].filter(Boolean);
    for (const tag of tags) { const el = document.createElement('span'); el.className = 'tag'; el.dataset.active = String(tag === 'Native active'); el.textContent = tag; heading.append(el); }
    item.append(heading);
    const expiry = document.createElement('p'); expiry.className = 'expiry'; expiry.textContent = expiryText(account.expiresAtMs);
    if (account.expiresAtMs !== null) expiry.title = new Date(account.expiresAtMs).toLocaleString();
    item.append(expiry);
    const quotas = document.createElement('div'); quotas.className = 'quotas';
    for (const [title, value] of [['5H', account.fiveHourRemaining], ['7D', account.sevenDayRemaining]] as const) {
      const group = document.createElement('span'), caption = document.createElement('span'), amount = document.createElement('strong');
      caption.className = 'muted'; caption.textContent = title; amount.textContent = value === null ? 'Unknown' : value === 'not-applicable' ? 'Not applicable' : `${value}% left`;
      group.append(caption, amount); quotas.append(group);
    }
    item.append(quotas);
    const evidence = document.createElement('p'); evidence.className = 'evidence muted'; evidence.textContent = `Quota ${age(account.usageObservedAtMs)} · expiry ${age(account.entitlementObservedAtMs)}`; item.append(evidence);
    const exclusion = s?.exclusions.find(row => row.credentialID === account.credentialID)?.code;
    if (exclusion) { const note = document.createElement('p'); note.className = 'reason'; note.textContent = reason(exclusion); item.append(note); }
    return item;
  });
  node('accounts').replaceChildren(...rows); node('empty').hidden = rows.length > 0;
  set('empty', stale ? reason('publisher-stale') : 'No verified account evidence yet. Open CodexPlusBar and refresh its accounts.');
  set('decision', s ? (s.blockedReason ? reason(s.blockedReason) : `Keep using ${s.activeLabel || label(s.activeCredentialID)}.`) +
    (s.lastSwitch ? ` Last switch ${age(s.lastSwitch.atMs)}.` : '') : 'Waiting for a verified status.');
  node('history').replaceChildren(...(s?.recentHistory ?? []).slice(-10).reverse().map(event => {
    const li = document.createElement('li'); li.textContent = `${age(event.atMs)} · ${reason(event.code)}${event.credentialID ? ` ${label(event.credentialID)}` : ''}`; return li;
  }));
  set('versions', s ? `Verified versions: OpenChamber ${s.supportedVersions.openchamber} · OpenCode ${s.supportedVersions.opencode}` : '');
}

let started = false;
const ready = host.onReady(context => { applyHostReady(context, document.documentElement); if (!started) { started = true; void model.load(); } });
const interval = setInterval(() => { if (started && !document.hidden) void model.load(); }, 5000);
window.addEventListener('pagehide', () => { clearInterval(interval); ready(); host.dispose(); modeButton.dispose(); recheck.dispose(); retry.dispose(); }, { once: true });
