import assert from 'node:assert/strict';
import { randomUUID } from 'node:crypto';
import { once } from 'node:events';
import { mkdtemp, rm } from 'node:fs/promises';
import { tmpdir } from 'node:os';
import { join } from 'node:path';
import { DatabaseSync } from 'node:sqlite';
import test from 'node:test';
import { createGateway } from './server.mjs';

async function fixture(t, extra = {}) {
  const root = await mkdtemp(join(tmpdir(), 'tacet-login-'));
  const usagePath = join(root, 'usage.sqlite');
  const outbox = [];
  let time = Date.UTC(2026, 10, 25);
  const options = {
    configPath: join(root, 'routes.json'), usagePath, adminToken: 'test-administrator-key-only',
    apiKey: 'substitute-only', now: () => time,
    fetchUpstream: async () => Response.json({ choices: [{ message: { content: 'Вітаю!' }, finish_reason: 'stop' }],
      usage: { prompt_tokens: 10, completion_tokens: 5 } }),
    emailLogin: {
      secret: 'fixture only - at least thirty-two characters',
      sendCode: async message => { outbox.push(message); }, ...extra,
    },
  };
  let server;
  let base;
  async function restart() {
    if (server) await new Promise(resolve => server.close(resolve));
    server = createGateway(options);
    server.listen(0, '127.0.0.1');
    await once(server, 'listening');
    base = `http://127.0.0.1:${server.address().port}/v1`;
  }
  t.after(async () => {
    if (server) await new Promise(resolve => server.close(resolve));
    await rm(root, { recursive: true, force: true });
  });
  await restart();

  async function request(path, { method, token, data } = {}) {
    const response = await fetch(`${base}${path}`, {
      method: method ?? (data ? 'POST' : 'GET'),
      headers: { ...(token && { authorization: `Bearer ${token}` }), ...(data && { 'content-type': 'application/json' }) },
      body: data && JSON.stringify(data),
    });
    return { status: response.status, body: await response.json() };
  }

  async function challenge(email) {
    const response = await request('/auth/code', { data: { email } });
    assert.equal(response.status, 200);
    return { challengeID: response.body.challengeID, code: outbox.at(-1)?.code };
  }

  const advance = ms => { time += ms; };
  const device = (deviceName = 'Laptop', platform = 'macos') => ({ deviceID: randomUUID(), deviceName, platform });
  async function connect(email, target) {
    advance(61_000);
    return request('/auth/verify', { data: { ...await challenge(email), ...target } });
  }

  return { outbox, usagePath, restart, request, challenge, advance, device, connect };
}

test('email login joins platforms, shares quota, rejects reuse and restores sessions after a restart', async t => {
  const f = await fixture(t);
  assert.deepEqual(await f.request('/auth/status'), { status: 200, body: { enabled: true } });
  assert.equal((await f.request('/models')).status, 401);
  const mac = f.device();
  const form = { ...await f.challenge(' First@Example.test '), ...mac };
  assert.equal(f.outbox[0].email, 'first@example.test');
  const simultaneous = await Promise.all([f.request('/auth/verify', { data: form }), f.request('/auth/verify', { data: form })]);
  assert.deepEqual(simultaneous.map(result => result.status).sort(), [200, 401]);
  const macToken = simultaneous.find(result => result.status === 200).body.token;
  const phone = f.device('Phone', 'ios');
  const phoneToken = (await f.connect('first@example.test', phone)).body.token;
  await f.restart();
  assert.equal((await f.request('/models', { token: macToken })).status, 200);
  const before = await f.request('/account/plan', { token: phoneToken });
  assert.deepEqual(before.body.limits, { priceCents: 0, audioSeconds: 1800, textTokens: 75_000, devices: 2 });
  assert.equal(before.body.canSwitch, false);
  assert.equal((await f.request('/account/plan', { method: 'PUT', token: phoneToken, data: { plan: 'pro' } })).status, 403);
  assert.equal((await f.request('/chat/completions', { token: macToken,
    data: { max_tokens: 550, messages: [{ role: 'user', content: 'Hello' }] } })).status, 200);
  assert.equal((await f.request('/account/plan', { token: phoneToken })).body.used.textTokens, 15);
});

test('a full account can replace an explicitly named device and revoke tokens without crossing accounts', async t => {
  const f = await fixture(t);
  const old = f.device('Old Mac');
  const oldToken = (await f.connect('first@example.test', old)).body.token;
  const remainingDevice = f.device('Other Mac');
  const remainingToken = (await f.connect('first@example.test', remainingDevice)).body.token;
  const unrelated = f.device();
  const unrelatedToken = (await f.connect('other@example.test', unrelated)).body.token;
  const pending = await f.connect('first@example.test', f.device('New phone', 'ios'));
  assert.equal(pending.status, 409);
  assert.deepEqual(pending.body.devices.map(entry => entry.name).sort(), ['Old Mac', 'Other Mac']);
  const ticket = pending.body.ticket;
  assert.equal((await f.request('/auth/device', { data: { ticket, replaceDeviceID: unrelated.deviceID } })).status, 404);
  const replacement = await f.request('/auth/device', { data: { ticket, replaceDeviceID: old.deviceID } });
  assert.equal(replacement.status, 200);
  assert.equal((await f.request('/auth/device', { data: { ticket, replaceDeviceID: old.deviceID } })).status, 401);
  assert.equal((await f.request('/models', { token: oldToken })).status, 401);
  assert.equal((await f.request('/models', { token: unrelatedToken })).status, 200);
  assert.deepEqual((await f.request('/account/devices', { token: replacement.body.token })).body.devices
    .map(device => [device.name, device.current]), [['New phone', true], ['Other Mac', false]]);
  assert.equal((await f.request(`/account/devices/${unrelated.deviceID}`, { method: 'DELETE', token: remainingToken })).status, 404);
  assert.equal((await f.request(`/account/devices/${remainingDevice.deviceID}`, { method: 'DELETE', token: remainingToken })).status, 200);
  assert.equal((await f.request('/models', { token: remainingToken })).status, 401);
  assert.equal((await f.request('/account/devices', { token: replacement.body.token })).body.devices.length, 1);
});

test('wrong codes spend attempts, sending is throttled, codes expire, and mail failure does not enable login', async t => {
  const f = await fixture(t);
  const email = 'first@example.test';
  const form = { ...await f.challenge(email), ...f.device() };
  assert.equal((await f.request('/auth/code', { data: { email } })).status, 429);
  const wrong = form.code === '000000' ? '000001' : '000000';
  for (let attempt = 0; attempt < 5; attempt++) {
    assert.equal((await f.request('/auth/verify', { data: { ...form, code: wrong } })).status, 401);
  }
  assert.equal((await f.request('/auth/verify', { data: form })).status, 401);
  f.advance(61_000);
  const next = { ...await f.challenge(email), ...f.device() };
  f.advance(10 * 60_000);
  assert.equal((await f.request('/auth/verify', { data: next })).status, 401);

  const failed = await fixture(t, { sendCode: async () => { throw Error('local mail fixture failure'); } });
  assert.deepEqual(await failed.request('/auth/code', { data: { email } }),
    { status: 503, body: { error: { code: 'login_unavailable', message: 'Could not send the sign-in code' } } });
});

test('replacement limits are type-independent and the same installation does not occupy another place', async t => {
  const f = await fixture(t);
  const email = 'first@example.test';
  const mac = f.device();
  const login = await f.connect(email, mac);
  const db = new DatabaseSync(f.usagePath);
  t.after(() => db.close());
  const account = db.prepare('SELECT id FROM login_accounts').get().id;
  const plan = db.prepare('INSERT INTO pilot_account_plan VALUES (?, ?) ON CONFLICT(account) DO UPDATE SET plan = excluded.plan');
  plan.run(account, 'basic');
  for (let i = 0; i < 4; i++) assert.equal((await f.connect(email, f.device())).status, 200);
  f.advance(60 * 60_000);
  assert.equal((await f.connect(email, f.device())).status, 409);
  const repeat = await f.connect(email, mac);
  assert.equal(repeat.status, 200);
  assert.equal((await f.request('/models', { token: login.body.token })).status, 401);
  assert.equal((await f.request('/account/devices', { token: repeat.body.token })).body.devices.length, 5);
  plan.run(account, 'pro');
  f.advance(60 * 60_000);
  for (let i = 0; i < 3; i++) assert.equal((await f.connect(email, f.device('iPhone', 'ios'))).status, 200);
  assert.equal((await f.connect(email, f.device())).status, 409);
  assert.equal((await f.request('/account/plan', { token: repeat.body.token })).body.limits.devices, 8);
});

test('a short selection can be edited within the remaining text allowance', async t => {
  const f = await fixture(t);
  const { body: { token } } = await f.connect('first@example.test', f.device());
  const db = new DatabaseSync(f.usagePath);
  const account = db.prepare('SELECT id FROM login_accounts').get().id;
  db.prepare('INSERT INTO pilot_account_quota VALUES (?, ?, ?, ?)').run(account, '2026-11', 0, 72_000);
  db.close();
  const messages = [{ role: 'system', content: 'Follow the translation instruction. '.repeat(25) },
    { role: 'user', content: 'SELECTED TEXT:\nHello!\n\nSPOKEN:\nTranslate to Ukrainian.' }];
  const send = max_tokens => f.request('/chat/completions', { token, data: { messages, max_tokens } });
  assert.equal((await send(4096)).body.error.code, 'plan_quota');
  assert.equal((await send(530)).body.choices[0].message.content, 'Вітаю!');
  assert.equal((await f.request('/account/plan', { token })).body.used.textTokens, 72_015);
});
