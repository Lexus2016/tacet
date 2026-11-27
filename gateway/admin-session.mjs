import { createHash, randomBytes, randomUUID } from 'node:crypto';
import { mkdirSync, readFileSync, renameSync, rmSync, writeFileSync } from 'node:fs';
import { dirname } from 'node:path';

// The owner stays signed in for 30 days. Sessions are kept on disk (as hashes, never the cookie
// value itself), so restarting or redeploying the gateway does not sign anyone out.
// Власник лишається в системі 30 днів. Сеанси зберігаємо на диску (як хеші, а не саме значення
// cookie), тож перезапуск чи нове розгортання шлюзу нікого не розлогінює.
const lifetime = 30 * 24 * 60 * 60;
const maxSessions = 64;

const digest = id => createHash('sha256').update(id).digest('base64url');

export function createAdminSessions({ secure, now = Date.now, path }) {
  const name = secure ? '__Secure-tacet_admin' : 'tacet_admin';
  const entries = new Map();
  const attributes = `Path=/admin/; HttpOnly; SameSite=Strict${secure ? '; Secure' : ''}`;

  if (path) {
    try {
      const saved = JSON.parse(readFileSync(path, 'utf8'));
      for (const [hash, expires] of Object.entries(saved?.sessions ?? {})) {
        if (/^[\w-]{43}$/.test(hash) && Number.isFinite(expires) && expires > now()) entries.set(hash, expires);
      }
    } catch {
      // No saved sessions yet, or the file is unreadable: everyone signs in again.
    }
  }

  function persist() {
    if (!path) return;
    const temporary = `${path}.${randomUUID()}.tmp`;
    try {
      mkdirSync(dirname(path), { recursive: true, mode: 0o700 });
      writeFileSync(temporary, JSON.stringify({ sessions: Object.fromEntries(entries) }), { mode: 0o600, flag: 'wx' });
      renameSync(temporary, path);
    } catch {
      // A sign-in must not fail because the disk is full; the session still works until a restart.
      rmSync(temporary, { force: true });
    }
  }

  function keyFor(req) {
    const prefix = `${name}=`;
    const id = (req.headers.cookie ?? '').split(';').map(cookie => cookie.trim())
      .find(cookie => cookie.startsWith(prefix))?.slice(prefix.length);
    return /^[\w-]{43}$/.test(id ?? '') ? digest(id) : null;
  }

  return {
    has(req) {
      const key = keyFor(req);
      const expires = entries.get(key);
      if (expires > now()) return true;
      if (entries.delete(key)) persist();
      return false;
    },
    open(req, res) {
      entries.delete(keyFor(req));
      const time = now();
      for (const [key, expires] of entries) {
        if (expires <= time) entries.delete(key);
      }
      while (entries.size >= maxSessions) entries.delete(entries.keys().next().value);
      const id = randomBytes(32).toString('base64url');
      entries.set(digest(id), time + lifetime * 1000);
      persist();
      res.setHeader('set-cookie', `${name}=${id}; Max-Age=${lifetime}; ${attributes}`);
    },
    close(req, res) {
      if (entries.delete(keyFor(req))) persist();
      res.setHeader('set-cookie', `${name}=; Max-Age=0; ${attributes}`);
    },
  };
}
