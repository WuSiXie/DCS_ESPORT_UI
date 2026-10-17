import http from 'node:http';
import { readFile } from 'node:fs/promises';
import { dirname, join, resolve } from 'node:path';
import { fileURLToPath, pathToFileURL } from 'node:url';
import { createHash, randomBytes, timingSafeEqual } from 'node:crypto';
import { OutputStore } from './output-store.mjs';
import { FEATURES, EVENT_TYPES, LAYOUTS, defaultConfig, publicOutput, ValidationError } from './output-model.mjs';
import { Upstream } from './upstream.mjs';

const webRoot = resolve(dirname(fileURLToPath(import.meta.url)), '../web');
const equal = (a, b) => typeof a === 'string' && typeof b === 'string' && Buffer.byteLength(a) === Buffer.byteLength(b) &&
  timingSafeEqual(Buffer.from(a), Buffer.from(b));
const secret = () => randomBytes(32).toString('hex');
const safeMethod = method => ['GET', 'HEAD'].includes(method);

export async function createDirector({ port = 9170, directory = 'runtime/director', upstream = 'http://127.0.0.1:9080' } = {}) {
  if (!Number.isInteger(port) || port < 1 || port > 65535) throw new Error('无效的本地服务端口');
  const authority = new Upstream(upstream), clients = new Set();
  let store = null, session = null, csrf = null, busy = false, notify = null, closed = false;
  const cookieName = `dcs_director_${port}`;
  const server = http.createServer({ maxHeaderSize: 8192, requestTimeout: 10000, headersTimeout: 10000 }, route);
  server.maxConnections = 64;
  const origin = `http://127.0.0.1:${port}`;
  function sourceFor(output) {
    if (output.config.followLatest) return [...authority.sources].sort((a,b) => b.createdOrder - a.createdOrder)[0] ?? null;
    if (output.config.sourceEpoch !== authority.epoch) return null;
    return authority.sources.find(source => source.sourceId === output.config.sourceId) ?? null;
  }
  function refreshSubscriptions() {
    authority.select((store?.outputs ?? []).map(sourceFor).filter(Boolean).map(source => source.sourceId));
  }
  function localOutput(output) { return { ...publicOutput(output), url: `${origin}/output/${output.id}#${output.readKey}` }; }
  function controlState() {
    return { ...authority.overview(), user: authority.user, outputs: (store?.outputs ?? []).map(localOutput),
      states: Object.fromEntries(authority.states), serverTime: Date.now() };
  }
  function outputState(output) {
    const source = sourceFor(output), state = source ? authority.states.get(source.sourceId) : null;
    return { output: publicOutput(output), connection: authority.status, serverEpoch: authority.epoch, source, sourcesReceivedAt: authority.sourcesReceivedAt,
      snapshot: state?.snapshot ?? null, aircraftLedger:state?.aircraftLedger??[],events: state?.events ?? [], gaps: state?.gaps ?? [], resync: state?.resync ?? null, serverTime: Date.now() };
  }
  function push(client) {
    if (closed || !authority.token || !store) { client.response.end();clients.delete(client);return; }
    const output = client.outputId ? store.get(client.outputId) : null;
    if (client.outputId && (!output || !equal(output.readKey, client.key))) { client.response.end();clients.delete(client);return; }
    const text = `event: state\ndata: ${JSON.stringify(output ? outputState(output) : controlState())}\n\n`;
    if (Buffer.byteLength(text) > 16 * 1024 * 1024 || client.response.writableLength > 1024 * 1024) {
      client.response.destroy();clients.delete(client);return;
    }
    client.response.write(text);
  }
  function schedule() {
    refreshSubscriptions();if (notify) return;
    notify = setTimeout(() => { notify = null;for (const client of clients) push(client); }, 100);notify.unref();
  }
  authority.on('change', schedule);
  authority.on('expired', () => { session = null;csrf = null; });
  const keepalive = setInterval(() => {
    for (const client of clients) {
      if (client.response.writableLength > 1024 * 1024) client.response.destroy();else client.response.write(': keepalive\n\n');
    }
  }, 10000);keepalive.unref();
  function json(response, status, value) { response.writeHead(status, { 'Content-Type': 'application/json; charset=utf-8' });response.end(JSON.stringify(value)); }
  function authenticated(request) {
    const cookies = Object.fromEntries((request.headers.cookie ?? '').split(';').map(part => part.trim().split('=')));
    return authority.token && session && equal(cookies[cookieName], session);
  }
  function requireControl(request, write = false) {
    if (busy) throw new ValidationError('正在切换登录会话，请稍候', 409);
    if (!authenticated(request)) throw new ValidationError('请先登录主服务器', 401);
    if (write && !equal(request.headers['x-csrf-token'], csrf)) throw new ValidationError('控制页已失效，请刷新页面', 403);
    if (write && authority.user?.role === 'viewer') throw new ValidationError('当前账号为只读权限', 403);
  }
  async function body(request) {
    let size = 0;const parts = [];
    for await (const part of request) { size += part.length;if (size > 524288) throw new ValidationError('请求内容过大', 413);parts.push(part); }
    try { const value = JSON.parse(Buffer.concat(parts).toString('utf8'));if (!value || typeof value !== 'object' || Array.isArray(value)) throw new Error();return value; }
    catch { throw new ValidationError('JSON 必须是对象'); }
  }
  function stream(request, response, output = null) {
    if (clients.size >= 32) throw new ValidationError('本地实时连接已达上限', 503);
    response.writeHead(200, { 'Content-Type': 'text/event-stream; charset=utf-8', Connection: 'keep-alive', 'X-Accel-Buffering': 'no' });
    const client = { response, outputId: output?.id, key: output?.readKey };clients.add(client);
    response.on('close', () => clients.delete(client));push(client);
  }
  async function route(request, response) {
    response.setHeader('Cache-Control', 'no-store');response.setHeader('X-Content-Type-Options', 'nosniff');
    response.setHeader('Referrer-Policy', 'no-referrer');
    response.setHeader('Content-Security-Policy', "default-src 'self'; script-src 'self'; style-src 'self' 'unsafe-inline'; img-src 'self' data:; connect-src 'self'; frame-src 'self'; frame-ancestors 'self'; base-uri 'none'; form-action 'self'");
    try {
      const host = request.headers.host;
      if (![ `127.0.0.1:${port}`, `localhost:${port}` ].includes(host)) throw new ValidationError('不接受此 Host', 403);
      if (request.headers.origin && request.headers.origin !== `http://${host}`) throw new ValidationError('不接受跨站请求', 403);
      if (!safeMethod(request.method) && request.headers.origin !== `http://${host}`) throw new ValidationError('写操作必须来自本地控制页', 403);
      const url = new URL(request.url, origin), path = url.pathname;
      if (request.method === 'GET' && path === '/healthz') { json(response, 200, { status: 'ok', version: '0.8.0' });return; }
      if (path === '/api/login' && request.method === 'POST') {
        if (busy) throw new ValidationError('正在登录，请稍候', 409);
        const input = await body(request);
        if (typeof input.username !== 'string' || typeof input.password !== 'string') throw new ValidationError('请输入账号和密码');
        busy = true;let switched = false;
        try {
          const user = await authority.login(input.username, input.password);
          switched = true;
          for (const client of clients) client.response.end();clients.clear();
          const namespace = createHash('sha256').update(`${authority.address}\0${user.username}`).digest('hex');
          store = await new OutputStore(join(resolve(directory), namespace)).load();
          session = secret();csrf = secret();
          response.setHeader('Set-Cookie', `${cookieName}=${session}; HttpOnly; SameSite=Strict; Path=/; Max-Age=28800`);
          refreshSubscriptions();json(response, 200, { user, csrf });
        } catch (error) {
          if (switched) { await authority.logout();store = null;session = null;csrf = null; }
          throw error;
        } finally { busy = false; }
        return;
      }
      if (path === '/api/session' && request.method === 'GET') {
        requireControl(request);json(response, 200, { user: authority.user, csrf, ...authority.overview(),
          features: FEATURES, eventTypes: EVENT_TYPES, layouts: LAYOUTS, defaultConfig: defaultConfig() });return;
      }
      if (path === '/api/logout' && request.method === 'POST') {
        requireControl(request);if (!equal(request.headers['x-csrf-token'], csrf)) throw new ValidationError('控制页已失效',403);
        await authority.logout();store = null;session = null;csrf = null;
        response.setHeader('Set-Cookie', `${cookieName}=; HttpOnly; SameSite=Strict; Path=/; Max-Age=0`);
        json(response,200,{ loggedOut:true });return;
      }
      if (path === '/api/control/stream' && request.method === 'GET') { requireControl(request);stream(request,response);return; }
      if (path === '/api/outputs' && request.method === 'GET') { requireControl(request);json(response,200,store.outputs.map(localOutput));return; }
      if (path === '/api/outputs' && request.method === 'POST') {
        requireControl(request,true);const input = await body(request);
        const output = await store.create(input.config);schedule();json(response,201,localOutput(store.get(output.id)));return;
      }
      const control = path.match(/^\/api\/outputs\/([a-f0-9-]{36})$/u);
      if (control && ['PUT','DELETE'].includes(request.method)) {
        requireControl(request,true);const input = await body(request);
        if (request.method === 'PUT') {
          const output = await store.update(control[1],input.revision,input.config);schedule();json(response,200,localOutput(store.get(output.id)));
        } else { const result = await store.remove(control[1],input.revision);schedule();json(response,200,result); }
        return;
      }
      const output = path.match(/^\/api\/output\/([a-f0-9-]{36})\/(state|stream)$/u);
      if (output && request.method === 'GET') {
        const record = store?.get(output[1]), token = request.headers.authorization?.replace(/^Bearer /u,'');
        if (busy || !authority.token || !record || !equal(token,record.readKey)) throw new ValidationError('输出访问已失效，请在控制台重新登录并复制地址',401);
        if (output[2] === 'stream') stream(request,response,record);else json(response,200,outputState(record));return;
      }
      const file = path === '/' ? 'control.html' : /^\/output\/[a-f0-9-]{36}$/u.test(path) ? 'output.html' : path.slice(1);
      const assets = { 'control.html':'text/html', 'output.html':'text/html', 'app.css':'text/css', 'hud.css':'text/css',
        'player-picker.mjs':'text/javascript','plate-controls.mjs':'text/javascript','control.mjs':'text/javascript', 'output.mjs':'text/javascript', 'telemetry.mjs':'text/javascript', 'stream.mjs':'text/javascript', 'map.mjs':'text/javascript', 'nameplates.mjs':'text/javascript','dock-editor.mjs':'text/javascript' };
      if (request.method === 'GET' && Object.hasOwn(assets,file)) {
        const content = await readFile(join(webRoot,file));response.writeHead(200,{'Content-Type':`${assets[file]}; charset=utf-8`});response.end(content);return;
      }
      json(response,404,{ error:'地址不存在' });
    } catch (error) {
      if (response.headersSent) { response.destroy();return; }
      json(response,error.status ?? 500,{ error:error.status ? error.message : '本地服务处理失败，请检查配置文件和服务日志' });
      if (!error.status) console.error('Director operation failed:',error.code ?? error.name);
    }
  }
  await new Promise((resolve,reject) => { server.once('error',reject);server.listen(port,'127.0.0.1',resolve); });
  return { server, authority, origin, close: async () => {
    closed = true;clearInterval(keepalive);clearTimeout(notify);await authority.logout();
    for (const client of clients) client.response.end();clients.clear();
    await new Promise(resolve => { server.close(resolve);server.closeAllConnections(); });
  } };
}

if (process.argv[1] && import.meta.url === pathToFileURL(resolve(process.argv[1])).href) {
  const options = {};
  for (let i=2;i<process.argv.length;i+=2) {
    const key = { '--port':'port', '--data-dir':'directory', '--upstream':'upstream' }[process.argv[i]];
    if (!key || !process.argv[i+1]) throw new Error('参数：--port 9170 --data-dir runtime/director --upstream http://127.0.0.1:9080');
    options[key] = key === 'port' ? Number(process.argv[i+1]) : process.argv[i+1];
  }
  const app = await createDirector(options);console.log(`DCS 导播服务 0.8.0 · ${app.origin}`);
  for (const signal of ['SIGINT','SIGTERM']) process.once(signal,async () => { await app.close();process.exit(0); });
}
