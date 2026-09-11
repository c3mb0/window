import { Socket, Channel } from 'phoenix';

type Session = {id: string; name: string; launch_cwd: string; state: string; revision: number; updated_at: number; runtime: {live: boolean; attached: boolean}};
type Event = {id: string; revision: number; kind: string; observed_at: number; payload: string; pending: boolean};
type Status = {persistence: string; error: string | null; archive_error: string | null; lost_observations: number; admission: {queued: number; rejected: number}; outbox: {rows: number; bytes: number; oldest_event_at: number | null}; files: Record<string, number>; disk: {free_bytes: number | null; sampled_at: number | null}; last_archive_commit: string | null; outbox_limit: number};
const node = <K extends keyof HTMLElementTagNameMap>(tag: K, text = '', className = '') => {
  const element = document.createElement(tag); element.textContent = text; element.className = className; return element;
};
const size = (bytes: number | null) => bytes === null ? 'unknown' : `${(bytes / 1048576).toFixed(1)} MiB`;
const time = (ms: number) => new Date(ms).toLocaleString();

export function mountShelf(token: string, local: (id: string) => boolean, focus: (id: string) => void, rename: (id: string, name: string) => void) {
  const toggle = node('button', 'Sessions'); toggle.id = 'shelf-toggle'; toggle.setAttribute('aria-expanded', 'false'); toggle.setAttribute('aria-controls', 'session-shelf');
  document.querySelector('nav')!.append(toggle);
  const panel = node('aside'); panel.id = 'session-shelf'; panel.hidden = true; panel.setAttribute('role', 'dialog'); panel.setAttribute('aria-label', 'Session shelf');
  const header = node('div', '', 'shelf-header'); const heading = node('h2', 'Sessions');
  const close = node('button', '×'); close.setAttribute('aria-label', 'Close session shelf');
  header.append(heading, close);
  const explanation = node('p', 'Last observed state is saved here. “Live now” is checked against this running server.', 'shelf-muted');
  const message = node('p', '', 'shelf-message'); message.setAttribute('role', 'status');
  const toolbar = node('div', '', 'shelf-toolbar'); const refresh = node('button', 'Refresh'); const backup = node('button', 'Create backup'); toolbar.append(refresh, backup);
  const storage = node('details'); const summary = node('summary', 'Storage status'); const storageBody = node('div', '', 'storage-status'); storage.append(summary, storageBody);
  const list = node('div', '', 'shelf-list'); list.setAttribute('aria-label', 'Recorded sessions');
  const detail = node('div', '', 'shelf-detail');
  panel.append(header, explanation, message, toolbar, storage, list, detail); document.body.append(panel);
  let channel: Channel | undefined; let socket: Socket | undefined; let selected: Session | undefined; let selection = 0; let busy = false;
  const request = <T>(event: string, data = {}, timeout = 16000): Promise<T> => new Promise((resolve, reject) => {
    if (!channel) { reject(new Error('Session shelf is disconnected')); return; }
    channel.push(event, data, timeout).receive('ok', resolve).receive('error', ({reason}: {reason: string}) => reject(new Error(reason)))
      .receive('timeout', () => reject(new Error(event === 'backup' ? 'Backup is still unconfirmed. Check the backup directory for a completed manifest.' : 'Session shelf request timed out')));
  });
  const report = (error: unknown) => {message.textContent = error instanceof Error ? error.message : String(error);};
  function hide() {panel.hidden = true; toggle.setAttribute('aria-expanded', 'false'); toggle.focus();}
  close.onclick = hide;
  panel.addEventListener('keydown', e => {if (e.key === 'Escape') {e.stopPropagation(); hide();}});
  function renderStatus(status: Status) {
    storageBody.replaceChildren();
    const age = status.outbox.oldest_event_at ? `${Math.max(0, Math.floor((Date.now() - status.outbox.oldest_event_at) / 1000))}s` : 'none';
    for (const text of [
      `Persistence: ${status.persistence}. ${status.error || ''}`,
      status.archive_error ? `Archive delayed: ${status.archive_error}` : 'Archive: no reported error.',
      `Pending: ${status.outbox.rows ?? 'unknown'} events · ${size(status.outbox.bytes)} of ${size(status.outbox_limit)} · oldest ${age}`,
      `Last archive commit: ${status.last_archive_commit ? time(Number(status.last_archive_commit)) : 'none yet'}`,
      `Unrecorded observations since storage started: ${status.lost_observations}. Rejected requests/observations: ${status.admission.rejected}. Queued: ${status.admission.queued}.`,
      `Disk free: ${size(status.disk.free_bytes)}${status.disk.sampled_at ? ` (sampled ${time(status.disk.sampled_at)})` : ''}`,
      ...Object.entries(status.files).map(([name, bytes]) => `${name}: ${size(bytes)}`),
      'Unrecorded observations cannot be reconstructed exactly. History is never automatically pruned.'
    ]) storageBody.append(node('p', text));
    summary.textContent = `Storage · ${status.outbox.rows ?? '?'} pending${status.error || status.archive_error || status.lost_observations || status.admission.rejected ? ' · attention needed' : ''}`;
  }
  async function inspect(session: Session) {
    selected = session; const generation = ++selection; detail.replaceChildren();
    const title = node('h3', session.name); const cwd = node('p', session.launch_cwd || 'Launch directory not recorded', 'shelf-path');
    const state = node('p', `Last observed: ${session.state} · revision ${session.revision} · ${time(session.updated_at)}`, 'shelf-muted');
    const focusButton = node('button', session.runtime.live && !local(session.id) ? 'Live elsewhere' : 'Focus terminal'); focusButton.disabled = !session.runtime.live || !local(session.id);
    focusButton.onclick = async () => {
      try {await request('focus', {id: session.id}); if (local(session.id)) {hide(); focus(session.id);} else throw new Error('This terminal is no longer on this page');} catch (error) {report(error);}
    };
    const form = node('form', '', 'shelf-rename'); const label = node('label', 'Session name'); const input = node('input'); input.value = session.name; input.maxLength = 128; input.required = true; input.setAttribute('aria-label', 'Session name'); label.append(input);
    const save = node('button', 'Rename'); save.type = 'submit'; form.append(label, save);
    form.onsubmit = async e => {
      e.preventDefault(); save.disabled = true;
      try {const updated = await request<Session>('rename', {id: session.id, name: input.value}); rename(session.id, updated.name); message.textContent = 'Name saved.'; await load();} catch (error) {report(error);} finally {save.disabled = false;}
    };
    const timeline = node('ol', '', 'shelf-timeline'); const timelineTitle = node('h3', 'Recent history');
    detail.append(title, cwd, state, focusButton, form, timelineTitle, timeline);
    try {
      const result = await request<{events: Event[]; archive_error: string | null}>('timeline', {id: session.id});
      if (generation !== selection) return;
      if (result.archive_error) timeline.append(node('li', `Archive unavailable; showing pending events. ${result.archive_error}`));
      if (!result.events.length) timeline.append(node('li', 'No recorded events available.'));
      for (const event of result.events) {
        const item = node('li'); const payload = JSON.parse(event.payload);
        item.append(node('strong', `${event.kind.replaceAll('_', ' ')}${event.pending ? ' · pending archive' : ''}`), node('p', `#${event.revision} · ${time(event.observed_at)} · ${payload.state}`, 'shelf-muted'), node('p', payload.reason || ''));
        const receipt = node('details'); receipt.append(node('summary', 'Receipt'), node('pre', JSON.stringify({event_id: event.id, ...payload}, null, 2))); item.append(receipt); timeline.append(item);
      }
    } catch (error) {if (generation === selection) report(error);}
  }
  async function load() {
    if (busy) return; busy = true; refresh.disabled = true;
    try {
      const result = await request<{sessions: Session[]; status: Status}>('list'); renderStatus(result.status); list.replaceChildren();
      if (!result.sessions.length) list.append(node('p', 'No recorded sessions yet.'));
      for (const session of result.sessions) {
        const row = node('button', '', 'shelf-session'); row.append(node('strong', session.name), node('span', session.runtime.live ? 'Live now' : `Last observed: ${session.state}`, session.runtime.live ? 'shelf-live' : 'shelf-muted'), node('small', session.launch_cwd || 'Unknown launch directory', 'shelf-path'));
        row.onclick = () => {void inspect(session);}; list.append(row);
      }
      if (selected) {const updated = result.sessions.find(s => s.id === selected!.id); if (updated) void inspect(updated);}
    } catch (error) {report(error);} finally {busy = false; refresh.disabled = false;}
  }
  refresh.onclick = () => {message.textContent = ''; void load();};
  backup.onclick = async () => {
    backup.disabled = true; message.textContent = 'Creating paired backup… Terminal input remains available.';
    try {const result = await request<{directory: string}>('backup', {}, 125000); message.textContent = `Backup complete: ${result.directory}`; await load();} catch (error) {report(error);} finally {backup.disabled = false;}
  };
  toggle.onclick = () => {
    if (!panel.hidden) {hide(); return;}
    panel.hidden = false; toggle.setAttribute('aria-expanded', 'true'); close.focus();
    if (channel) {void load(); return;}
    socket = new Socket('/socket', {params: {token}, reconnectAfterMs: () => 86400000});
    socket.onClose(() => {message.textContent = 'Session shelf disconnected. Refresh the page to reconnect.';});
    socket.connect(); channel = socket.channel('shelf', {});
    channel.join().receive('ok', () => {void load();}).receive('error', report).receive('timeout', () => report('Session shelf connection timed out'));
  };
  window.addEventListener('pagehide', () => socket?.disconnect());
}
