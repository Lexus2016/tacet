import { randomBytes } from 'node:crypto';

const lifetime = 8 * 60 * 60;

export function createAdminSessions({ secure, now = Date.now }) {
  const name = secure ? '__Secure-tacet_admin' : 'tacet_admin';
  const entries = new Map();
  const attributes = `Path=/admin/; HttpOnly; SameSite=Strict${secure ? '; Secure' : ''}`;

  function idFor(req) {
    const prefix = `${name}=`;
    const id = (req.headers.cookie ?? '').split(';').map(cookie => cookie.trim())
      .find(cookie => cookie.startsWith(prefix))?.slice(prefix.length);
    return /^[\w-]{43}$/.test(id ?? '') ? id : null;
  }

  return {
    has(req) {
      const id = idFor(req);
      const expires = entries.get(id);
      if (expires > now()) return true;
      entries.delete(id);
      return false;
    },
    open(req, res) {
      entries.delete(idFor(req));
      const time = now();
      for (const [id, expires] of entries) {
        if (expires <= time) entries.delete(id);
      }
      if (entries.size >= 64) entries.delete(entries.keys().next().value);
      const id = randomBytes(32).toString('base64url');
      entries.set(id, time + lifetime * 1000);
      res.setHeader('set-cookie', `${name}=${id}; Max-Age=${lifetime}; ${attributes}`);
    },
    close(req, res) {
      entries.delete(idFor(req));
      res.setHeader('set-cookie', `${name}=; Max-Age=0; ${attributes}`);
    },
  };
}
