import { EventEmitter } from 'node:events';
import { updateAircraftLedger,updatePresenceLedger } from '../web/nameplates.mjs';

export class UpstreamError extends Error {
  constructor(message, status = 502) { super(message); this.status = status; }
}
export function upstreamAddress(input) {
  const url = new URL(input);
  const local = ['127.0.0.1', 'localhost', '[::1]'].includes(url.hostname);
  if (url.username || url.password || url.search || url.hash || url.pathname !== '/' ||
      !['http:', 'https:'].includes(url.protocol) || (url.protocol === 'http:' && !local))
    throw new Error('主服务器必须是 HTTPS 地址；仅回环地址允许 HTTP');
  return url.origin;
}

/** The director owns this session. No upstream credential is sent to a browser. */
export class Upstream extends EventEmitter {
  constructor(address) {
    super();this.address = upstreamAddress(address);this.token = null;this.user = null;
    this.epoch = null;this.sources = [];this.sourcesReceivedAt = null;this.states = new Map();this.desired = new Set();
    this.status = 'logged_out';this.socket = null;this.retry = null;this.heartbeat = null;
    this.attempts = 0;this.generation = 0;this.stopped = true;this.lastMessage = 0;
  }
  async request(path, { method = 'GET', body, token = this.token } = {}) {
    let response;
    try {
      response = await fetch(this.address + path, { method,
        headers: { 'Content-Type': 'application/json', ...(token ? { Authorization: `Bearer ${token}` } : {}) },
        body: body === undefined ? undefined : JSON.stringify(body), signal: AbortSignal.timeout(5000), redirect: 'error' });
    } catch { throw new UpstreamError('无法连接主服务器，请检查地址、网络和证书'); }
    let value;try { value = await response.json(); } catch { throw new UpstreamError('主服务器返回了无效数据'); }
    if (!response.ok) {
      const message = ({ invalid_credentials: '账号或密码错误', login_limited: '登录请求过多，请稍后重试',
        unauthorized: '登录已过期，请重新登录', admin_required: '需要管理员权限', director_required:'需要导播权限',
})[value.error] ?? '主服务器拒绝了请求';
      throw new UpstreamError(message, response.status);
    }
    return value;
  }
  async login(username, password) {
    const reply = await this.request('/api/v1/auth/login', { method: 'POST', body: { username, password }, token: null });
    const old = this.token;this.stop();
    if (old) this.request('/api/v1/auth/logout', { method: 'POST', token: old }).catch(() => {});
    this.token = reply.accessToken;this.user = reply.user;this.epoch = reply.serverEpoch;
    this.sources = [];this.states.clear();this.desired.clear();this.stopped = false;
    this.expiresAt = Date.now() + reply.expiresIn * 1000;this.attempts = 0;
    this.status = 'connecting';this.emit('change');this.connect();return this.user;
  }
  stop() {
    this.stopped = true;this.generation++;clearTimeout(this.retry);clearInterval(this.heartbeat);
    const socket = this.socket;this.socket = null;socket?.close();
  }
  async logout() {
    const token = this.token;this.stop();this.token = null;this.user = null;
    this.sources = [];this.states.clear();this.desired.clear();this.status = 'logged_out';this.emit('change');
    if (token) await this.request('/api/v1/auth/logout', { method: 'POST', token }).catch(() => {});
  }
  expire() {
    this.stop();this.token = null;this.status = 'expired';this.sources = [];this.states.clear();
    this.emit('change');this.emit('expired');
  }
  async connect() {
    if (this.stopped) return;
    const generation = ++this.generation;this.status = this.attempts ? 'reconnecting' : 'connecting';this.emit('change');
    try {
      const { ticket } = await this.request('/api/v1/auth/ws-ticket', { method: 'POST' });
      if (this.stopped || generation !== this.generation) return;
      const url = new URL(this.address);url.protocol = url.protocol === 'https:' ? 'wss:' : 'ws:';
      url.pathname = '/ws/v1/telemetry';url.searchParams.set('ticket', ticket);
      const socket = new WebSocket(url);this.socket = socket;this.lastMessage = Date.now();
      const current = () => !this.stopped && generation === this.generation && this.socket === socket;
      const handshake = setTimeout(() => { if (current() && socket.readyState !== WebSocket.OPEN) socket.close(); }, 8000);
      socket.addEventListener('open', () => { clearTimeout(handshake); });
      socket.addEventListener('message', event => {
        if (!current()) return;this.lastMessage = Date.now();
        try { this.receive(JSON.parse(event.data)); } catch { socket.close(); }
      });
      socket.addEventListener('error', () => {}); // close handles retry; never log ticket URLs.
      socket.addEventListener('close', () => {
        clearTimeout(handshake);if (!current()) return;this.socket = null;clearInterval(this.heartbeat);this.reconnect();
      });
      clearInterval(this.heartbeat);
      this.heartbeat = setInterval(() => {
        if (!current()) return;
        if (Date.now() >= this.expiresAt) { this.expire();return; }
        if (Date.now() - this.lastMessage > 15000) { socket.close();return; }
        this.send({ type: 'ping' });
      }, 5000);this.heartbeat.unref();
    } catch (error) {
      if (this.stopped || generation !== this.generation) return;
      if ([401, 403].includes(error.status)) this.expire();else this.reconnect();
    }
  }
  reconnect() {
    if (this.stopped) return;
    this.status = 'reconnecting';this.emit('change');
    const delay = Math.min(10000, 500 * 2 ** Math.min(this.attempts++, 5)) + Math.random() * 250;
    clearTimeout(this.retry);this.retry = setTimeout(() => this.connect(), delay);this.retry.unref();
  }
  send(message) { if (this.socket?.readyState === WebSocket.OPEN) this.socket.send(JSON.stringify(message)); }
  subscribe(id) {
    const state = this.states.get(id);
    this.send({ type: 'subscribe', sourceId: id, ...(state && state.cursor !== null ? { afterSeq: state.cursor, serverEpoch: this.epoch } : {}) });
  }
  select(ids) {
    const next = new Set(ids);
    if (next.size > 16) throw new Error('同时订阅的数据源不能超过 16 个');
    for (const id of this.desired) if (!next.has(id)) { this.send({ type: 'unsubscribe', sourceId: id });this.states.delete(id); }
    const previous = this.desired;this.desired = next;
    for (const id of next) if (!previous.has(id) && this.status === 'connected') this.subscribe(id);
  }
  state(id) {
    if (!this.states.has(id)) this.states.set(id, { snapshot: null, events: [], cursor: null, gaps: [], resync: null,aircraftLedger:[] });
    return this.states.get(id);
  }
  receive(message) {
    if (message.type === 'welcome') {
      if (this.epoch !== message.serverEpoch) { this.states.clear();this.sources = [];this.emit('reset'); }
      this.epoch = message.serverEpoch;this.user = message.user;this.status = 'connected';this.attempts = 0;
      for (const id of this.desired) this.subscribe(id);
    } else if (message.serverEpoch !== this.epoch) return;
    else if (message.type === 'sources') {
      this.sources = message.sources;this.sourcesReceivedAt = Date.now();
      for(const source of this.sources){const state=this.states.get(source.sourceId);if(state)updatePresenceLedger(state.aircraftLedger,source.hookStatus?.players);}
      const allowed = new Set(this.sources.map(source => source.sourceId));
      for (const id of this.states.keys()) if (!allowed.has(id)) this.states.delete(id);
    } else if (message.type === 'source_removed') { this.states.delete(message.sourceId); }
    else if (message.type === 'resync_required') {
      if (!this.desired.has(message.sourceId)) return;
      const state = this.state(message.sourceId);state.events = [];state.cursor = null;state.resync = message.reason;
    } else if (message.type === 'snapshot') {
      if (!this.desired.has(message.sourceId)) return;
      const state=this.state(message.sourceId);state.snapshot=message.state;
      state.aircraftLedger=updateAircraftLedger(state.aircraftLedger,message.state);
      updatePresenceLedger(state.aircraftLedger,this.sources.find(s=>s.sourceId===message.sourceId)?.hookStatus?.players);
    } else if (message.type === 'events') {
      if (!this.desired.has(message.sourceId)) return;
      const state = this.state(message.sourceId), receivedAt = Date.now();
      state.aircraftLedger=updateAircraftLedger(state.aircraftLedger,null,message.events.filter(e=>state.cursor===null||e.eventSeq>state.cursor));
      for (const event of message.events) if (state.cursor === null || event.eventSeq > state.cursor)
        state.events.push({ ...event, receivedAt, historical: message.historical });
      state.cursor = message.throughSeq;state.gaps = message.gaps;
      let bytes = 0;const kept = [];
      for (let i = state.events.length - 1; i >= 0 && kept.length < 200; i--) {
        bytes += JSON.stringify(state.events[i]).length;if (bytes > 2 * 1024 * 1024) break;kept.push(state.events[i]);
      }
      state.events = kept.reverse();
    } else if (message.type === 'error') { this.lastError = message.error; }
    else return;
    this.emit('change');
  }
  overview() { return { status: this.status, serverEpoch: this.epoch, sources: this.sources, sourcesReceivedAt: this.sourcesReceivedAt, expiresAt: this.expiresAt ?? null }; }
}
