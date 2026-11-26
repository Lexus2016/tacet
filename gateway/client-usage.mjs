import { createHash } from 'node:crypto';
import { mkdirSync, readFileSync } from 'node:fs';
import { dirname } from 'node:path';
import { DatabaseSync } from 'node:sqlite';

const platforms = new Set(['ios', 'android', 'macos', 'windows']);
const sharedClient = Object.freeze({ account: '', platform: 'unknown' });
const digest = token => createHash('sha256').update(token).digest('hex');
const nonnegative = value => Number.isFinite(value) && value >= 0 ? value : null;
const tokenCount = value => Number.isSafeInteger(value) && value >= 0 ? value : null;

export function openClientUsage({ registryPath, databasePath, clientToken, adminToken, managed = false, now = Date.now }) {
  if (registryPath && !databasePath) {
    throw new TypeError('Client registry requires a usage database / Реєстр клієнтів потребує сховища використання');
  }
  const clients = new Map();
  const seats = new Map();
  if (registryPath) {
    const entries = JSON.parse(readFileSync(registryPath, 'utf8'));
    if (!Array.isArray(entries)) throw new TypeError('Invalid client registry / Некоректний реєстр клієнтів');
    for (const entry of entries) {
      if (!entry || typeof entry.sha256 !== 'string' || !/^[0-9a-f]{64}$/.test(entry.sha256) ||
          typeof entry.account !== 'string' || !/^[a-zA-Z0-9_-]{1,64}$/.test(entry.account) ||
          !platforms.has(entry.platform) || clients.has(entry.sha256)) {
        throw new TypeError('Invalid client entry / Некоректний запис клієнта');
      }
      const family = ['macos', 'windows'].includes(entry.platform) ? 'desktop' : 'mobile';
      // Devices share one limit per account, whatever the platform.
      // Пристрої мають спільний ліміт на акаунт незалежно від платформи.
      const seat = (seats.get(entry.account) ?? 0) + 1;
      seats.set(entry.account, seat);
      clients.set(entry.sha256, { account: entry.account, platform: entry.platform, family, seat });
    }
  }
  const sharedHash = clientToken ? digest(clientToken) : undefined;
  if (clients.has(digest(adminToken)) || clients.has(sharedHash)) {
    throw new TypeError('Conflicting client credentials / Ключі клієнтів конфліктують');
  }
  if (!sharedHash && clients.size === 0 && !managed) {
    throw new TypeError('No client credentials configured / Не налаштовано ключів клієнтів');
  }
  function identify(header) {
    if (!header?.startsWith('Bearer ')) return undefined;
    const hash = digest(header.slice(7));
    return hash === sharedHash ? sharedClient : clients.get(hash);
  }

  if (!databasePath) return { identify };
  mkdirSync(dirname(databasePath), { recursive: true, mode: 0o700 });
  const database = new DatabaseSync(databasePath);
  database.exec(`
    PRAGMA journal_mode = WAL;
    CREATE TABLE IF NOT EXISTS usage_daily (
      day TEXT NOT NULL,
      account TEXT NOT NULL,
      platform TEXT NOT NULL,
      operation TEXT NOT NULL,
      route TEXT NOT NULL,
      model TEXT NOT NULL,
      attempts INTEGER NOT NULL,
      completed INTEGER NOT NULL,
      audio_seconds REAL NOT NULL,
      audio_seconds_samples INTEGER NOT NULL,
      input_tokens INTEGER NOT NULL,
      output_tokens INTEGER NOT NULL,
      token_samples INTEGER NOT NULL,
      reported_cost_usd REAL NOT NULL,
      cost_samples INTEGER NOT NULL,
      PRIMARY KEY (day, account, platform, operation, route, model)
    ) STRICT;
  `);
  const accumulate = database.prepare(`
    INSERT INTO usage_daily (day, account, platform, operation, route, model, attempts, completed,
      audio_seconds, audio_seconds_samples, input_tokens, output_tokens, token_samples, reported_cost_usd, cost_samples)
    VALUES (?, ?, ?, ?, ?, ?, 1, ?, ?, ?, ?, ?, ?, ?, ?)
    ON CONFLICT (day, account, platform, operation, route, model) DO UPDATE SET
      attempts = attempts + 1,
      completed = completed + excluded.completed,
      audio_seconds = audio_seconds + excluded.audio_seconds,
      audio_seconds_samples = audio_seconds_samples + excluded.audio_seconds_samples,
      input_tokens = input_tokens + excluded.input_tokens,
      output_tokens = output_tokens + excluded.output_tokens,
      token_samples = token_samples + excluded.token_samples,
      reported_cost_usd = reported_cost_usd + excluded.reported_cost_usd,
      cost_samples = cost_samples + excluded.cost_samples
  `);

  let lastError = -Infinity;
  return {
    identify,
    record(client, operation, { route, data, completed, started }) {
      const day = new Date(started).toISOString().slice(0, 10);
      const usage = data?.usage;
      const seconds = operation === 'audio' ? nonnegative(usage?.seconds) ?? nonnegative(data?.duration) : null;
      const input = operation === 'text' ? tokenCount(usage?.prompt_tokens) : null;
      const output = operation === 'text' ? tokenCount(usage?.completion_tokens) : null;
      const cost = nonnegative(usage?.cost);
      try {
        accumulate.run(day, client.account, client.platform, operation, route.id, route.model, Number(completed),
          seconds ?? 0, Number(seconds !== null), input ?? 0, output ?? 0, Number(input !== null && output !== null),
          cost ?? 0, Number(cost !== null));
      } catch (error) {
        // Pilot measurements are best effort. / Виміри пілоту не блокують диктування.
        const time = now();
        if (time - lastError >= 60_000) {
          lastError = time;
          console.error('Tacet usage write failed / Не вдалося записати використання Tacet', error.code ?? error.name);
        }
      }
    },
    close: () => database.close(),
  };
}
