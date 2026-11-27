import { createHash, createHmac, randomBytes, randomInt, randomUUID, timingSafeEqual } from 'node:crypto';
import { DatabaseSync } from 'node:sqlite';
import { catalog } from './account-plans.mjs';
import { GatewayError } from './routing.mjs';

const minute = 60_000;
const hour = 60 * minute;
const day = 24 * hour;
const opaque = () => randomBytes(32).toString('base64url');
const digest = value => createHash('sha256').update(value).digest('hex');
const isOpaque = value => typeof value === 'string' && /^[A-Za-z0-9_-]{43}$/.test(value);
const isUUID = value => typeof value === 'string' && /^[a-f0-9]{8}(?:-[a-f0-9]{4}){3}-[a-f0-9]{12}$/i.test(value);
const platforms = new Set(['macos', 'ios', 'windows', 'android']);
const badCode = () => new GatewayError(401, 'invalid_code', 'The code is invalid or has expired');
const blockedAccount = () => new GatewayError(403, 'account_blocked', 'This account is blocked. Contact Tacet support.');
const unknownDevice = () => new GatewayError(404, 'device_not_found', 'This device is no longer connected');
const unavailable = () => new GatewayError(503, 'login_unavailable', 'Could not send the sign-in code');

function emailAddress(value) {
  const email = typeof value === 'string' ? value.trim().toLowerCase() : '';
  if (email.length > 254 || !/^[a-z0-9!#$%&'*+\/=?^_`{|}~-]+(?:\.[a-z0-9!#$%&'*+\/=?^_`{|}~-]+)*@(?:[a-z0-9](?:[a-z0-9-]{0,61}[a-z0-9])?\.)+[a-z0-9](?:[a-z0-9-]{0,61}[a-z0-9])?$/.test(email) ||
      email.indexOf('@') > 64) {
    throw new GatewayError(400, 'invalid_email', 'Enter a valid email address');
  }
  return email;
}

function deviceFields(input) {
  const name = typeof input?.deviceName === 'string' ? input.deviceName.trim() : '';
  if (!isUUID(input?.deviceID) || !platforms.has(input?.platform) || !name || name.length > 80 || /[\p{Cc}\p{Cf}]/u.test(name)) {
    throw new GatewayError(400, 'invalid_device', 'Enter a valid device name and platform');
  }
  return { id: input.deviceID.toLowerCase(), name, platform: input.platform };
}

export function openAccountLogin({ path, sendCode, secret, now = Date.now, allowedEmails, reviewer, isBlocked = () => false }) {
  if (!path || typeof sendCode !== 'function' || typeof secret !== 'string' || Buffer.byteLength(secret) < 32) {
    throw new TypeError('Email login needs a database, mail delivery and a secret / Для входу потрібні база, пошта й секрет');
  }
  // App Review cannot read mail, so one named address signs in with a fixed code. It sends no mail,
  // is not counted against send limits, and exists only while the operator keeps the file in place.
  // Рецензент Apple не читає пошту, тож одна названа адреса входить зі сталим кодом. Лист не
  // надсилається, ліміти надсилань не рахуються, а доступ існує, лише поки оператор тримає файл.
  const review = reviewer && /^\d{6}$/.test(String(reviewer.code))
    ? { email: emailAddress(reviewer.email), code: String(reviewer.code) } : undefined;
  const allowed = allowedEmails?.length ? new Set(allowedEmails.map(emailAddress)) : undefined;
  const eligible = email => !allowed || allowed.has(email);
  const db = new DatabaseSync(path);
  db.exec(`
    PRAGMA busy_timeout = 3000;
    CREATE TABLE IF NOT EXISTS login_accounts (id TEXT PRIMARY KEY, email TEXT NOT NULL UNIQUE) STRICT;
    CREATE TABLE IF NOT EXISTS login_devices (
      account TEXT NOT NULL, id TEXT NOT NULL, name TEXT NOT NULL, platform TEXT NOT NULL,
      token TEXT NOT NULL UNIQUE, last_login INTEGER NOT NULL, PRIMARY KEY (account, id)
    ) STRICT;
    CREATE TABLE IF NOT EXISTS login_codes (
      id TEXT PRIMARY KEY, email TEXT NOT NULL, code TEXT NOT NULL, expires INTEGER NOT NULL,
      attempts INTEGER NOT NULL DEFAULT 0, ready INTEGER NOT NULL DEFAULT 0
    ) STRICT;
    CREATE INDEX IF NOT EXISTS login_codes_email ON login_codes(email);
    CREATE TABLE IF NOT EXISTS login_tickets (
      id TEXT PRIMARY KEY, account TEXT NOT NULL, device TEXT NOT NULL, name TEXT NOT NULL,
      platform TEXT NOT NULL, expires INTEGER NOT NULL
    ) STRICT;
    CREATE TABLE IF NOT EXISTS login_sends (email TEXT NOT NULL, source TEXT NOT NULL, time INTEGER NOT NULL) STRICT;
    CREATE INDEX IF NOT EXISTS login_sends_time ON login_sends(time);
    CREATE INDEX IF NOT EXISTS login_sends_email ON login_sends(email, time);
    CREATE INDEX IF NOT EXISTS login_sends_source ON login_sends(source, time);
  `);

  const removeExpiredCodes = db.prepare('DELETE FROM login_codes WHERE expires <= ?');
  const removeExpiredTickets = db.prepare('DELETE FROM login_tickets WHERE expires <= ?');
  const removeOldSends = db.prepare('DELETE FROM login_sends WHERE time <= ?');
  const emailSends = db.prepare('SELECT COUNT(*) AS count, MAX(time) AS last FROM login_sends WHERE email = ? AND time > ?');
  const sourceSends = db.prepare('SELECT COUNT(*) AS count FROM login_sends WHERE source = ? AND time > ?');
  const allSends = db.prepare('SELECT COUNT(*) AS count FROM login_sends WHERE time > ?');
  const addSend = db.prepare('INSERT INTO login_sends VALUES (?, ?, ?)');
  const invalidateCodes = db.prepare('DELETE FROM login_codes WHERE email = ?');
  const addCode = db.prepare('INSERT INTO login_codes (id, email, code, expires) VALUES (?, ?, ?, ?)');
  const readyCode = db.prepare('UPDATE login_codes SET ready = 1 WHERE id = ?');
  const removeCode = db.prepare('DELETE FROM login_codes WHERE id = ?');
  const tryCode = db.prepare(`UPDATE login_codes SET attempts = attempts + 1
    WHERE id = ? AND ready = 1 AND expires > ? AND attempts < 5 RETURNING email, code`);
  const findAccount = db.prepare('SELECT id, email FROM login_accounts WHERE email = ?');
  const accountByID = db.prepare('SELECT email FROM login_accounts WHERE id = ?');
  const addAccount = db.prepare('INSERT INTO login_accounts VALUES (?, ?)');
  const getPlan = db.prepare('SELECT plan FROM pilot_account_plan WHERE account = ?');
  const listDevices = db.prepare('SELECT id, name, platform FROM login_devices WHERE account = ? ORDER BY last_login DESC, id');
  const getDevice = db.prepare('SELECT id FROM login_devices WHERE account = ? AND id = ?');
  const removeDevice = db.prepare('DELETE FROM login_devices WHERE account = ? AND id = ?');
  const saveDevice = db.prepare(`INSERT INTO login_devices VALUES (?, ?, ?, ?, ?, ?)
    ON CONFLICT(account, id) DO UPDATE SET name = excluded.name, platform = excluded.platform,
      token = excluded.token, last_login = excluded.last_login`);
  const identifyDevice = db.prepare(`SELECT d.account, d.id AS device, d.platform, a.email FROM login_devices d
    JOIN login_accounts a ON a.id = d.account WHERE d.token = ?`);
  const addTicket = db.prepare('INSERT INTO login_tickets VALUES (?, ?, ?, ?, ?, ?)');
  const findTicket = db.prepare('SELECT * FROM login_tickets WHERE id = ? AND expires > ?');
  const removeTicket = db.prepare('DELETE FROM login_tickets WHERE id = ?');

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

  function codeDigest(id, email, code) {
    return createHmac('sha256', secret).update(JSON.stringify([id, email, code])).digest('hex');
  }

  function devices(account, current) {
    return listDevices.all(account).map(device => ({ ...device, current: device.id === current }));
  }

  function limit(account) {
    const plan = getPlan.get(account)?.plan;
    return (Object.hasOwn(catalog, plan) ? catalog[plan] : catalog.free).devices;
  }

  function connect(account, device, time) {
    const token = `tacet_device_${opaque()}`;
    saveDevice.run(account, device.id, device.name, device.platform, digest(token), time);
    return { token };
  }

  return {
    async start(value, source) {
      const email = emailAddress(value);
      const challengeID = opaque();
      if (review && email === review.email) {
        const time = now();
        transaction(() => {
          removeExpiredCodes.run(time);
          invalidateCodes.run(email);
          addCode.run(challengeID, email, codeDigest(challengeID, email, review.code), time + 60 * minute);
          readyCode.run(challengeID);
        });
        return { challengeID };
      }
      if (!eligible(email)) return { challengeID };
      const code = String(randomInt(1_000_000)).padStart(6, '0');
      const time = now();
      const emailKey = digest(email);
      const sourceKey = digest(source);
      transaction(() => {
        removeOldSends.run(time - day);
        removeExpiredCodes.run(time);
        removeExpiredTickets.run(time);
        const recent = emailSends.get(emailKey, time - hour);
        if (recent.count >= 5 || recent.last > time - minute || sourceSends.get(sourceKey, time - hour).count >= 25 ||
            allSends.get(time - hour).count >= 600) {
          throw new GatewayError(429, 'code_rate_limit', 'Wait before requesting another sign-in code', { retryAfter: minute });
        }
        addSend.run(emailKey, sourceKey, time);
        invalidateCodes.run(email);
        addCode.run(challengeID, email, codeDigest(challengeID, email, code), time + 10 * minute);
      });
      try {
        await sendCode({ email, code });
        readyCode.run(challengeID);
      } catch {
        removeCode.run(challengeID);
        throw unavailable();
      }
      return { challengeID };
    },

    verify(input) {
      if (!isOpaque(input?.challengeID) || typeof input.code !== 'string' || !/^\d{6}$/.test(input.code)) throw badCode();
      const device = deviceFields(input);
      const time = now();
      const result = transaction(() => {
        const challenge = tryCode.get(input.challengeID, time);
        if (!challenge || !eligible(challenge.email) || !timingSafeEqual(Buffer.from(challenge.code, 'hex'),
          Buffer.from(codeDigest(input.challengeID, challenge.email, input.code), 'hex'))) return undefined;
        removeCode.run(input.challengeID);
        let account = findAccount.get(challenge.email)?.id;
        if (!account) {
          account = `acct_${randomUUID()}`;
          addAccount.run(account, challenge.email);
        }
        // A blocked account gets no new device keys. / Заблокований акаунт не отримує нових ключів пристроїв.
        if (isBlocked(account)) throw blockedAccount();
        const existing = devices(account, device.id);
        if (existing.some(entry => entry.current) || existing.length < limit(account)) return connect(account, device, time);
        const ticket = opaque();
        addTicket.run(digest(ticket), account, device.id, device.name, device.platform, time + 5 * minute);
        return { ticket, devices: existing };
      });
      if (!result) throw badCode();
      return result;
    },

    replace(input) {
      if (!isOpaque(input?.ticket)) throw badCode();
      if (!isUUID(input.replaceDeviceID)) throw unknownDevice();
      const time = now();
      const hash = digest(input.ticket);
      return transaction(() => {
        const verified = findTicket.get(hash, time);
        if (!verified) throw badCode();
        const accountEmail = accountByID.get(verified.account)?.email;
        if (!accountEmail || !eligible(accountEmail)) throw badCode();
        const { account, device: id, name, platform } = verified;
        if (isBlocked(account)) throw blockedAccount();
        const existing = devices(account, id);
        if (!getDevice.get(account, input.replaceDeviceID.toLowerCase())) throw unknownDevice();
        if (!existing.some(entry => entry.current)) {
          const capacity = limit(account);
          if (existing.length > capacity) throw new GatewayError(409, 'device_limit', 'Disconnect more devices to continue');
          if (existing.length === capacity) removeDevice.run(account, input.replaceDeviceID.toLowerCase());
        }
        removeTicket.run(hash);
        return connect(account, { id, name, platform }, time);
      });
    },

    identify(header) {
      const token = /^Bearer (tacet_device_[A-Za-z0-9_-]{43})$/.exec(header ?? '')?.[1];
      if (!token) return undefined;
      const row = identifyDevice.get(digest(token));
      if (row && eligible(row.email)) return { account: row.account, platform: row.platform, device: row.device, managed: true };
    },

    devices: client => ({ devices: devices(client.account, client.device) }),

    revoke(client, device) {
      if (!isUUID(device) || !removeDevice.run(client.account, device.toLowerCase()).changes) throw unknownDevice();
      return { ok: true };
    },

    close: () => db.close(),
  };
}
