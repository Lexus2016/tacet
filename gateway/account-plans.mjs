import { DatabaseSync } from 'node:sqlite';
import { GatewayError } from './routing.mjs';

// One price table for every account and platform: USD cents, allowances and a shared limit on
// connected devices. Paid allowances renew monthly. The free plan is a one-time allowance of
// cloud dictation that never renews; once it is used, only on-device dictation remains.
// Єдина таблиця тарифів для всіх акаунтів і платформ: центи США, пакети та спільний ліміт
// під'єднаних пристроїв. Платні пакети поновлюються щомісяця. Безплатний тариф — разовий запас
// хмарного диктування, який не поновлюється; після нього лишається диктування на пристрої.
export const plans = Object.freeze({
  free: { priceCents: 0, audioSeconds: 100 * 60, textTokens: 300_000, devices: 2 },
  basic: { priceCents: 499, audioSeconds: 600 * 60, textTokens: 1_000_000, devices: 5 },
  pro: { priceCents: 999, audioSeconds: 900 * 60, textTokens: 1_500_000, devices: 8 },
});

// Never offered for sale: set by the operator only. / Не продаються: призначає лише оператор.
export const operatorPlans = Object.freeze({
  paused: { priceCents: 0, audioSeconds: 0, textTokens: 0, devices: 2 },
  unlimited: { priceCents: 0, audioSeconds: null, textTokens: null, devices: 8 },
});

export const catalog = Object.freeze({ ...plans, ...operatorPlans });

const pcmSubtype = Buffer.from('0100000000001000800000aa00389b71', 'hex');

function wavSeconds(audio) {
  const invalid = () => new GatewayError(400, 'invalid_pilot_audio', 'Send a valid PCM WAV recording');
  if (audio?.format !== 'wav') throw invalid();
  const bytes = Buffer.from(audio.data, 'base64');
  if (bytes.length < 44 || bytes.toString('ascii', 0, 4) !== 'RIFF' ||
      bytes.toString('ascii', 8, 12) !== 'WAVE' || bytes.readUInt32LE(4) + 8 !== bytes.length) throw invalid();
  let format, samples;
  for (let offset = 12; offset + 8 <= bytes.length;) {
    const name = bytes.toString('ascii', offset, offset + 4);
    const size = bytes.readUInt32LE(offset + 4);
    const start = offset + 8;
    const next = start + size + (size % 2);
    if (next > bytes.length) throw invalid();
    if (name === 'fmt ') {
      if (format || size < 16) throw invalid();
      const encoding = bytes.readUInt16LE(start);
      const channels = bytes.readUInt16LE(start + 2);
      const rate = bytes.readUInt32LE(start + 4);
      const width = bytes.readUInt16LE(start + 14);
      const block = bytes.readUInt16LE(start + 12);
      const extensiblePCM = encoding === 0xfffe && size >= 40 && bytes.readUInt16LE(start + 16) >= 22 &&
        bytes.readUInt16LE(start + 18) === 16 && bytes.subarray(start + 24, start + 40).equals(pcmSubtype);
      if ((encoding !== 1 && !extensiblePCM) || channels !== 1 || rate < 8_000 || rate > 192_000 || width !== 16 || block !== 2 ||
          bytes.readUInt32LE(start + 8) !== rate * block) throw invalid();
      format = { rate, block };
    }
    if (name === 'data') {
      if (samples !== undefined) throw invalid();
      samples = size;
    }
    offset = next;
  }
  if (!format || !samples || samples % format.block !== 0) throw invalid();
  return Math.ceil(samples / format.block / format.rate);
}

function textUnits(input) {
  return input.messages.reduce((sum, message) => sum + Buffer.byteLength(message.content) + 16, input.max_tokens);
}

export function openAccountPlans({ path, pilotAccounts, managed = false, now = Date.now }) {
  if (!pilotAccounts?.length && !managed) return undefined;
  if (!path) throw new TypeError('Pilot plans require a usage database / Тестові тарифи потребують бази обліку');
  const allowed = new Set(pilotAccounts);
  const db = new DatabaseSync(path);
  db.exec('PRAGMA busy_timeout = 3000');

  function transaction(work) {
    db.exec('BEGIN IMMEDIATE');
    try {
      const value = work();
      db.exec('COMMIT');
      return value;
    } catch (error) {
      db.exec('ROLLBACK');
      throw error;
    }
  }

  transaction(() => {
    const tableExists = db.prepare("SELECT 1 FROM sqlite_master WHERE type = 'table' AND name = ?");
    const hadDailyAudio = tableExists.get('pilot_account_audio_daily');
    db.exec(`
      CREATE TABLE IF NOT EXISTS pilot_account_plan (account TEXT PRIMARY KEY, plan TEXT NOT NULL) STRICT;
      CREATE TABLE IF NOT EXISTS pilot_account_quota (
        account TEXT NOT NULL, month TEXT NOT NULL, audio INTEGER NOT NULL, text INTEGER NOT NULL,
        PRIMARY KEY (account, month)
      ) STRICT;
      CREATE TABLE IF NOT EXISTS pilot_account_audio_daily (
        account TEXT NOT NULL, day TEXT NOT NULL, audio INTEGER NOT NULL, PRIMARY KEY (account, day)
      ) STRICT;
      CREATE TABLE IF NOT EXISTS free_allowance (
        scope TEXT NOT NULL, id TEXT NOT NULL, audio INTEGER NOT NULL DEFAULT 0, text INTEGER NOT NULL DEFAULT 0,
        bonus_audio INTEGER NOT NULL DEFAULT 0, PRIMARY KEY (scope, id)
      ) STRICT;
    `);
    if (!hadDailyAudio && tableExists.get('usage_daily')) {
      // Carry only usage known to have occurred on the current UTC day.
      // Переносимо лише використання, яке зафіксовано в поточній добі UTC.
      const day = new Date(now()).toISOString().slice(0, 10);
      const month = day.slice(0, 7);
      db.prepare(`INSERT INTO pilot_account_audio_daily
        SELECT q.account, ?, q.audio FROM pilot_account_quota q WHERE q.month = ? AND q.audio > 0
          AND EXISTS (SELECT 1 FROM usage_daily u WHERE u.account = q.account AND u.operation = 'audio' AND u.completed > 0 AND u.day = ?)
          AND NOT EXISTS (SELECT 1 FROM usage_daily u WHERE u.account = q.account AND u.operation = 'audio'
            AND u.completed > 0 AND u.day >= ? AND u.day < ?)
      `).run(day, month, day, `${month}-01`, day);
    }
  });
  const readPlan = db.prepare('SELECT plan FROM pilot_account_plan WHERE account = ?');
  const savePlan = db.prepare(`INSERT INTO pilot_account_plan VALUES (?, ?) ON CONFLICT(account) DO UPDATE SET plan = excluded.plan`);
  const readUsage = db.prepare('SELECT audio, text FROM pilot_account_quota WHERE account = ? AND month = ?');
  const changeUsage = db.prepare(`INSERT INTO pilot_account_quota VALUES (?, ?, ?, ?)
    ON CONFLICT(account, month) DO UPDATE SET audio = audio + excluded.audio, text = text + excluded.text`);
  const changeDailyAudio = db.prepare(`INSERT INTO pilot_account_audio_daily VALUES (?, ?, ?)
    ON CONFLICT(account, day) DO UPDATE SET audio = audio + excluded.audio`);
  // The free allowance is counted for the account and for the device, and the larger figure
  // applies: a device that used it under one email brings nothing new to another.
  // Безплатний запас рахується і для акаунта, і для пристрою, а діє більше з двох чисел:
  // пристрій, який витратив його під однією поштою, нічого не додає іншій.
  const readFree = db.prepare('SELECT audio, text, bonus_audio AS bonus FROM free_allowance WHERE scope = ? AND id = ?');
  const changeFree = db.prepare(`INSERT INTO free_allowance (scope, id, audio, text) VALUES (?, ?, ?, ?)
    ON CONFLICT(scope, id) DO UPDATE SET audio = audio + excluded.audio, text = text + excluded.text`);

  function freeUsed(client) {
    const account = readFree.get('account', client.account) ?? { audio: 0, text: 0, bonus: 0 };
    const device = client.device ? readFree.get('device', client.device) : undefined;
    return { audio: Math.max(account.audio, device?.audio ?? 0), text: Math.max(account.text, device?.text ?? 0),
      bonus: account.bonus };
  }

  function chargeFree(client, audio, text) {
    changeFree.run('account', client.account, audio, text);
    if (client.device) changeFree.run('device', client.device, audio, text);
  }

  function get(client) {
    if (!client.account) throw new GatewayError(403, 'account_required', 'An account access key is required');
    const date = new Date(now());
    const day = date.toISOString().slice(0, 10);
    const month = day.slice(0, 7);
    const resetsAt = new Date(Date.UTC(date.getUTCFullYear(), date.getUTCMonth() + 1, 1)).toISOString();
    const saved = readPlan.get(client.account)?.plan;
    const plan = Object.hasOwn(catalog, saved) ? saved : 'free';
    const monthly = readUsage.get(client.account, month) ?? { audio: 0, text: 0 };
    const once = plan === 'free' ? freeUsed(client) : undefined;
    const used = once ?? monthly;
    // 'once' marks an allowance that never renews. / 'once' позначає запас, який не поновлюється.
    const audioPeriod = once ? 'once' : 'month';
    const audioResetsAt = once ? null : resetsAt;
    const limits = once?.bonus ? { ...catalog[plan], audioSeconds: catalog[plan].audioSeconds + once.bonus } : catalog[plan];
    const deviceAllowed = client.managed || client.seat <= limits.devices;
    const canSwitch = !client.managed && allowed.has(client.account);
    return { plan, day, month, resetsAt, audioPeriod, audioResetsAt, limits,
      used: { audioSeconds: used.audio, textTokens: used.text }, deviceAllowed,
      canSwitch, available: Object.entries(canSwitch ? catalog : plans).map(([id, limits]) => ({ id, ...limits })) };
  }

  return {
    get,
    select(client, id) {
      if (client.managed || !allowed.has(client.account)) throw new GatewayError(403, 'pilot_only', 'Plan switching is limited to pilot accounts');
      if (typeof id !== 'string' || !Object.hasOwn(catalog, id)) throw new GatewayError(400, 'invalid_plan', 'Unknown plan');
      savePlan.run(client.account, id);
      return get(client);
    },
    reserve(client, kind, input) {
      const amount = kind === 'audio' ? wavSeconds(input.input_audio) + 1 : textUnits(input);
      const snapshot = transaction(() => {
        const snapshot = get(client);
        if (snapshot.plan === 'paused') throw new GatewayError(403, 'plan_paused', 'Dictation is paused. Select a plan in Tacet.');
        if (!snapshot.deviceAllowed) throw new GatewayError(403, 'device_limit', 'This device exceeds the plan device limit');
        const field = kind === 'audio' ? 'audioSeconds' : 'textTokens';
        const limit = snapshot.limits[field];
        if (limit !== null && snapshot.used[field] + amount > limit) {
          if (snapshot.audioPeriod === 'once') {
            throw new GatewayError(429, 'plan_quota', 'The free cloud allowance has been used');
          }
          throw new GatewayError(429, 'plan_quota', 'The shared monthly allowance has been reached');
        }
        changeUsage.run(client.account, snapshot.month, kind === 'audio' ? amount : 0, kind === 'text' ? amount : 0);
        if (kind === 'audio') changeDailyAudio.run(client.account, snapshot.day, amount);
        if (snapshot.audioPeriod === 'once') chargeFree(client, kind === 'audio' ? amount : 0, kind === 'text' ? amount : 0);
        return snapshot;
      });
      return reply => {
        const input = reply?.usage?.prompt_tokens;
        const output = reply?.usage?.completion_tokens;
        const measuredText = Number.isSafeInteger(input) && input >= 0 && Number.isSafeInteger(output) && output >= 0
          ? input + output : amount;
        const charge = !reply || (kind === 'audio' && !reply.text.trim()) ? 0 : kind === 'audio' ? amount : Math.min(amount, measuredText);
        const refund = charge - amount;
        if (refund) transaction(() => {
          changeUsage.run(client.account, snapshot.month, kind === 'audio' ? refund : 0, kind === 'text' ? refund : 0);
          if (kind === 'audio') changeDailyAudio.run(client.account, snapshot.day, refund);
          if (snapshot.audioPeriod === 'once') chargeFree(client, kind === 'audio' ? refund : 0, kind === 'text' ? refund : 0);
        });
      };
    },
    close: () => db.close(),
  };
}
