import assert from 'node:assert/strict';
import { createHash } from 'node:crypto';
import { mkdtemp, rm, writeFile } from 'node:fs/promises';
import { tmpdir } from 'node:os';
import { join } from 'node:path';
import { once } from 'node:events';
import { get } from 'node:http';
import { DatabaseSync } from 'node:sqlite';
import test from 'node:test';
import { createGateway } from './server.mjs';

const adminToken = 'test-admin-token-9aef275bac';
const clientToken = 'test-client-token-36d1f9fac';
const apiKey = 'openrouter-test-key-not-real';
const groqKey = 'groq-test-key-not-real';
const ollamaKey = 'ollama-test-key-not-real';
const body = { messages: [{ role: 'user', content: 'Test input' }] };
const textReply = content => Response.json({ choices: [{ message: { content } }], usage: { cost: 0.00023 } });

test('sends a complete long selection once per attempt and rejects truncated replies', async t => {
  const selected = Array.from({ length: 20 }, (_, page) =>
    `## Page ${page + 1}\n` + 'Tekst przykładowy z zachowanymi szczegółami, liczbami i adresami. '.repeat(33)
  ).join('\n\n');
  const gateway = await fixture(t, input => input.max_tokens <= 4_096 ? textReply('Short result') :
    Response.json({ choices: [{
      message: { content: input.provider.only[0] === 'groq' ? 'Partial' : selected },
      finish_reason: input.provider.only[0] === 'groq' ? 'length' : 'stop',
    }] }));
  const json = { max_tokens: 28_000, messages: [{ role: 'user', content: selected }] };
  assert.equal((await gateway.text(json)).status, 400);
  const expanded = await gateway.request('/v1/chat/completions', { method: 'POST', token: clientToken, json,
    headers: { 'x-tacet-operation': 'selection-edit' } });
  assert.equal(expanded.status, 200);
  assert.equal((await expanded.json()).choices[0].message.content, selected);
  assert.deepEqual(gateway.calls.map(({ input }) => input.messages[0].content), [selected, selected]);
  assert.deepEqual(gateway.calls[0].input.reasoning, { effort: 'low', exclude: true });
  const oversized = await gateway.request('/v1/chat/completions', { method: 'POST', token: clientToken,
    json: { ...json, messages: [{ role: 'user', content: 'x'.repeat(110_000) }] },
    headers: { 'x-tacet-operation': 'selection-edit' } });
  assert.equal(oversized.status, 413);
  assert.equal(gateway.calls.length, 2);
  assert.equal((await gateway.text()).status, 200);
  assert.equal(gateway.calls[2].input.provider.only[0], 'groq');
});

test('reserves capacity for ordinary text while two expanded edits are active', async t => {
  let release, bothActive;
  let active = 0;
  const held = new Promise(resolve => { release = resolve; });
  const ready = new Promise(resolve => { bothActive = resolve; });
  const gateway = await fixture(t, async input => {
    if (input.max_tokens <= 4_096) return textReply('Regular');
    if (++active === 2) bothActive();
    await held;
    return Response.json({ choices: [{ message: { content: 'Edited' }, finish_reason: 'stop' }] });
  });
  const send = () => gateway.request('/v1/chat/completions', { method: 'POST', token: clientToken,
    json: { ...body, max_tokens: 16_000 }, headers: { 'x-tacet-operation': 'selection-edit' } });
  const waiting = [send(), send()];
  try {
    await ready;
    assert.equal((await send()).status, 429);
    assert.equal((await gateway.text()).status, 200);
  } finally {
    release();
    await Promise.all(waiting);
  }
});

test('a reply stopped by the per-request output limit leaves route health ready', async t => {
  let nextReply;
  const gateway = await fixture(t, () => nextReply ?? textReply('Complete'));
  assert.equal((await gateway.text()).status, 200);
  nextReply = Response.json({ choices: [{ message: { content: 'Partial' }, finish_reason: 'length' }] });
  assert.equal((await (await gateway.text()).json()).error.code, 'output_limit');
  nextReply = undefined;
  assert.equal((await gateway.text()).status, 200);
  assert.deepEqual(gateway.calls.map(({ input }) => input.provider.only[0]), ['groq', 'groq', 'groq']);
  assert.equal((await gateway.admin()).health['text-groq'].state, 'ready');
});

async function fixture(t, handle, parameters = {}, saved) {
  const root = await mkdtemp(join(tmpdir(), 'tacet-gateway-'));
  t.after(() => rm(root, { recursive: true, force: true }));
  const calls = [];
  const configPath = join(root, 'routes.json');
  if (saved) await writeFile(configPath, JSON.stringify(saved));
  const hostKeys = {
    'openrouter.ai': parameters.apiKey ?? apiKey,
    'api.groq.com': parameters.groqKey,
    'ollama.com': parameters.ollamaKey,
  };
  const settings = {
    configPath, adminToken, clientToken, apiKey,
    fetchUpstream: async (url, options) => {
      assert.equal(options.headers.authorization, `Bearer ${hostKeys[new URL(url).hostname]}`);
      assert.equal(options.redirect, 'error');
      const input = options.body instanceof FormData ? options.body : JSON.parse(options.body);
      calls.push({ url, input });
      return handle(input, options, url);
    }, ...parameters,
  };
  async function start(overrides = {}) {
    const server = createGateway({ ...settings, ...overrides });
    server.listen(0, '127.0.0.1');
    await once(server, 'listening');
    t.after(() => server.close());
    const base = `http://127.0.0.1:${server.address().port}`;
    const request = (path, { method = 'GET', token, json, form, headers } = {}) => fetch(`${base}${path}`, {
      method,
      headers: { ...headers, ...(token && { authorization: `Bearer ${token}` }), ...(json && { 'content-type': 'application/json' }) },
      body: form ?? (json && JSON.stringify(json)),
    });
    return {
      request, calls, start, base, stop: () => new Promise(resolve => server.close(resolve)),
      text: (json = body) => request('/v1/chat/completions', { method: 'POST', token: clientToken, json }),
      admin: () => request('/admin/api/routes', { token: adminToken }).then(res => res.json()),
      save: json => request('/admin/api/routes', { method: 'PUT', token: adminToken, json }),
    };
  }
  return start();
}

async function chooseRoutes(gateway, kind, enabled) {
  const snapshot = await gateway.admin();
  const available = new Map(snapshot.routes[kind].map(route => [route.id, route]));
  const ordered = enabled.map(id => {
    const route = available.get(id);
    available.delete(id);
    return { ...route, enabled: true };
  });
  snapshot.routes[kind] = [...ordered, ...[...available.values()].map(route => ({ ...route, enabled: false }))];
  assert.equal((await gateway.save(snapshot)).status, 200);
}

test('lists configured client operations without calling upstream', async t => {
  const gateway = await fixture(t, () => assert.fail('unexpected upstream request'));
  const models = token => gateway.request('/v1/models', { token });
  assert.equal((await models()).status, 401);
  assert.equal((await models(adminToken)).status, 401);
  const ids = async () => (await (await models(clientToken)).json()).data.map(({ id }) => id);
  assert.deepEqual(await ids(), ['tacet-text', 'tacet-transcription']);
  await chooseRoutes(gateway, 'audio', ['audio-groq-direct']);
  assert.deepEqual(await ids(), ['tacet-text']);
  await chooseRoutes(gateway, 'text', []);
  assert.deepEqual(await ids(), []);
  assert.equal(gateway.calls.length, 0);
});

test('attributes measured attempts to issued accounts and platforms across server restarts', async t => {
  const root = await mkdtemp(join(tmpdir(), 'tacet-usage-'));
  t.after(() => rm(root, { recursive: true, force: true }));
  const registryPath = join(root, 'clients.json');
  const usagePath = join(root, 'usage.sqlite');
  const mobile = 'test-mobile-key-7cc19377d1';
  const desktop = 'test-desktop-key-67eb9bb11b';
  const other = 'test-other-key-90bbea07ef';
  const entry = (token, account, platform) => ({
    account, platform, sha256: createHash('sha256').update(token).digest('hex'),
  });
  const mobileEntry = entry(mobile, 'pilot-1', 'ios');
  const desktopEntry = entry(desktop, 'pilot-1', 'macos');
  const otherEntry = entry(other, 'pilot-2', 'macos');
  await writeFile(registryPath, JSON.stringify([mobileEntry, desktopEntry, otherEntry]));
  const settings = { registryPath, usagePath, now: () => Date.UTC(2026, 10, 25, 23, 59) };
  const gateway = await fixture(t, (input, _options, url) => {
    if (url.endsWith('/audio/transcriptions')) return Response.json({ text: 'hello', usage: { seconds: 5.5, cost: 0.005 } });
    if (input.provider.only[0] === 'groq') {
      return Response.json({ choices: [], usage: { prompt_tokens: 10, completion_tokens: 8, cost: 0.001 } });
    }
    return Response.json({ choices: [{ message: { content: 'hello' } }], usage: { prompt_tokens: 11, completion_tokens: 3 } });
  }, settings);
  const textRequest = (app, token) => app.request('/v1/chat/completions', { method: 'POST', token,
    json: { ...body, account: 'forged', platform: 'ios' }, headers: { 'x-tacet-platform': 'ios' } });
  const audio = { input_audio: { data: Buffer.from('test').toString('base64'), format: 'wav' } };
  assert.equal((await gateway.request('/v1/models', { token: mobile })).status, 200);
  assert.equal((await gateway.request('/admin/api/routes', { token: mobile })).status, 401);
  assert.equal((await textRequest(gateway, adminToken)).status, 401);
  assert.equal((await gateway.request('/v1/audio/transcriptions', { method: 'POST', token: mobile, json: audio })).status, 200);
  assert.equal((await textRequest(gateway, desktop)).status, 200);
  assert.equal((await textRequest(gateway, other)).status, 200);
  assert.equal((await textRequest(gateway, clientToken)).status, 200);

  await gateway.stop();
  await writeFile(registryPath, JSON.stringify([mobileEntry, otherEntry]));
  const restarted = await gateway.start({ clientToken: undefined });
  assert.equal((await restarted.request('/v1/models', { token: desktop })).status, 401);
  assert.equal((await restarted.request('/v1/models', { token: clientToken })).status, 401);
  assert.equal((await restarted.request('/v1/audio/transcriptions', { method: 'POST', token: mobile, json: audio })).status, 200);

  const db = new DatabaseSync(usagePath, { readOnly: true });
  try {
    const rows = db.prepare('SELECT * FROM usage_daily').all();
    const row = (account, platform, route) => rows.find(r => r.account === account && r.platform === platform && r.route === route);
    const audioRow = rows.find(r => r.platform === 'ios');
    assert.deepEqual([audioRow.day, audioRow.account, audioRow.operation, audioRow.model, audioRow.attempts, audioRow.completed,
      audioRow.audio_seconds, audioRow.audio_seconds_samples, audioRow.reported_cost_usd],
    ['2026-11-25', 'pilot-1', 'audio', 'openai/whisper-large-v3', 2, 2, 11, 2, 0.01]);
    const failed = row('pilot-1', 'macos', 'text-groq');
    assert.deepEqual([failed.attempts, failed.completed, failed.input_tokens, failed.output_tokens, failed.cost_samples], [1, 0, 10, 8, 1]);
    const fallback = row('pilot-1', 'macos', 'text-bedrock');
    assert.deepEqual([fallback.attempts, fallback.completed, fallback.input_tokens, fallback.output_tokens, fallback.cost_samples], [1, 1, 11, 3, 0]);
    assert.equal(row('pilot-2', 'macos', 'text-bedrock').completed, 1);
    assert.equal(row('', 'unknown', 'text-bedrock').completed, 1);
    assert.equal(rows.length, 5);
  } finally {
    db.close();
  }
});

test('enforces one durable quota and the chosen device counts across desktop and phone', async t => {
  const root = await mkdtemp(join(tmpdir(), 'tacet-pilot-'));
  t.after(() => rm(root, { recursive: true, force: true }));
  const registryPath = join(root, 'devices.json');
  const usagePath = join(root, 'usage.sqlite');
  const mac = 'pilot-mac-credential-000001';
  const phone = 'pilot-ios-credential-000002';
  const secondPhone = 'pilot-ios-credential-000003';
  const other = 'other-ios-credential-000004';
  await writeFile(registryPath, JSON.stringify([
    [mac, 'pilot', 'macos'], [phone, 'pilot', 'ios'], [secondPhone, 'pilot', 'ios'], [other, 'other', 'ios'],
  ].map(([token, account, platform]) => ({ account, platform, sha256: createHash('sha256').update(token).digest('hex') }))));
  let now = Date.UTC(2026, 10, 25);
  let fail = false;
  let gateway = await fixture(t, (_input, _options, url) => {
    if (fail) return new Response(null, { status: 400 });
    return url.endsWith('audio/transcriptions') ? Response.json({ text: 'Pilot greeting' }) :
      Response.json({ choices: [{ message: { content: 'Result' } }], usage: { prompt_tokens: 21, completion_tokens: 4 } });
  }, { registryPath, usagePath, pilotAccounts: ['pilot'], now: () => now, clientToken: undefined });
  const plan = (app, token) => app.request('/v1/account/plan', { token }).then(reply => reply.json());
  const set = (app, token, plan) => app.request('/v1/account/plan', { method: 'PUT', token, json: { plan } });
  function waveWithDuration(seconds, sampleRate = 16_000) {
    const audioBytes = seconds * sampleRate * 2;
    const wave = Buffer.alloc(44 + audioBytes);
    wave.write('RIFF'); wave.writeUInt32LE(wave.length - 8, 4); wave.write('WAVEfmt ', 8);
    wave.writeUInt32LE(16, 16); wave.writeUInt16LE(1, 20); wave.writeUInt16LE(1, 22);
    wave.writeUInt32LE(sampleRate, 24); wave.writeUInt32LE(sampleRate * 2, 28); wave.writeUInt16LE(2, 32);
    wave.writeUInt16LE(16, 34); wave.write('data', 36); wave.writeUInt32LE(audioBytes, 40);
    return wave;
  }
  const wave = waveWithDuration(1);
  const iphoneWave = waveWithDuration(0.5, 48_000);
  const audio = (app, token, data = wave) => app.request('/v1/audio/transcriptions', { method: 'POST', token,
    json: { input_audio: { data: data.toString('base64'), format: 'wav' } } });

  const initial = await plan(gateway, mac);
  assert.equal(initial.plan, 'free');
  assert.equal(initial.audioPeriod, 'day');
  assert.equal(initial.audioResetsAt, '2026-11-26T00:00:00.000Z');
  assert.equal(initial.resetsAt, '2026-12-01T00:00:00.000Z');
  const freeLimit = initial.limits;
  assert.equal(freeLimit.audioSeconds, 1800);
  assert.equal(freeLimit.textTokens, 75_000);
  assert.equal((await plan(gateway, secondPhone)).deviceAllowed, false);
  assert.equal((await set(gateway, other, 'unlimited')).status, 403);
  // One price table: everyone sees the same three plans; operator-only plans are never offered for sale.
  assert.deepEqual((await plan(gateway, other)).available.map(option => [option.id, option.priceCents, option.devices]),
    [['free', 0, 2], ['basic', 599, 5], ['pro', 999, 8]]);
  assert.deepEqual(initial.available.map(option => option.id), ['free', 'basic', 'pro', 'paused', 'unlimited']);
  assert.equal((await set(gateway, mac, 'constructor')).status, 400);
  assert.equal((await audio(gateway, secondPhone)).status, 403);
  assert.equal((await audio(gateway, phone, Buffer.from('not wav'))).status, 400);
  assert.equal(gateway.calls.length, 0);
  assert.equal((await audio(gateway, phone, iphoneWave)).status, 200);
  assert.equal((await plan(gateway, mac)).used.audioSeconds, 2);
  assert.equal((await plan(gateway, other)).used.audioSeconds, 0);
  assert.equal((await audio(gateway, mac, waveWithDuration(5))).status, 200);
  assert.equal((await plan(gateway, phone)).used.audioSeconds, 8);
  assert.equal((await audio(gateway, phone, waveWithDuration(12))).status, 200);
  assert.equal((await plan(gateway, mac)).used.audioSeconds, 21);

  await gateway.stop();
  const legacyDB = new DatabaseSync(usagePath);
  legacyDB.exec('DROP TABLE pilot_account_audio_daily');
  legacyDB.close();
  gateway = await gateway.start();
  assert.equal((await plan(gateway, mac)).used.audioSeconds, 21);

  fail = true;
  assert.equal((await audio(gateway, mac)).status, 400);
  assert.equal((await plan(gateway, phone)).used.audioSeconds, 21);
  fail = false;
  assert.equal((await set(gateway, phone, 'paused')).status, 200);
  assert.equal((await audio(gateway, mac)).status, 403);
  assert.equal((await set(gateway, mac, 'basic')).status, 200);
  assert.equal((await plan(gateway, secondPhone)).deviceAllowed, true);
  assert.equal((await gateway.request('/v1/chat/completions', { method: 'POST', token: secondPhone, json: body })).status, 200);
  assert.equal((await plan(gateway, mac)).used.textTokens, 25);
  const db = new DatabaseSync(usagePath);
  db.prepare("UPDATE pilot_account_quota SET audio = ? WHERE account = 'pilot'").run(freeLimit.audioSeconds - 2);
  db.prepare("UPDATE pilot_account_audio_daily SET audio = ? WHERE account = 'pilot'").run(freeLimit.audioSeconds - 2);
  db.close();
  await set(gateway, phone, 'free');
  const concurrent = await Promise.all([audio(gateway, phone), audio(gateway, mac)]);
  assert.deepEqual(concurrent.map(reply => reply.status).sort(), [200, 429]);
  assert.equal((await plan(gateway, mac)).used.audioSeconds, freeLimit.audioSeconds);
  assert.equal((await set(gateway, mac, 'unlimited')).status, 200);
  assert.equal((await audio(gateway, phone)).status, 200);
  await set(gateway, phone, 'free');
  await gateway.stop();
  const restarted = await gateway.start();
  assert.equal((await plan(restarted, mac)).used.audioSeconds, freeLimit.audioSeconds + 2);
  assert.equal((await audio(restarted, phone)).status, 429);
  now = Date.UTC(2026, 10, 26);
  assert.deepEqual((await plan(restarted, mac)).used, { audioSeconds: 0, textTokens: 25 });
  assert.equal((await audio(restarted, phone)).status, 200);
  await set(restarted, phone, 'basic');
  const paid = await plan(restarted, mac);
  assert.equal(paid.audioPeriod, 'month');
  assert.equal(paid.audioResetsAt, paid.resetsAt);
  assert.equal(paid.used.audioSeconds, freeLimit.audioSeconds + 4);
  await set(restarted, phone, 'free');
  assert.equal((await plan(restarted, mac)).used.audioSeconds, 2);
  now = Date.UTC(2026, 11, 1);
  assert.equal((await plan(restarted, mac)).used.audioSeconds, 0);
  assert.equal((await audio(restarted, phone)).status, 200);
});

test('keeps the admin and client credentials separate and serves the admin UI', async t => {
  const gateway = await fixture(t, () => assert.fail('unexpected upstream request'));
  assert.equal((await gateway.request('/healthz')).status, 200);
  assert.match(await (await gateway.request('/admin/')).text(), /Шлюз Tacet/);
  assert.equal((await gateway.request('/admin/app.js')).status, 200);
  assert.equal((await gateway.request('/admin/api/routes')).status, 401);
  assert.equal((await gateway.request('/admin/api/routes', { token: clientToken })).status, 401);
  assert.equal((await gateway.request('/v1/chat/completions', { method: 'POST', token: adminToken, json: body })).status, 401);
  const state = await gateway.admin();
  assert.equal(state.configured, true);
  assert.deepEqual(state.connections, { openrouter: true, groq: false, ollama: false });
  assert.ok(!JSON.stringify(state).includes(apiKey));
  assert.deepEqual(state.health, {});
});

test('accepts the short admin key only on the local admin, with live connections configured', async t => {
  const short = 'testkey8';
  assert.throws(() => createGateway({ adminToken: short, clientToken, apiKey }), /Invalid gateway credentials/);
  assert.throws(() => createGateway({ adminToken: short, clientToken, ollamaKey }), /Invalid gateway credentials/);
  const gateway = await fixture(t, () => assert.fail('unexpected upstream request'), {
    adminToken: short, groqKey, ollamaKey, localAdmin: true,
  });
  const result = await gateway.request('/admin/api/routes', { token: short });
  assert.equal(result.status, 200);
  assert.deepEqual((await result.json()).connections, { openrouter: true, groq: true, ollama: true });
  const proxied = await gateway.request('/admin/api/routes', { token: short, headers: { 'x-forwarded-proto': 'https' } });
  assert.equal(proxied.status, 403);
  const otherHost = await new Promise((resolve, reject) => {
    get(`${gateway.base}/admin/`, { headers: { Host: 'external.example' } }, response => {
      response.resume();
      resolve(response.statusCode);
    }).on('error', reject);
  });
  assert.equal(otherHost, 403);
  const client = await gateway.request('/v1/chat/completions', { method: 'POST', token: short, json: body });
  assert.equal(client.status, 401);
});

test('restores the browser session on reload and removes it on logout', async t => {
  const gateway = await fixture(t, () => assert.fail('unexpected upstream request'), { localAdmin: true });
  const login = key => gateway.request('/admin/api/session', {
    method: 'POST', json: { key }, headers: { 'x-tacet-admin': '1' },
  });
  const incorrect = await login('wrong');
  assert.equal(incorrect.status, 401);
  assert.equal(incorrect.headers.get('set-cookie'), null);
  const logged = await login(adminToken);
  assert.equal(logged.status, 200);
  const cookie = logged.headers.get('set-cookie');
  assert.match(cookie, /Path=\/admin\/; HttpOnly; SameSite=Strict/);
  assert.doesNotMatch(cookie, /Secure/);
  assert.ok(!cookie.includes(adminToken));
  const headers = { cookie: cookie.split(';')[0] };
  const newPage = await gateway.request('/admin/', { headers });
  assert.equal(newPage.status, 200);
  const resumed = await gateway.request('/admin/api/routes', { headers });
  assert.equal(resumed.status, 200);
  const state = await resumed.json();
  assert.equal((await gateway.request('/admin/api/routes', { method: 'PUT', json: state, headers })).status, 403);
  assert.equal((await gateway.request('/admin/api/routes', {
    method: 'PUT', json: state, headers: { ...headers, 'x-tacet-admin': '1' },
  })).status, 200);
  assert.equal((await gateway.request('/v1/chat/completions', { method: 'POST', json: body, headers })).status, 401);
  const logout = await gateway.request('/admin/api/session', {
    method: 'DELETE', headers: { ...headers, 'x-tacet-admin': '1' },
  });
  assert.match(logout.headers.get('set-cookie'), /Max-Age=0/);
  assert.equal((await gateway.request('/admin/api/routes', { headers })).status, 401);
});

test('issues Secure cookies for public mode and rejects expired browser sessions', async t => {
  let now = 1000;
  const gateway = await fixture(t, () => assert.fail('unexpected upstream request'), { now: () => now });
  const login = await gateway.request('/admin/api/session', {
    method: 'POST', json: { key: adminToken }, headers: { 'x-tacet-admin': '1' },
  });
  const cookie = login.headers.get('set-cookie');
  assert.match(cookie, /^__Secure-tacet_admin=.+; HttpOnly; SameSite=Strict; Secure$/);
  const headers = { cookie: cookie.split(';')[0] };
  assert.equal((await gateway.request('/admin/api/routes', { headers })).status, 200);
  now += 8 * 60 * 60 * 1_000;
  assert.equal((await gateway.request('/admin/api/routes', { headers })).status, 401);
});

test('tries Groq, Bedrock and Cerebras in order and tracks the reason and actual usage', async t => {
  const gateway = await fixture(t, input => {
    const provider = input.provider.only[0];
    if (provider === 'groq') return new Response('', { status: 429, headers: { 'retry-after': '60' } });
    if (provider === 'amazon-bedrock') return new Response('', { status: 503 });
    return textReply('Returned by Cerebras');
  });
  const response = await gateway.text({ ...body, model: 'other', provider: { only: ['untrusted'] }, max_tokens: 800 });
  assert.equal(response.status, 200);
  assert.equal((await response.json()).choices[0].message.content, 'Returned by Cerebras');
  assert.deepEqual(gateway.calls.map(({ input }) => input.provider.only[0]), ['groq', 'amazon-bedrock', 'cerebras']);
  for (const { url, input } of gateway.calls) {
    assert.equal(url, 'https://openrouter.ai/api/v1/chat/completions');
    assert.equal(input.model, 'openai/gpt-oss-120b');
    assert.equal(input.max_tokens, 800);
    assert.equal(input.provider.allow_fallbacks, false);
    assert.equal(input.stream, false);
  }
  const { health } = await gateway.admin();
  assert.equal(health['text-groq'].reason, 'upstream_429');
  assert.equal(health['text-bedrock'].reason, 'upstream_503');
  assert.equal(health['text-cerebras'].state, 'ready');
  assert.equal(health['text-cerebras'].cost, 0.00023);
  assert.ok(health['text-groq'].until - health['text-groq'].checkedAt >= 59_000);
});

test('applies a reordered, multiply disabled configuration and reloads it after restart', async t => {
  const gateway = await fixture(t, () => textReply('Result'));
  const before = await gateway.admin();
  const update = { revision: before.revision, routes: before.routes };
  const [groq, bedrock, cerebras, ...newRoutes] = update.routes.text;
  update.routes.text = [cerebras, bedrock, groq, ...newRoutes];
  update.routes.text[0].enabled = false;
  update.routes.text[2].enabled = false;
  assert.equal((await gateway.save(update)).status, 200);
  assert.equal((await gateway.save(update)).status, 409);
  assert.equal((await gateway.text()).status, 200);
  const restarted = await gateway.start();
  assert.equal((await restarted.text()).status, 200);
  assert.deepEqual(gateway.calls.map(({ input }) => input.provider.only[0]), ['amazon-bedrock', 'amazon-bedrock']);
  assert.deepEqual((await restarted.admin()).routes.text.slice(0, 3).map(({ provider, enabled }) => [provider, enabled]), [
    ['cerebras', false], ['amazon-bedrock', true], ['groq', false],
  ]);
  const { revision, routes } = await restarted.admin();
  routes.text[1].enabled = false;
  assert.equal((await restarted.save({ revision, routes })).status, 200);
  assert.equal((await restarted.text()).status, 503);
  assert.equal(gateway.calls.length, 2);
});

test('migrates existing priorities and disabled routes while adding new connections as inactive', async t => {
  const gateway = await fixture(t, () => textReply('Result'), { groqKey, ollamaKey }, {
    revision: 3,
    routes: {
      text: ['text-bedrock', 'text-cerebras', 'text-groq'].map((id, index) => ({ id, enabled: index === 0 })),
      audio: ['audio-turbo', 'audio-whisper'].map(id => ({ id, enabled: true })),
    },
  });
  const snapshot = await gateway.admin();
  assert.equal(snapshot.revision, 4);
  assert.deepEqual(snapshot.connections, { openrouter: true, groq: true, ollama: true });
  assert.deepEqual(snapshot.routes.text.map(({ id, enabled }) => [id, enabled]), [
    ['text-bedrock', true], ['text-cerebras', false], ['text-groq', false],
    ['text-groq-direct', false], ['text-ollama-cloud', false],
  ]);
  assert.deepEqual(snapshot.routes.audio.map(({ id, enabled }) => [id, enabled]), [
    ['audio-turbo', true], ['audio-whisper', true],
    ['audio-whisper-together', false], ['audio-groq-direct', false],
  ]);
  assert.ok(![apiKey, groqKey, ollamaKey].some(key => JSON.stringify(snapshot).includes(key)));
});

test('can put direct Groq first and fail over from a shared OpenRouter error to Ollama Cloud', async t => {
  const gateway = await fixture(t, (_input, _options, url) => {
    const host = new URL(url).hostname;
    if (host === 'api.groq.com') return new Response('', { status: 429 });
    if (host === 'openrouter.ai') return new Response('', { status: 402 });
    return textReply('Ollama result');
  }, { groqKey, ollamaKey });
  await chooseRoutes(gateway, 'text', ['text-groq-direct', 'text-groq', 'text-bedrock', 'text-ollama-cloud']);
  const response = await gateway.text({ ...body, model: 'other', provider: { only: ['untrusted'] }, max_tokens: 800 });
  assert.equal(response.status, 200);
  assert.equal((await response.json()).choices[0].message.content, 'Ollama result');
  assert.deepEqual(gateway.calls.map(({ url }) => url), [
    'https://api.groq.com/openai/v1/chat/completions',
    'https://openrouter.ai/api/v1/chat/completions',
    'https://ollama.com/v1/chat/completions',
  ]);
  assert.equal(gateway.calls[0].input.model, 'openai/gpt-oss-120b');
  assert.equal(gateway.calls[0].input.max_completion_tokens, 800);
  assert.ok(!('max_tokens' in gateway.calls[0].input));
  assert.ok(!('provider' in gateway.calls[0].input));
  assert.equal(gateway.calls[2].input.model, 'gpt-oss:120b');
  assert.equal(gateway.calls[2].input.max_tokens, 800);
  assert.ok(!('provider' in gateway.calls[2].input));
  const { health } = await gateway.admin();
  assert.equal(health['text-groq-direct'].reason, 'upstream_429');
  assert.equal(health['text-groq'].reason, 'upstream_402');
  assert.equal(health['text-ollama-cloud'].state, 'ready');
});

test('sends multipart audio to direct Groq and forwards unsupported AAC to OpenRouter', async t => {
  const gateway = await fixture(t, () => Response.json({ text: 'Test' }), { groqKey });
  await chooseRoutes(gateway, 'audio', ['audio-groq-direct', 'audio-whisper']);
  const send = format => gateway.request('/v1/audio/transcriptions', { method: 'POST', token: clientToken,
    json: { input_audio: { data: 'YQ==', format }, language: 'uk', response_format: 'verbose_json' },
  });
  assert.equal((await send('wav')).status, 200);
  assert.equal((await send('aac')).status, 200);
  assert.deepEqual(gateway.calls.map(({ url }) => url), [
    'https://api.groq.com/openai/v1/audio/transcriptions', 'https://openrouter.ai/api/v1/audio/transcriptions',
  ]);
  const form = gateway.calls[0].input;
  assert.equal(form.get('model'), 'whisper-large-v3');
  assert.equal(form.get('file').name, 'audio.wav');
  assert.equal(await form.get('file').text(), 'a');
  assert.equal(form.get('language'), 'uk');
  assert.equal(form.get('response_format'), 'verbose_json');
  assert.equal(gateway.calls[1].input.input_audio.format, 'aac');
});

test('can use Ollama with no OpenRouter key and skip enabled routes without a configured key', async t => {
  const gateway = await fixture(t, () => textReply('Ollama'), { apiKey: undefined, ollamaKey });
  await chooseRoutes(gateway, 'text', ['text-groq', 'text-groq-direct', 'text-ollama-cloud']);
  assert.equal((await gateway.text()).status, 200);
  assert.equal(gateway.calls.length, 1);
  assert.equal(gateway.calls[0].url, 'https://ollama.com/v1/chat/completions');
});

test('permits a new attempt after cooldown and returns to the primary', async t => {
  let now = 10_000;
  let groqAttempts = 0;
  const gateway = await fixture(t, input => {
    if (input.provider.only[0] === 'groq' && ++groqAttempts === 1) return new Response('', { status: 503 });
    return textReply(input.provider.only[0]);
  }, { now: () => now, cooldown: 300 });
  const first = await (await gateway.text()).json();
  assert.equal(first.choices[0].message.content, 'amazon-bedrock');
  assert.equal((await gateway.admin()).health['text-groq'].state, 'cooldown');
  await gateway.text();
  now += 301;
  assert.equal((await gateway.admin()).health['text-groq'].state, 'waiting');
  const recovered = await (await gateway.text()).json();
  assert.equal(recovered.choices[0].message.content, 'groq');
  assert.equal((await gateway.admin()).health['text-groq'].state, 'ready');
  assert.deepEqual(gateway.calls.map(({ input }) => input.provider.only[0]), ['groq', 'amazon-bedrock', 'amazon-bedrock', 'groq']);
});

test('sends Groq then Together routing fields for Whisper Large V3 multipart uploads', async t => {
  const gateway = await fixture(t, input => input.provider.only[0] === 'together'
    ? Response.json({ text: 'Приклад', language: 'uk', usage: { cost: 0.001 } })
    : new Response('', { status: 503 }));
  const form = new FormData();
  form.set('file', new Blob(['mock-audio']), 'sample.wav');
  form.set('language', 'UK');
  form.set('response_format', 'verbose_json');
  const response = await gateway.request('/v1/audio/transcriptions', { method: 'POST', token: clientToken, form });
  assert.equal(response.status, 200);
  assert.equal((await response.json()).text, 'Приклад');
  assert.deepEqual(gateway.calls.map(({ input }) => input.model), ['openai/whisper-large-v3', 'openai/whisper-large-v3']);
  assert.deepEqual(gateway.calls.map(({ input }) => input.provider), [
    { only: ['groq'], allow_fallbacks: false },
    { only: ['together'], allow_fallbacks: false },
  ]);
  for (const { input, url } of gateway.calls) {
    assert.equal(url, 'https://openrouter.ai/api/v1/audio/transcriptions');
    assert.deepEqual(input.input_audio, { data: Buffer.from('mock-audio').toString('base64'), format: 'wav' });
    assert.equal(input.language, 'uk');
    assert.equal(input.response_format, 'verbose_json');
  }
  const { health } = await gateway.admin();
  assert.equal(health['audio-whisper'].reason, 'upstream_503');
  assert.equal(health['audio-whisper-together'].successes, 1);
});

test('accepts valid JSON audio and rejects ambiguous encodings before contacting OpenRouter', async t => {
  const gateway = await fixture(t, () => Response.json({ text: 'Test' }));
  const send = data => gateway.request('/v1/audio/transcriptions', { method: 'POST', token: clientToken,
    json: { input_audio: { data, format: 'wav' }, model: 'other', provider: { only: ['untrusted'] } } });
  assert.equal((await send('YQ==')).status, 200);
  assert.equal((await send('YR==')).status, 400);
  assert.equal(gateway.calls.length, 1);
  assert.equal(gateway.calls[0].input.model, 'openai/whisper-large-v3');
  assert.deepEqual(gateway.calls[0].input.provider, { only: ['groq'], allow_fallbacks: false });
});

test('ignores forged route metadata and refuses a duplicate route without changing the active policy', async t => {
  const gateway = await fixture(t, () => textReply('Complete'));
  const baseline = await gateway.admin();
  const update = structuredClone(baseline);
  update.routes.text[1] = update.routes.text[0];
  assert.equal((await gateway.save(update)).status, 400);
  assert.deepEqual(await gateway.admin(), baseline);
  const changed = structuredClone(baseline);
  changed.routes.text[0].provider = 'untrusted';
  changed.routes.text[0].model = 'untrusted';
  assert.equal((await gateway.save(changed)).status, 200);
  assert.equal((await gateway.text()).status, 200);
  assert.deepEqual(gateway.calls[0].input.provider.only, ['groq']);
  assert.equal(gateway.calls[0].input.model, 'openai/gpt-oss-120b');
});

test('does not run additional providers when the shared OpenRouter balance is exhausted', async t => {
  const gateway = await fixture(t, () => new Response(`Private detail ${apiKey}`, { status: 402 }));
  const response = await gateway.text();
  assert.equal(response.status, 503);
  const json = await response.json();
  assert.equal(json.error.code, 'upstream_402');
  assert.ok(!JSON.stringify(json).includes(apiKey));
  assert.equal(gateway.calls.length, 1);
});

test('an in-flight success does not clear a newer provider retry delay', async t => {
  let now = 10_000;
  const started = [Promise.withResolvers(), Promise.withResolvers()];
  const replies = [Promise.withResolvers(), Promise.withResolvers()];
  let primaryCalls = 0;
  const gateway = await fixture(t, input => {
    if (input.provider.only[0] !== 'groq') return textReply('Fallback');
    const index = primaryCalls++;
    if (index >= replies.length) return textReply('Primary probe');
    started[index].resolve();
    return replies[index].promise;
  }, { now: () => now });
  const first = gateway.text();
  await started[0].promise;
  const second = gateway.text();
  await started[1].promise;
  try {
    replies[0].resolve(new Response('', { status: 429, headers: { 'Retry-After': '60' } }));
    assert.equal((await (await first).json()).choices[0].message.content, 'Fallback');
    replies[1].resolve(textReply('In-flight primary'));
    assert.equal((await second).status, 200);
    now += 59_000;
    const state = (await gateway.admin()).health['text-groq'];
    assert.equal(state.successes, 1);
    assert.equal(state.state, 'cooldown');
    assert.equal(state.until, 70_000);
    assert.equal((await (await gateway.text()).json()).choices[0].message.content, 'Fallback');
    assert.equal(primaryCalls, 2);
    now += 1_000;
    assert.equal((await (await gateway.text()).json()).choices[0].message.content, 'Primary probe');
  } finally {
    for (const reply of replies) reply.resolve(textReply('Released fixture'));
  }
});

test('shares balance backoff between audio and text on the same credential', async t => {
  let now = 10_000;
  let funded = false;
  const gateway = await fixture(t, (_input, _options, url) => {
    if (!funded) return new Response('', { status: 402 });
    return url.endsWith('/audio/transcriptions') ? Response.json({ text: 'Audio result' }) : textReply('Text result');
  }, { now: () => now });
  const audio = () => gateway.request('/v1/audio/transcriptions', {
    method: 'POST', token: clientToken, json: { input_audio: { data: 'YQ==', format: 'wav' } },
  });
  assert.equal((await gateway.text()).status, 503);
  const skipped = await audio();
  assert.equal(skipped.status, 503);
  assert.equal(skipped.headers.get('retry-after'), '30');
  assert.equal((await skipped.json()).error.code, 'upstream_402');
  assert.equal(gateway.calls.length, 1);
  funded = true;
  now += 30_000;
  assert.equal((await audio()).status, 200);
  assert.equal((await gateway.text()).status, 200);
  assert.equal(gateway.calls.length, 3);
});

test('does not share a provider 403 across clients', async t => {
  let attempts = 0;
  const gateway = await fixture(t, () => ++attempts === 1
    ? new Response('', { status: 403 }) : textReply('Other request'));
  assert.equal((await gateway.text()).status, 503);
  assert.equal((await gateway.text()).status, 200);
  assert.equal(attempts, 2);
});

test('rejects oversized upstream JSON and falls back', async t => {
  const oversized = 'x'.repeat(2 * 1024 * 1024);
  const gateway = await fixture(t, input => input.provider.only[0] === 'groq'
    ? textReply(oversized) : textReply('Bounded fallback'));
  const result = await gateway.text();
  assert.equal(result.status, 200);
  assert.ok((await result.json()).choices[0].message.content === 'Bounded fallback',
    'Expected fallback after the oversized response');
  assert.equal((await gateway.admin()).health['text-groq'].reason, 'reply_too_large');
});

test('falls back on a timed-out or incomplete response and rejects malformed input locally', async t => {
  const gateway = await fixture(t, (input, { signal }) => {
    const provider = input.provider.only[0];
    if (provider === 'groq') return new Promise((_, reject) => {
      signal.addEventListener('abort', () => reject(signal.reason), { once: true });
    });
    if (provider === 'amazon-bedrock') return textReply(' ');
    return textReply('Complete');
  }, { timeouts: { text: 20, audio: 20 } });
  assert.equal((await gateway.text({ messages: 'bad' })).status, 400);
  assert.equal(gateway.calls.length, 0);
  assert.equal((await gateway.text()).status, 200);
  const { health } = await gateway.admin();
  assert.equal(health['text-groq'].reason, 'timeout');
  assert.equal(health['text-bedrock'].reason, 'invalid_reply');
});

test('bounds in-flight requests and returns retry guidance under load', async t => {
  let release;
  let entered;
  const started = new Promise(resolve => { entered = resolve; });
  const hold = new Promise(resolve => { release = resolve; });
  const gateway = await fixture(t, async () => {
    entered();
    await hold;
    return textReply('Complete');
  }, { maxInFlight: 1 });
  const first = gateway.text();
  await started;
  try {
    const concurrent = await gateway.text();
    assert.equal(concurrent.status, 429);
    assert.equal(concurrent.headers.get('retry-after'), '1');
    assert.equal(gateway.calls.length, 1);
  } finally {
    release();
  }
  assert.equal((await first).status, 200);
});

test('accounts for audio bytes independently of text capacity and releases the reservation', async t => {
  const entered = Promise.withResolvers();
  const hold = Promise.withResolvers();
  const audio = { input_audio: { data: 'YQ==', format: 'wav' } };
  let audioCalls = 0;
  const gateway = await fixture(t, async (_input, _options, url) => {
    if (url.endsWith('/chat/completions')) return textReply('Text remains available');
    if (++audioCalls === 1) {
      entered.resolve();
      await hold.promise;
    }
    return Response.json({ text: 'Audio result' });
  }, { maxAudioBytesInFlight: Buffer.byteLength(JSON.stringify(audio)) });
  const sendAudio = () => gateway.request('/v1/audio/transcriptions', { method: 'POST', token: clientToken, json: audio });
  const first = sendAudio();
  await entered.promise;
  try {
    const excess = await sendAudio();
    assert.equal(excess.status, 429);
    assert.equal(excess.headers.get('retry-after'), '1');
    assert.equal((await gateway.text()).status, 200);
    assert.equal(audioCalls, 1);
  } finally {
    hold.resolve();
  }
  assert.equal((await first).status, 200);
  assert.equal((await sendAudio()).status, 200);
});

test('a cancelled client releases its slot and aborts the upstream request', async t => {
  const entered = Promise.withResolvers();
  const aborted = Promise.withResolvers();
  let calls = 0;
  const gateway = await fixture(t, (_input, { signal }) => {
    if (++calls > 1) return textReply('Next request');
    entered.resolve();
    return new Promise((_, reject) => signal.addEventListener('abort', () => {
      aborted.resolve();
      reject(signal.reason);
    }, { once: true }));
  }, { maxInFlight: 1 });
  const controller = new AbortController();
  const result = fetch(gateway.base + '/v1/chat/completions', {
    method: 'POST', headers: { Authorization: 'Bearer ' + clientToken, 'content-type': 'application/json' },
    body: JSON.stringify(body), signal: controller.signal,
  });
  await entered.promise;
  controller.abort();
  await assert.rejects(result, { name: 'AbortError' });
  await aborted.promise;
  assert.deepEqual((await gateway.admin()).health, {});
  assert.equal((await gateway.text()).status, 200);
});
