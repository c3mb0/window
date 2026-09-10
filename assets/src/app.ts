import { Terminal } from '@xterm/xterm';
import { FitAddon } from '@xterm/addon-fit';
import { Socket, Channel } from 'phoenix';
import roles from './theme.json';
import '@xterm/xterm/css/xterm.css';
import './style.css';

for (const [key, value] of Object.entries(roles)) document.documentElement.style.setProperty(`--${key}`, value);
const theme = {
  background: roles.canvas, foreground: roles.text, cursor: roles.text, cursorAccent: roles.canvas,
  selectionBackground: roles.copySurface, selectionForeground: roles.text,
  black: roles.canvas, red: roles.negative, green: roles.positive, yellow: roles.pending,
  blue: roles.identityBlue, magenta: roles.identityViolet, cyan: roles.identityAqua, white: roles.text,
  brightBlack: roles.dim, brightRed: roles.negative, brightGreen: roles.positive, brightYellow: roles.pending,
  brightBlue: roles.identityBlue, brightMagenta: roles.identityViolet, brightCyan: roles.identityAqua, brightWhite: roles.text,
};
const tabstrip = document.querySelector<HTMLDivElement>('#tabs')!;
const surface = document.querySelector<HTMLElement>('#terminals')!;
const add = document.querySelector<HTMLButtonElement>('#new')!;
const suppliedToken = new URLSearchParams(location.hash.slice(1)).get('token');
const token = (() => {
  try {
    if (suppliedToken) sessionStorage.setItem('window.startupToken', suppliedToken);
    const saved = sessionStorage.getItem('window.startupToken') || '';
    // Tab-scoped storage survives refresh; the capability stays out of URL history.
    history.replaceState(null, '', location.pathname);
    return saved;
  } catch {
    // If storage is unavailable, retain the fragment so refresh still works.
    return suppliedToken || '';
  }
})();
const tabs: Tab[] = [];
let active: Tab | undefined;
let ordinal = 0;
class Tab {
  term = new Terminal({theme, fontFamily: '"SFMono-Regular", Menlo, Monaco, monospace', fontSize: 14,
    lineHeight: 1.12, scrollback: 5000, cursorBlink: true, macOptionIsMeta: true,
    drawBoldTextInBrightColors: false, allowProposedApi: false,
    // Links remain text: no hyperlink addon or OSC 8 handler that opens a URL.
    linkHandler: {activate: () => {}}});
  fit = new FitAddon();
  pane = document.createElement('section');
  item = document.createElement('div');
  select = document.createElement('button');
  close = document.createElement('button');
  socket: Socket;
  channel?: Channel;
  connected = false;
  disposed = false;
  ended = false;
  label = `Terminal ${++ordinal}`;
  inputQueue: Uint8Array[] = [];
  queuedBytes = 0;
  sending = false;
  sequence = 0;
  constructor() {
    this.item.className = 'tab';
    this.select.textContent = this.label;
    this.select.setAttribute('role', 'tab');
    this.pane.id = `terminal-${ordinal}`;
    this.pane.setAttribute('role', 'tabpanel');
    this.select.id = `tab-${ordinal}`;
    this.select.setAttribute('aria-controls', this.pane.id);
    this.pane.setAttribute('aria-labelledby', this.select.id);
    this.close.textContent = '×';
    this.close.setAttribute('aria-label', `Close ${this.label}`);
    this.close.className = 'close';
    this.select.onclick = () => activate(this);
    this.close.onclick = e => { e.stopPropagation(); remove(this); };
    this.item.append(this.select, this.close);
    tabstrip.append(this.item);
    surface.append(this.pane);
    this.term.loadAddon(this.fit);
    this.term.open(this.pane);
    this.socket = new Socket('/socket', {params: {token}, heartbeatIntervalMs: 10000, reconnectAfterMs: () => 86400000});
    this.socket.onError(() => this.disconnect());
    this.socket.onClose(() => this.disconnect());
    this.term.onData(data => this.input(new TextEncoder().encode(data)));
    this.term.onBinary(data => this.input(Uint8Array.from(data, c => c.charCodeAt(0) & 255)));
    this.term.attachCustomKeyEventHandler(e => {
      if (e.metaKey && e.key.toLowerCase() === 'c' && this.term.hasSelection()) {
        if (e.type === 'keydown') navigator.clipboard.writeText(this.term.getSelection()).catch(() => {});
        return false;
      }
      // Let native paste deliver the clipboard once through xterm's paste handler.
      if (e.metaKey && e.key.toLowerCase() === 'v') return false;
      return true;
    });
  }
  start() {
    this.fit.fit();
    if (!token) { this.state('Missing startup token — open the launcher URL'); return; }
    this.socket.connect();
    const channel = this.socket.channel(`terminal:${crypto.randomUUID()}`, {rows: this.term.rows, cols: this.term.cols});
    this.channel = channel;
    channel.on('output', ({hex}: {hex: string}) => {
      if (this.disposed) return;
      const bytes = Uint8Array.from(hex.match(/../g) || [], x => parseInt(x, 16));
      this.term.write(bytes, () => {
        if (!this.disposed && this.socket.isConnected()) channel.push('credit', {bytes: bytes.length});
      });
    });
    channel.on('exited', ({code, signal}: {code: number | null; signal: number | null}) => {
      this.ended = true; this.connected = false; this.inputQueue = []; this.queuedBytes = 0;
      this.state(`Exited ${code ?? `signal ${signal}`}`);
    });
    channel.on('failed', ({reason}: {reason: string}) => { this.state(reason); this.disconnect(false); });
    channel.onError(() => this.disconnect());
    channel.join().receive('ok', () => { if (!this.disposed) {this.connected = true; this.resize();} })
      .receive('error', ({reason}: {reason: string}) => {this.state(reason); this.disconnect(false);})
      .receive('timeout', () => {this.state('Shell creation timed out'); this.disconnect(false);});
  }
  state(message: string) {
    this.select.textContent = `${this.label} · ${message}`;
    this.select.title = message;
  }
  disconnect(show = true) {
    if (this.disposed) return;
    this.connected = false;
    this.inputQueue = []; this.queuedBytes = 0;
    if (show && !this.ended) this.state('Disconnected');
    // No automatic rejoin, replacement shell, or buffered input replay.
    this.socket.disconnect();
  }
  input(bytes: Uint8Array) {
    if (!this.connected || this.ended || this.disposed) return;
    if (this.queuedBytes + bytes.length > 65536) {
      this.state('Input exceeded 64 KiB — disconnected'); this.disconnect(false); return;
    }
    for (let offset = 0; offset < bytes.length; offset += 4096) this.inputQueue.push(bytes.slice(offset, offset + 4096));
    this.queuedBytes += bytes.length;
    this.drainInput();
  }
  drainInput() {
    if (this.sending || !this.connected) return;
    const bytes = this.inputQueue.shift();
    if (!bytes) return;
    this.sending = true;
    const hex = Array.from(bytes, b => b.toString(16).padStart(2, '0')).join('');
    this.channel!.push('input', {hex, seq: ++this.sequence}).receive('ok', () => {
      this.queuedBytes -= bytes.length; this.sending = false; this.drainInput();
    }).receive('error', () => { this.state('Input rejected'); this.disconnect(false); })
      .receive('timeout', () => { this.state('Input delivery unknown — disconnected'); this.disconnect(false); });
  }
  resize() {
    if (this.disposed || active !== this) return;
    this.fit.fit();
    if (this.connected) this.channel!.push('resize', {rows: this.term.rows, cols: this.term.cols});
  }
  dispose() {
    this.disposed = true;
    const disconnect = () => this.socket.disconnect();
    if (this.socket.isConnected() && this.channel) {
      this.channel.push('close', {}).receive('ok', disconnect).receive('error', disconnect).receive('timeout', disconnect);
    } else disconnect();
    this.term.dispose(); this.pane.remove(); this.item.remove(); this.inputQueue = [];
  }
}
function activate(tab: Tab) {
  active = tab;
  for (const t of tabs) {
    const selected = t === tab;
    t.pane.hidden = !selected; t.item.classList.toggle('active', selected);
    t.select.setAttribute('aria-selected', String(selected));
  }
  tab.resize(); tab.term.focus();
}
function remove(tab: Tab) {
  const index = tabs.indexOf(tab);
  tabs.splice(index, 1); tab.dispose();
  if (active === tab) {
    active = undefined;
    const next = tabs[Math.min(index, tabs.length - 1)];
    if (next) activate(next); else add.focus();
  } else {
    active?.term.focus();
  }
}
function create() {const tab = new Tab(); tabs.push(tab); activate(tab); tab.start();}
add.onclick = create;
let resizeFrame = 0;
new ResizeObserver(() => { cancelAnimationFrame(resizeFrame); resizeFrame = requestAnimationFrame(() => active?.resize()); }).observe(surface);
window.addEventListener('offline', () => tabs.forEach(t => t.disconnect()));
window.addEventListener('pagehide', () => tabs.forEach(t => t.socket.disconnect()));
await document.fonts.ready;
create();
