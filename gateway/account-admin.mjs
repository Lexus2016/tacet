import { DatabaseSync } from 'node:sqlite';
import { catalog } from './account-plans.mjs';
import { GatewayError } from './routing.mjs';

const day = 24 * 60 * 60 * 1000;
const money = (cents, currency) => `${(cents / 100).toFixed(2)} ${currency}`;
const sorts = {
  active: 'COALESCE(s.last_active, 0) DESC', created: 'COALESCE(s.created, 0) DESC',
  audio: 'audio DESC', text: 'text DESC', email: "COALESCE(a.email, k.account)",
};

function text(value, name, max, required = true) {
  const result = typeof value === 'string' ? value.trim() : '';
  if ((required && !result) || result.length > max || /[\u0000-\u001f\u007f]/.test(result)) {
    throw new GatewayError(400, 'invalid_admin_input', `Enter a valid ${name}`);
  }
  return result;
}

// Operator tools over the account database: who the users are, what they use, and the manual
// decisions about them. Every change is written to an append-only action log.
// Інструменти оператора над базою акаунтів: хто користувачі, що вони використовують, і ручні
// рішення щодо них. Кожна зміна потрапляє в журнал дій, який лише доповнюється.
export function openAccountAdmin({ path, now = Date.now }) {
  const db = new DatabaseSync(path);
  db.exec(`
    PRAGMA busy_timeout = 3000;
    CREATE TABLE IF NOT EXISTS account_state (
      account TEXT PRIMARY KEY, created INTEGER NOT NULL, last_active INTEGER NOT NULL,
      blocked TEXT, plan_source TEXT NOT NULL DEFAULT 'default', plan_until INTEGER
    ) STRICT;
    CREATE TABLE IF NOT EXISTS admin_actions (
      id INTEGER PRIMARY KEY AUTOINCREMENT, time INTEGER NOT NULL, account TEXT NOT NULL,
      action TEXT NOT NULL, detail TEXT NOT NULL, reason TEXT NOT NULL
    ) STRICT;
    CREATE INDEX IF NOT EXISTS admin_actions_account ON admin_actions(account, id);
    CREATE TABLE IF NOT EXISTS account_payments (
      id INTEGER PRIMARY KEY AUTOINCREMENT, account TEXT NOT NULL, time INTEGER NOT NULL,
      amount_cents INTEGER NOT NULL, currency TEXT NOT NULL, method TEXT NOT NULL,
      reference TEXT NOT NULL, note TEXT NOT NULL, recorded INTEGER NOT NULL
    ) STRICT;
    CREATE INDEX IF NOT EXISTS account_payments_account ON account_payments(account, time);
    CREATE TABLE IF NOT EXISTS transition_gifts (device TEXT PRIMARY KEY, account TEXT NOT NULL, time INTEGER NOT NULL) STRICT;
    CREATE TABLE IF NOT EXISTS free_allowance (
      scope TEXT NOT NULL, id TEXT NOT NULL, audio INTEGER NOT NULL DEFAULT 0, text INTEGER NOT NULL DEFAULT 0,
      bonus_audio INTEGER NOT NULL DEFAULT 0, PRIMARY KEY (scope, id)
    ) STRICT;
  `);

  const known = `known(account) AS (
    SELECT id FROM login_accounts UNION SELECT account FROM pilot_account_plan
    UNION SELECT account FROM pilot_account_quota UNION SELECT account FROM account_state)`;
  const columns = `k.account, a.email, p.plan, s.created, s.last_active, s.blocked, s.plan_source, s.plan_until,
    (SELECT COUNT(*) FROM login_devices d WHERE d.account = k.account) AS devices,
    COALESCE(q.audio, 0) AS audio, COALESCE(q.text, 0) AS text,
    COALESCE(f.audio, 0) AS free_audio, COALESCE(f.text, 0) AS free_text, COALESCE(f.bonus_audio, 0) AS bonus`;
  const joins = `FROM known k LEFT JOIN login_accounts a ON a.id = k.account
    LEFT JOIN pilot_account_plan p ON p.account = k.account
    LEFT JOIN account_state s ON s.account = k.account
    LEFT JOIN pilot_account_quota q ON q.account = k.account AND q.month = ?
    LEFT JOIN free_allowance f ON f.scope = 'account' AND f.id = k.account`;
  const filter = `WHERE (? = '' OR a.email LIKE ? ESCAPE '\\' OR k.account LIKE ? ESCAPE '\\')
    AND (? = '' OR (? = 'blocked') = (s.blocked IS NOT NULL))`;
  const lists = Object.fromEntries(Object.entries(sorts).map(([name, order]) => [name,
    db.prepare(`WITH ${known} SELECT ${columns} ${joins} ${filter} ORDER BY ${order}, k.account`)]));
  const one = db.prepare(`WITH ${known} SELECT ${columns} ${joins} WHERE k.account = ?`);
  const readState = db.prepare('SELECT blocked, plan_until FROM account_state WHERE account = ?');
  // A row created by an operator action has no known dates (0) until the account is next seen.
  // Рядок, створений дією оператора, не має відомих дат (0), доки акаунт не з'явиться знову.
  const touch = db.prepare(`INSERT INTO account_state (account, created, last_active) VALUES (?, ?, ?)
    ON CONFLICT(account) DO UPDATE SET last_active = excluded.last_active,
      created = CASE WHEN created = 0 THEN excluded.created ELSE created END`);
  const addState = db.prepare('INSERT OR IGNORE INTO account_state (account, created, last_active) VALUES (?, 0, 0)');
  const findPayment = db.prepare("SELECT 1 FROM account_payments WHERE account = ? AND reference = ? AND reference <> ''");
  const scrubPayments = db.prepare("UPDATE account_payments SET note = '' WHERE account = ?");
  const scrubActions = db.prepare("UPDATE admin_actions SET reason = '' WHERE account = ?");
  const setBlocked = db.prepare('UPDATE account_state SET blocked = ? WHERE account = ?');
  const setPlanState = db.prepare('UPDATE account_state SET plan_source = ?, plan_until = ? WHERE account = ?');
  const savePlan = db.prepare(`INSERT INTO pilot_account_plan VALUES (?, ?)
    ON CONFLICT(account) DO UPDATE SET plan = excluded.plan`);
  const log = db.prepare('INSERT INTO admin_actions (time, account, action, detail, reason) VALUES (?, ?, ?, ?, ?)');
  const addGift = db.prepare('INSERT OR IGNORE INTO transition_gifts (device, account, time) VALUES (?, ?, ?)');
  const currentPlan = db.prepare('SELECT plan FROM pilot_account_plan WHERE account = ?');
  const actions = db.prepare('SELECT time, action, detail, reason FROM admin_actions WHERE account = ? ORDER BY id DESC LIMIT 100');
  const addPayment = db.prepare(`INSERT INTO account_payments
    (account, time, amount_cents, currency, method, reference, note, recorded) VALUES (?, ?, ?, ?, ?, ?, ?, ?)`);
  const payments = db.prepare(`SELECT time, amount_cents AS amountCents, currency, method, reference, note
    FROM account_payments WHERE account = ? ORDER BY time DESC, id DESC LIMIT 100`);
  const devices = db.prepare('SELECT id, name, platform, last_login AS lastLogin FROM login_devices WHERE account = ? ORDER BY last_login DESC, id');
  const removeDevice = db.prepare('DELETE FROM login_devices WHERE account = ? AND id = ?');
  const dailyAudio = db.prepare('SELECT audio FROM pilot_account_audio_daily WHERE account = ? AND day = ?');
  const usageDays = db.prepare(`SELECT day, platform, operation, SUM(attempts) AS attempts, SUM(completed) AS completed,
      CAST(ROUND(SUM(audio_seconds)) AS INTEGER) AS audioSeconds, SUM(input_tokens + output_tokens) AS tokens,
      SUM(reported_cost_usd) AS costUSD
    FROM usage_daily WHERE account = ? AND day >= ? GROUP BY day, platform, operation ORDER BY day DESC, platform, operation`);
  const planCounts = db.prepare(`WITH ${known} SELECT
      CASE WHEN s.plan_until IS NOT NULL AND s.plan_until <= ? THEN 'free' ELSE p.plan END AS plan, COUNT(*) AS count, SUM(s.blocked IS NOT NULL) AS blocked,
      SUM(COALESCE(s.created, 0) > ?) AS recent, SUM(COALESCE(s.last_active, 0) > ?) AS active
    FROM known k LEFT JOIN pilot_account_plan p ON p.account = k.account
    LEFT JOIN account_state s ON s.account = k.account GROUP BY 1`);
  const monthUsage = db.prepare('SELECT COALESCE(SUM(audio), 0) AS audio, COALESCE(SUM(text), 0) AS text FROM pilot_account_quota WHERE month = ?');
  const monthCost = db.prepare(`SELECT COALESCE(SUM(reported_cost_usd), 0) AS cost, COALESCE(SUM(cost_samples), 0) AS samples,
    COALESCE(SUM(attempts), 0) AS attempts FROM usage_daily WHERE day >= ? AND day < ?`);
  const monthPayments = db.prepare(`SELECT currency, SUM(amount_cents) AS amountCents, COUNT(*) AS count
    FROM account_payments WHERE time >= ? AND time < ? GROUP BY currency ORDER BY currency`);
  const removals = [
    'DELETE FROM login_codes WHERE email = (SELECT email FROM login_accounts WHERE id = ?)',
    'DELETE FROM login_tickets WHERE account = ?', 'DELETE FROM login_devices WHERE account = ?',
    'DELETE FROM pilot_account_plan WHERE account = ?', 'DELETE FROM pilot_account_quota WHERE account = ?',
    'DELETE FROM pilot_account_audio_daily WHERE account = ?', 'DELETE FROM usage_daily WHERE account = ?',
    'DELETE FROM account_state WHERE account = ?', 'DELETE FROM login_accounts WHERE id = ?',
    // Device rows stay: they hold no personal data and stop a deleted account from being
    // re-created for a fresh allowance.
    // Рядки пристроїв лишаються: особистих даних у них немає, і вони не дають відтворити
    // видалений акаунт заради нового запасу.
    "DELETE FROM free_allowance WHERE scope = 'account' AND id = ?",
  ].map(sql => db.prepare(sql));
  const addBonus = db.prepare(`INSERT INTO free_allowance (scope, id, bonus_audio) VALUES ('account', ?, ?)
    ON CONFLICT(scope, id) DO UPDATE SET bonus_audio = bonus_audio + excluded.bonus_audio`);

  const seen = new Map();

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

  function month(time) {
    const date = new Date(time);
    const start = Date.UTC(date.getUTCFullYear(), date.getUTCMonth(), 1);
    return { id: date.toISOString().slice(0, 7), start, end: Date.UTC(date.getUTCFullYear(), date.getUTCMonth() + 1, 1) };
  }

  // A plan past its end date counts as free everywhere, also before the account's next request.
  // Тариф після дати завершення всюди вважається безплатним, ще до наступного запиту акаунта.
  const ended = (row, time) => Boolean(row.plan_until && row.plan_until <= time);

  function present(row, time = now()) {
    const expired = ended(row, time);
    if (expired) row = { ...row, plan: 'free', plan_source: 'default', plan_until: null };
    const plan = Object.hasOwn(catalog, row.plan) ? row.plan : 'free';
    // The free plan is a one-time allowance: show what is used of it, not this month's usage.
    // A device that used its allowance under another email can make the user's own figure higher.
    // Безплатний тариф — разовий запас: показуємо, скільки з нього використано, а не місячне
    // використання. Пристрій, що витратив запас під іншою поштою, може зробити число користувача вищим.
    const once = plan === 'free';
    return {
      account: row.account, email: row.email, plan,
      limits: once && row.bonus ? { ...catalog.free, audioSeconds: catalog.free.audioSeconds + row.bonus } : catalog[plan],
      planSource: row.plan_source ?? 'default', planUntil: row.plan_until,
      blocked: row.blocked, created: row.created, lastActive: row.last_active, devices: row.devices,
      period: once ? 'once' : 'month', bonusAudioSeconds: row.bonus,
      used: once ? { audioSeconds: row.free_audio, textTokens: row.free_text } : { audioSeconds: row.audio, textTokens: row.text },
    };
  }

  function find(account) {
    const row = typeof account === 'string' ? one.get(month(now()).id, account) : undefined;
    if (!row) throw new GatewayError(404, 'unknown_account', 'Account not found');
    return row;
  }

  // The state row is created on first use, so an update always has a row to change.
  // Рядок стану створюється під час першого використання, тож оновленню завжди є що змінити.
  function ensure(account) {
    addState.run(account);
  }

  function until(value, time) {
    if (value === null || value === undefined || value === '') return null;
    const parsed = typeof value === 'number' ? value : Date.parse(value);
    if (!Number.isSafeInteger(parsed) || parsed <= time || parsed > time + 3660 * day) {
      throw new GatewayError(400, 'invalid_admin_input', 'Enter an end date within the next ten years');
    }
    return parsed;
  }

  function assign(account, plan, end, source, reason, time) {
    if (typeof plan !== 'string' || !Object.hasOwn(catalog, plan)) throw new GatewayError(400, 'invalid_plan', 'Unknown plan');
    ensure(account);
    savePlan.run(account, plan);
    setPlanState.run(plan === 'free' ? 'default' : source, plan === 'free' ? null : end, account);
    log.run(time, account, 'plan', JSON.stringify({ plan, until: plan === 'free' ? null : end, source }), reason);
  }

  return {
    // Called for every identified request: refuses a blocked account, ends an expired plan and
    // records activity (at most once a minute per account).
    // Викликається для кожного розпізнаного запиту: відмовляє заблокованому акаунту, завершує
    // прострочений тариф і фіксує активність (не частіше ніж раз на хвилину на акаунт).
    guard(account) {
      const time = now();
      const state = readState.get(account);
      if (state?.plan_until && state.plan_until <= time) {
        transaction(() => {
          savePlan.run(account, 'free');
          setPlanState.run('default', null, account);
          log.run(time, account, 'plan_expired', JSON.stringify({ plan: 'free' }), 'The plan reached its end date');
        });
      }
      if (state?.blocked) throw new GatewayError(403, 'account_blocked', 'This account is blocked. Contact Tacet support.');
      if (!state || time - (seen.get(account) ?? 0) >= 60_000) {
        if (seen.size > 10_000) seen.clear();
        seen.set(account, time);
        touch.run(account, time, time);
      }
    },

    isBlocked: account => Boolean(readState.get(account)?.blocked),

    list(input = {}) {
      const query = typeof input.query === 'string' ? input.query.trim().toLowerCase().slice(0, 100) : '';
      const pattern = `%${query.replace(/[\\%_]/g, '\\$&')}%`;
      const status = ['blocked', 'active'].includes(input.status) ? input.status : '';
      const plan = typeof input.plan === 'string' && Object.hasOwn(catalog, input.plan) ? input.plan : '';
      const rows = (Object.hasOwn(lists, input.sort) ? lists[input.sort] : lists.active).all(month(now()).id, query, pattern, pattern, status, status)
        .map(row => present(row)).filter(row => !plan || row.plan === plan);
      const offset = Math.max(0, Number.parseInt(input.offset, 10) || 0);
      return { total: rows.length, offset, users: rows.slice(offset, offset + 100) };
    },

    detail(account) {
      const time = now();
      const today = new Date(time).toISOString().slice(0, 10);
      return {
        ...present(find(account)),
        usedToday: { audioSeconds: dailyAudio.get(account, today)?.audio ?? 0 },
        deviceList: devices.all(account),
        usage: usageDays.all(account, new Date(time - 30 * day).toISOString().slice(0, 10)),
        payments: payments.all(account), actions: actions.all(account),
        plans: Object.entries(catalog).map(([id, limits]) => ({ id, ...limits })),
      };
    },

    summary() {
      const time = now();
      const current = month(time);
      const days = [new Date(current.start).toISOString().slice(0, 10), new Date(current.end).toISOString().slice(0, 10)];
      const plans = {};
      const totals = { accounts: 0, blocked: 0, newThisWeek: 0, activeThisWeek: 0 };
      for (const row of planCounts.all(time, time - 7 * day, time - 7 * day)) {
        const plan = Object.hasOwn(catalog, row.plan) ? row.plan : 'free';
        plans[plan] = (plans[plan] ?? 0) + row.count;
        totals.accounts += row.count;
        totals.blocked += row.blocked;
        totals.newThisWeek += row.recent;
        totals.activeThisWeek += row.active;
      }
      const used = monthUsage.get(current.id);
      const cost = monthCost.get(...days);
      return {
        ...totals, plans, month: current.id, used: { audioSeconds: used.audio, textTokens: used.text },
        // Providers do not report a cost for every request, so this is a lower bound.
        // Провайдери повідомляють вартість не для кожного запиту, тож це нижня межа.
        providerCost: { usd: cost.cost, reportedRequests: cost.samples, requests: cost.attempts },
        payments: monthPayments.all(current.start, current.end),
      };
    },

    // People who used the Mac app before accounts existed get one month of Basic when they first
    // sign in: once per device, and only while the account is on the free plan. The app reports
    // the earlier use itself, so this is a courtesy, not a security boundary.
    // Ті, хто користувався застосунком для Mac до появи акаунтів, отримують місяць Basic під час
    // першого входу: раз на пристрій і лише поки акаунт на безплатному тарифі. Про попереднє
    // користування повідомляє сам застосунок, тож це люб'язність, а не межа безпеки.
    welcomeBack(account, device) {
      const time = now();
      return transaction(() => {
        const plan = currentPlan.get(account)?.plan ?? 'free';
        if (plan !== 'free' || addGift.run(device, account, time).changes === 0) return false;
        assign(account, 'basic', time + 30 * day, 'gift', 'A month of Basic for moving from the earlier Mac version', time);
        return true;
      });
    },

    setPlan(account, input) {
      const time = now();
      find(account);
      const reason = text(input?.reason, 'reason', 200);
      const end = until(input?.until, time);
      transaction(() => assign(account, input?.plan, end, 'operator', reason, time));
      return this.detail(account);
    },

    // Adds minutes to an account's one-time free allowance. / Додає хвилини до разового безплатного запасу акаунта.
    grantMinutes(account, input) {
      const time = now();
      find(account);
      const minutes = input?.minutes;
      if (!Number.isSafeInteger(minutes) || minutes <= 0 || minutes > 10_000) {
        throw new GatewayError(400, 'invalid_admin_input', 'Enter between 1 and 10000 minutes');
      }
      const reason = text(input?.reason, 'reason', 200);
      transaction(() => {
        ensure(account);
        addBonus.run(account, minutes * 60);
        log.run(time, account, 'allowance', JSON.stringify({ minutes }), reason);
      });
      return this.detail(account);
    },

    block(account, input) {
      const time = now();
      find(account);
      const reason = text(input?.reason, 'reason', 200);
      transaction(() => {
        ensure(account);
        setBlocked.run(reason, account);
        log.run(time, account, 'block', '{}', reason);
      });
      return this.detail(account);
    },

    unblock(account, input) {
      const time = now();
      find(account);
      const reason = text(input?.reason, 'reason', 200);
      transaction(() => {
        ensure(account);
        setBlocked.run(null, account);
        log.run(time, account, 'unblock', '{}', reason);
      });
      return this.detail(account);
    },

    // Records money received. With a plan it also activates that plan until the given date.
    // Фіксує отримані гроші. Якщо вказано тариф, одразу вмикає його до заданої дати.
    recordPayment(account, input) {
      const time = now();
      find(account);
      const amount = input?.amountCents;
      if (!Number.isSafeInteger(amount) || amount <= 0 || amount > 100_000_00) {
        throw new GatewayError(400, 'invalid_admin_input', 'Enter a valid amount');
      }
      const currency = text(input?.currency, 'currency', 3).toUpperCase();
      if (!/^[A-Z]{3}$/.test(currency)) throw new GatewayError(400, 'invalid_admin_input', 'Enter a three-letter currency');
      const method = text(input?.method, 'payment method', 40);
      const reference = text(input?.reference, 'reference', 120, false);
      const note = text(input?.note, 'note', 200, false);
      const paid = input?.time === undefined || input.time === null || input.time === '' ? time
        : typeof input.time === 'number' ? input.time : Date.parse(input.time);
      if (!Number.isSafeInteger(paid) || paid > time + day || paid < time - 3660 * day) {
        throw new GatewayError(400, 'invalid_admin_input', 'Enter a valid payment date');
      }
      const end = input?.plan ? until(input.until, time) : null;
      transaction(() => {
        // The same payment number is recorded once, so a repeated submission cannot double the money.
        // Той самий номер платежу фіксується раз, тож повторне надсилання не подвоює суму.
        if (findPayment.get(account, reference)) {
          throw new GatewayError(409, 'duplicate_payment', 'This payment reference is already recorded');
        }
        addPayment.run(account, paid, amount, currency, method, reference, note, time);
        log.run(time, account, 'payment', JSON.stringify({ amountCents: amount, currency, method, reference }), note || 'Payment recorded');
        if (input?.plan) assign(account, input.plan, end, 'payment', `Payment ${reference || money(amount, currency)}`, time);
      });
      return this.detail(account);
    },

    revokeDevice(account, device, input) {
      const time = now();
      find(account);
      const reason = text(input?.reason, 'reason', 200);
      transaction(() => {
        if (typeof device !== 'string' || !removeDevice.run(account, device.toLowerCase()).changes) {
          throw new GatewayError(404, 'unknown_device', 'Device not found');
        }
        log.run(time, account, 'device_revoked', JSON.stringify({ device: device.toLowerCase() }), reason);
      });
      return this.detail(account);
    },

    // Removes the account and its usage. Payments and the action log stay as accounting records,
    // linked only to the opaque account identifier, with earlier notes and reasons cleared.
    // Видаляє акаунт і його використання. Оплати й журнал дій лишаються як облікові записи,
    // пов'язані лише з непрозорим ідентифікатором акаунта.
    remove(account, input) {
      const time = now();
      const row = find(account);
      if (!row.email) throw new GatewayError(400, 'invalid_admin_input', 'Only email accounts can be deleted here');
      if (input?.confirm !== row.email) throw new GatewayError(400, 'confirmation_required', 'Type the account email to confirm');
      const reason = text(input?.reason, 'reason', 200);
      transaction(() => {
        for (const statement of removals) statement.run(account);
        // Free text typed by the operator may name the person; amounts, dates and references stay.
        // Вільний текст оператора може називати людину; суми, дати й номери платежів лишаються.
        scrubPayments.run(account);
        scrubActions.run(account);
        log.run(time, account, 'account_deleted', '{}', reason);
      });
      seen.delete(account);
      return { ok: true };
    },

    close: () => db.close(),
  };
}
