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

  return { outbox, usagePath, restart, request, challenge, advance, device, connect, time: () => time,
    get origin() { return base.slice(0, -3); } };
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
  // Only the App Review account is marked; an ordinary account is not.
  assert.equal(before.body.review, undefined);
  assert.deepEqual(before.body.limits, { priceCents: 0, audioSeconds: 6000, textTokens: 1_000_000, devices: 2 });
  assert.equal(before.body.canSwitch, false);
  assert.equal((await f.request('/account/plan', { method: 'PUT', token: phoneToken, data: { plan: 'pro' } })).status, 403);
  assert.equal((await f.request('/chat/completions', { token: macToken,
    data: { max_tokens: 550, messages: [{ role: 'user', content: 'Hello' }] } })).status, 200);
  assert.equal((await f.request('/account/plan', { token: phoneToken })).body.used.textTokens, 15);
});

test('an account owner can delete the account from the app, and a deleted account cannot be used or re-created for free minutes', async t => {
  const f = await fixture(t);
  const phone = f.device('Phone', 'ios');
  const token = (await f.connect('owner@example.test', phone)).body.token;
  const other = (await f.connect('keep@example.test', f.device('Laptop'))).body.token;
  assert.equal((await f.request('/account', { method: 'DELETE', data: { confirm: 'owner@example.test' } })).status, 401);
  assert.equal((await f.request('/account', { method: 'DELETE', token, data: {} })).body.error.code, 'confirmation_required');
  assert.equal((await f.request('/account', { method: 'DELETE', token, data: { confirm: 'wrong@example.test' } })).status, 400);
  assert.equal((await f.request('/models', { token })).status, 200);
  const deleted = await f.request('/account', { method: 'DELETE', token, data: { confirm: ' Owner@Example.test ' } });
  assert.deepEqual(deleted, { status: 200, body: { ok: true } });
  // The credential stops working at once; other accounts are untouched.
  assert.equal((await f.request('/models', { token })).status, 401);
  assert.equal((await f.request('/models', { token: other })).status, 200);
  const db = new DatabaseSync(f.usagePath, { readOnly: true });
  assert.equal(db.prepare("SELECT COUNT(*) AS count FROM login_accounts WHERE email = 'owner@example.test'").get().count, 0);
  assert.equal(db.prepare("SELECT COUNT(*) AS count FROM admin_actions WHERE action = 'account_deleted'").get().count, 1);
  db.close();
  // Signing in again starts a new account on the same device.
  assert.equal((await f.connect('owner@example.test', phone)).status, 200);
});

test('the App Review address signs in with a fixed code, sends no mail and cannot be used by anyone else', async t => {
  const f = await fixture(t, { reviewer: { email: 'AppReview@Example.test', code: '424242' } });
  const phone = f.device('Review iPhone', 'ios');
  f.advance(61_000);
  const started = await f.request('/auth/code', { data: { email: 'appreview@example.test' } });
  assert.equal(started.status, 200);
  assert.equal(f.outbox.length, 0);
  const wrong = await f.request('/auth/verify', { data: { challengeID: started.body.challengeID, code: '000000', ...phone } });
  assert.equal(wrong.status, 401);
  const ok = await f.request('/auth/verify', { data: { challengeID: started.body.challengeID, code: '424242', ...phone } });
  assert.equal(ok.status, 200);
  assert.equal((await f.request('/models', { token: ok.body.token })).status, 200);
  // The reviewer, and nobody else, is marked in the plan the apps read.
  const reviewerPlan = await f.request('/account/plan', { token: ok.body.token });
  assert.equal(reviewerPlan.status, 200);
  assert.equal(reviewerPlan.body.review, true);
  // Repeated requests are never rate limited for the reviewer, and the fixed code only works for that address.
  for (let i = 0; i < 7; i += 1) assert.equal((await f.request('/auth/code', { data: { email: 'appreview@example.test' } })).status, 200);
  const other = await f.request('/auth/code', { data: { email: 'someone@example.test' } });
  assert.equal(f.outbox.length, 1);
  const stolen = await f.request('/auth/verify', { data: { challengeID: other.body.challengeID, code: '424242', ...f.device() } });
  assert.equal(stolen.status, 401);
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
  for (let i = 0; i < 2; i++) assert.equal((await f.connect(email, f.device())).status, 200);
  f.advance(60 * 60_000);
  assert.equal((await f.connect(email, f.device())).status, 409);
  const repeat = await f.connect(email, mac);
  assert.equal(repeat.status, 200);
  assert.equal((await f.request('/models', { token: login.body.token })).status, 401);
  assert.equal((await f.request('/account/devices', { token: repeat.body.token })).body.devices.length, 3);
  plan.run(account, 'pro');
  f.advance(60 * 60_000);
  for (let i = 0; i < 5; i++) {
    // Stay under the hourly limit on sign-in codes per address.
    if (i === 3) f.advance(60 * 60_000);
    assert.equal((await f.connect(email, f.device('iPhone', 'ios'))).status, 200);
  }
  assert.equal((await f.connect(email, f.device())).status, 409);
  assert.equal((await f.request('/account/plan', { token: repeat.body.token })).body.limits.devices, 8);
});

test('a short selection can be edited within the remaining text allowance', async t => {
  const f = await fixture(t);
  const { body: { token } } = await f.connect('first@example.test', f.device());
  const db = new DatabaseSync(f.usagePath);
  const account = db.prepare('SELECT id FROM login_accounts').get().id;
  db.prepare("INSERT INTO free_allowance (scope, id, audio, text) VALUES ('account', ?, 0, 997000)").run(account);
  db.close();
  const messages = [{ role: 'system', content: 'Follow the translation instruction. '.repeat(25) },
    { role: 'user', content: 'SELECTED TEXT:\nHello!\n\nSPOKEN:\nTranslate to Ukrainian.' }];
  const send = max_tokens => f.request('/chat/completions', { token, data: { messages, max_tokens } });
  assert.equal((await send(4096)).body.error.code, 'plan_quota');
  assert.equal((await send(530)).body.choices[0].message.content, 'Вітаю!');
  assert.equal((await f.request('/account/plan', { token })).body.used.textTokens, 997_015);
  // A selection over the word limit is refused before any provider is called.
  const long = [{ role: 'user', content: `SELECTED TEXT:\n${'слово '.repeat(1001)}\n\nSPOKEN:\nкоротше` }];
  const refused = await f.request('/chat/completions', { token, data: { messages: long, max_tokens: 64 } });
  assert.deepEqual([refused.status, refused.body.error.code], [413, 'selection_too_long']);
  const cjk = [{ role: 'user', content: `SELECTED TEXT:\n${'字'.repeat(2002)}\n\nSPOKEN:\n翻译` }];
  assert.equal((await f.request('/chat/completions', { token, data: { messages: cjk, max_tokens: 64 } })).status, 413);
});

test('an earlier Mac user gets one month of Basic once per device, then returns to Free', async t => {
  const f = await fixture(t);
  const mac = { ...f.device('Old Mac'), transition: true };
  const first = await f.connect('veteran@example.test', mac);
  assert.equal(first.body.gift, true);
  const plan = async token => (await f.request('/account/plan', { token })).body;
  assert.deepEqual([(await plan(first.body.token)).plan, (await plan(first.body.token)).limits.audioSeconds], ['basic', 36000]);
  // The same device under another email, and a phone, get no second gift.
  assert.equal((await f.connect('other@example.test', mac)).body.gift, false);
  assert.equal((await f.connect('phone@example.test', { ...f.device('iPhone', 'ios'), transition: true })).body.gift, undefined);
  // A newcomer who does not report earlier use stays on Free.
  const fresh = await f.connect('new@example.test', f.device('New Mac'));
  assert.equal((await plan(fresh.body.token)).plan, 'free');
  f.advance(31 * 24 * 60 * 60_000);
  assert.equal((await plan(first.body.token)).plan, 'free');
});

test('the free allowance is one-time, follows the device to a new email and can be extended by the owner', async t => {
  const f = await fixture(t);
  const laptop = f.device();
  const first = (await f.connect('first@example.test', laptop)).body.token;
  const db = new DatabaseSync(f.usagePath);
  const account = db.prepare("SELECT id FROM login_accounts WHERE email = 'first@example.test'").get().id;
  // The account and the device have both used the whole allowance.
  for (const [scope, id] of [['account', account], ['device', laptop.deviceID.toLowerCase()]]) {
    db.prepare('INSERT INTO free_allowance (scope, id, audio, text) VALUES (?, ?, 6000, 0)').run(scope, id);
  }
  db.close();
  const plan = async token => (await f.request('/account/plan', { token })).body;
  assert.deepEqual([(await plan(first)).audioPeriod, (await plan(first)).used.audioSeconds], ['once', 6000]);

  // A new email on the same device starts with that device's used allowance, not a fresh one.
  const again = (await f.connect('second@example.test', laptop)).body.token;
  assert.equal((await plan(again)).used.audioSeconds, 6000);
  // The same new email on a device that never used the allowance does get it.
  const fresh = (await f.connect('second@example.test', f.device('Other Mac'))).body.token;
  assert.equal((await plan(fresh)).used.audioSeconds, 0);

  const admin = async (path, data) => {
    const response = await fetch(`${f.origin}/admin/api/users${path}`, { method: 'POST',
      headers: { authorization: 'Bearer test-administrator-key-only', 'content-type': 'application/json' }, body: JSON.stringify(data) });
    return { status: response.status, body: await response.json() };
  };
  assert.equal((await admin(`/${account}/allowance`, { minutes: 0, reason: 'x' })).status, 400);
  const granted = await admin(`/${account}/allowance`, { minutes: 30, reason: 'Support request' });
  assert.deepEqual([granted.status, granted.body.period, granted.body.limits.audioSeconds, granted.body.bonusAudioSeconds,
    granted.body.actions[0].action], [200, 'once', 7800, 1800, 'allowance']);
  assert.equal((await plan(first)).limits.audioSeconds, 7800);
});

test('the owner console lists users and applies plans, blocks, payments and removal', async t => {
  const app = await fixture(t);
  const first = (await app.connect('First@Example.com', app.device('Laptop', 'macos'))).body.token;
  const phone = app.device('Phone', 'ios');
  await app.connect('first@example.com', phone);
  const second = (await app.connect('second@example.com', app.device())).body.token;
  assert.equal((await app.request('/models', { token: first })).status, 200);
  assert.equal((await app.request('/models', { token: second })).status, 200);

  const admin = async (path, data) => {
    const response = await fetch(`${app.origin}/admin/api/users${path}`, {
      method: data ? 'POST' : 'GET',
      headers: { authorization: 'Bearer test-administrator-key-only', ...(data && { 'content-type': 'application/json' }) },
      body: data && JSON.stringify(data),
    });
    return { status: response.status, body: await response.json() };
  };
  assert.equal((await fetch(`${app.origin}/admin/api/users`)).status, 401);
  assert.equal((await app.request('/models', { token: first })).status, 200);

  const listed = (await admin('')).body;
  assert.equal(listed.total, 2);
  assert.deepEqual(listed.users.map(user => [user.email, user.plan, user.devices, user.blocked]).sort(),
    [['first@example.com', 'free', 2, null], ['second@example.com', 'free', 1, null]]);
  assert.equal((await admin('?query=SECOND')).body.total, 1);
  assert.equal((await admin('?query=%25')).body.total, 0);
  const account = listed.users.find(user => user.email === 'first@example.com').account;
  assert.ok(listed.users.every(user => user.created && user.lastActive));

  // A plan with an end date applies at once and falls back to free when it ends.
  const end = app.time() + 3 * 24 * 60 * 60 * 1000;
  assert.equal((await admin(`/${account}/plan`, { plan: 'unlimited', until: end })).status, 400);
  assert.equal((await admin(`/${account}/plan`, { plan: 'gold', reason: 'test' })).status, 400);
  assert.equal((await admin(`/${account}/plan`, { plan: 'pro', until: app.time() - 1, reason: 'test' })).status, 400);
  const granted = (await admin(`/${account}/plan`, { plan: 'unlimited', until: end, reason: 'Owner access' })).body;
  assert.deepEqual([granted.plan, granted.planSource, granted.planUntil], ['unlimited', 'operator', end]);
  const seen = (await app.request('/account/plan', { token: first })).body;
  assert.equal(seen.plan, 'unlimited');
  assert.deepEqual(seen.available.map(option => option.id), ['free', 'basic', 'pro']);
  app.advance(4 * 24 * 60 * 60 * 1000);
  assert.equal((await app.request('/account/plan', { token: first })).body.plan, 'free');
  assert.deepEqual((await admin(`/${account}`)).body.actions.map(entry => entry.action), ['plan_expired', 'plan']);

  // A payment is recorded and can switch the plan in the same step.
  assert.equal((await admin(`/${account}/payments`, { amountCents: 0, currency: 'USD', method: 'card' })).status, 400);
  const paid = (await admin(`/${account}/payments`, { amountCents: 599, currency: 'usd', method: 'Bank transfer',
    reference: 'INV-1', plan: 'basic', until: app.time() + 31 * 24 * 60 * 60 * 1000 })).body;
  assert.deepEqual([paid.plan, paid.planSource, paid.payments.length, paid.payments[0].amountCents, paid.payments[0].currency],
    ['basic', 'payment', 1, 599, 'USD']);
  const summary = (await admin('/summary')).body;
  assert.deepEqual([summary.accounts, summary.plans.basic, summary.plans.free, summary.blocked], [2, 1, 1, 0]);
  assert.deepEqual(summary.payments, [{ currency: 'USD', amountCents: 599, count: 1 }]);
  // A repeated submission of the same payment number is refused and changes nothing.
  assert.equal((await admin(`/${account}/payments`, { amountCents: 599, currency: 'USD', method: 'Bank transfer', reference: 'INV-1' })).status, 409);
  assert.equal((await admin(`/${account}`)).body.payments.length, 1);
  assert.equal((await admin('?sort=constructor')).status, 200);
  assert.equal((await admin(`/${account}/plan`, { plan: 'pro', until: Number.MAX_SAFE_INTEGER, reason: 'test' })).status, 400);
  // An ended plan shows as free in the console even before the account's next request.
  const other = listed.users.find(user => user.email === 'second@example.com').account;
  await admin(`/${other}/plan`, { plan: 'pro', until: app.time() + 60_000, reason: 'Short trial' });
  assert.equal((await admin(`/${other}`)).body.plan, 'pro');
  app.advance(120_000);
  assert.deepEqual([(await admin(`/${other}`)).body.plan, (await admin('/summary')).body.plans.pro], ['free', undefined]);

  // Blocking takes effect on the next request and stops new sign-ins; unblocking restores both.
  assert.equal((await admin(`/${account}/block`, {})).status, 400);
  assert.equal((await admin(`/${account}/block`, { reason: 'Abuse report' })).body.blocked, 'Abuse report');
  const refused = await app.request('/models', { token: first });
  assert.deepEqual([refused.status, refused.body.error.code], [403, 'account_blocked']);
  assert.equal((await app.request('/account/devices', { token: first })).status, 403);
  assert.equal((await app.request('/models', { token: second })).status, 200);
  assert.equal((await app.connect('first@example.com', app.device('Tablet', 'ios'))).status, 403);
  assert.equal((await admin('?status=blocked')).body.total, 1);
  assert.equal((await admin(`/${account}/unblock`, { reason: 'Resolved' })).body.blocked, null);
  assert.equal((await app.request('/models', { token: first })).status, 200);

  // A revoked device loses access; the rest of the account keeps working.
  const devices = (await admin(`/${account}`)).body.deviceList;
  const laptop = devices.find(device => device.name === 'Laptop');
  assert.equal((await admin(`/${account}/devices/${laptop.id}`, { reason: 'Lost laptop' })).body.deviceList.length, devices.length - 1);
  assert.equal((await app.request('/models', { token: first })).status, 401);
  assert.equal((await admin(`/${account}/devices/${laptop.id}`, { reason: 'Again' })).status, 404);

  // Deletion needs the email typed back; payments and the action log remain as records.
  assert.equal((await admin(`/${account}/delete`, { confirm: 'wrong@example.com', reason: 'User request' })).status, 400);
  assert.deepEqual((await admin(`/${account}/delete`, { confirm: 'first@example.com', reason: 'User request' })).body, { ok: true });
  assert.equal((await admin(`/${account}`)).status, 404);
  assert.equal((await admin('')).body.total, 1);
  const db = new DatabaseSync(app.usagePath, { readOnly: true });
  assert.equal(db.prepare('SELECT COUNT(*) AS count FROM account_payments WHERE account = ?').get(account).count, 1);
  assert.equal(db.prepare("SELECT COUNT(*) AS count FROM admin_actions WHERE account = ? AND action = 'account_deleted'").get(account).count, 1);
  assert.equal(db.prepare("SELECT COUNT(*) AS count FROM admin_actions WHERE account = ? AND reason <> '' AND action <> 'account_deleted'").get(account).count, 0);
  assert.equal(db.prepare('SELECT COUNT(*) AS count FROM login_accounts').get().count, 1);
  db.close();
  assert.equal((await admin('/unknown-account')).status, 404);
  assert.equal((await admin('/a/b/c/d')).status, 404);
});
