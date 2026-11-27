import { timingSafeEqual } from 'node:crypto';
import { readFileSync } from 'node:fs';
import { createServer } from 'node:http';
import { isIP } from 'node:net';
import { createAdminSessions } from './admin-session.mjs';
import { openAccountLogin } from './account-login.mjs';
import { openAccountAdmin } from './account-admin.mjs';
import { openAccountPlans, selectionWordLimit, selectionWords } from './account-plans.mjs';
import { openClientUsage } from './client-usage.mjs';
import { ConfigConflict, openRouteStore } from './routes.mjs';
import { createRouter, GatewayError } from './routing.mjs';

const assets = new Map([
  ['/admin/', ['index.html', 'text/html; charset=utf-8']],
  ['/admin/app.js', ['app.js', 'text/javascript; charset=utf-8']],
  ['/admin/users.js', ['users.js', 'text/javascript; charset=utf-8']],
  ['/admin/style.css', ['style.css', 'text/css; charset=utf-8']],
].map(([path, [file, type]]) => [path, [readFileSync(new URL(`./admin/${file}`, import.meta.url)), type]]));

const audioLimit = 8 * 1024 * 1024;
const multipartAudioLimit = audioLimit + 64 * 1024;
const jsonAudioLimit = 4 * Math.ceil(audioLimit / 3) + 2 * 1024;
const clientModels = { text: 'tacet-text', audio: 'tacet-transcription' };
const audioFormats = new Set(['wav', 'mp3', 'flac', 'm4a', 'ogg', 'webm', 'aac', 'mp4', 'mpeg', 'mpga']);
const textRoles = new Set(['system', 'developer', 'user', 'assistant']);
const loopback = new Set(['127.0.0.1', '::1', '::ffff:127.0.0.1']);
const expandedTextBodyLimit = 640 * 1024;
const expandedTextContext = 130_000;

const invalid = message => new GatewayError(400, 'invalid_input', message);
const tooLarge = () => new GatewayError(413, 'payload_too_large', 'Request exceeds the size limit');

function keysMatch(value, token) {
  if (typeof value !== 'string') return false;
  const actual = Buffer.from(value);
  const expected = Buffer.from(token);
  return actual.length === expected.length && timingSafeEqual(actual, expected);
}

function allowed(req, token) {
  const value = req.headers.authorization;
  return value?.startsWith('Bearer ') && keysMatch(value.slice(7), token);
}

function localAdminRequest(req) {
  return loopback.has(req.socket.localAddress) && loopback.has(req.socket.remoteAddress) &&
    /^(127\.0\.0\.1|localhost|\[::1\])(?::[0-9]{1,5})?$/.test(req.headers.host ?? '') &&
    !Object.keys(req.headers).some(name => name === 'forwarded' || name.startsWith('x-forwarded-'));
}

function requireAdminHeader(req) {
  if (req.headers['x-tacet-admin'] !== '1') {
    throw new GatewayError(403, 'invalid_admin_request', 'Use the Tacet admin application');
  }
}

async function readBody(req, limit) {
  if (Number(req.headers['content-length']) > limit) {
    req.resume();
    throw tooLarge();
  }
  let length = 0;
  const chunks = [];
  for await (const chunk of req.iterator({ destroyOnReturn: false })) {
    length += chunk.length;
    if (length > limit) {
      req.resume();
      throw tooLarge();
    }
    chunks.push(chunk);
  }
  return Buffer.concat(chunks, length);
}

function jsonValue(bytes) {
  try {
    return JSON.parse(bytes.toString('utf8'));
  } catch {
    throw invalid('Expected valid JSON');
  }
}

async function readJson(req, limit) {
  if (!/^application\/json(?:\s*;|$)/i.test(req.headers['content-type'] ?? '')) {
    throw new GatewayError(415, 'unsupported_media_type', 'Expected an application/json body');
  }
  return jsonValue(await readBody(req, limit));
}

async function textInput(req, expanded) {
  const value = await readJson(req, expanded ? expandedTextBodyLimit : 128 * 1024);
  if (!Array.isArray(value?.messages) || value.messages.length === 0 || value.messages.length > 24 ||
      !value.messages.every(message => textRoles.has(message?.role) && typeof message.content === 'string') ||
      !value.messages.some(message => message.role === 'user' && message.content.trim())) {
    throw invalid('Provide text messages including a user message');
  }
  if (value.stream === true) throw invalid('Use a non-streaming request');
  for (const message of value.messages) {
    if (message.role !== 'user' || !message.content.startsWith('SELECTED TEXT:\n')) continue;
    const end = message.content.lastIndexOf('\n\nSPOKEN:\n');
    const selected = message.content.slice('SELECTED TEXT:\n'.length, end < 0 ? undefined : end);
    if (selectionWords(selected) > selectionWordLimit) {
      throw new GatewayError(413, 'selection_too_long', `The selected text is too long. Tacet edits up to ${selectionWordLimit} words at a time.`);
    }
  }
  const maxTokens = value.max_completion_tokens ?? value.max_tokens ?? 2048;
  const maxCompletion = expanded ? 32_768 : 4_096;
  if (!Number.isInteger(maxTokens) || maxTokens < 1 || maxTokens > maxCompletion) {
    throw invalid(`The token limit must be between 1 and ${maxCompletion}`);
  }
  if (expanded && value.messages.reduce((sum, message) => sum + Buffer.byteLength(message.content) + 16, maxTokens) > expandedTextContext) {
    throw new GatewayError(413, 'selection_context', 'The document and its requested output exceed the available context');
  }
  const input = {
    messages: value.messages.map(({ role, content }) => ({ role, content })),
    max_tokens: maxTokens,
  };
  if (typeof value.temperature === 'number' && value.temperature >= 0 && value.temperature <= 2) {
    input.temperature = value.temperature;
  }
  return input;
}

async function audioInput(req) {
  const type = req.headers['content-type'] ?? '';
  let inputAudio, language, format;
  if (/^multipart\/form-data\s*;/i.test(type)) {
    const bytes = await readBody(req, multipartAudioLimit);
    let form;
    try {
      form = await new Request('http://localhost/', {
        method: 'POST', headers: { 'content-type': type }, body: bytes,
      }).formData();
    } catch {
      throw invalid('Invalid multipart audio');
    }
    const file = form.get('file');
    if (!(file instanceof File) || file.size === 0) throw invalid('Provide an audio file');
    if (file.size > audioLimit) throw tooLarge();
    const extension = file.name.toLowerCase().split('.').pop();
    if (!audioFormats.has(extension)) throw invalid('Unsupported audio format');
    inputAudio = { data: Buffer.from(await file.arrayBuffer()).toString('base64'), format: extension };
    language = form.get('language');
    format = form.get('response_format');
  } else {
    const value = await readJson(req, jsonAudioLimit);
    inputAudio = value?.input_audio;
    language = value?.language;
    format = value?.response_format;
    if (!audioFormats.has(inputAudio?.format) || typeof inputAudio.data !== 'string' ||
        inputAudio.data.length === 0 || inputAudio.data.length % 4 !== 0 || !/^[A-Za-z0-9+/]+=*$/.test(inputAudio.data)) {
      throw invalid('Provide valid base64 audio and its format');
    }
    const decoded = Buffer.from(inputAudio.data, 'base64');
    if (decoded.length > audioLimit) throw tooLarge();
    if (decoded.toString('base64') !== inputAudio.data) throw invalid('Invalid base64 audio');
  }
  if (language && (typeof language !== 'string' || !/^[a-z]{2,3}$/i.test(language))) {
    throw invalid('Provide an ISO language code');
  }
  if (format && !['json', 'verbose_json'].includes(format)) throw invalid('Use json or verbose_json');
  return {
    input_audio: { data: inputAudio.data, format: inputAudio.format },
    ...(language && { language: language.toLowerCase() }), ...(format && { response_format: format }),
  };
}

function reservedAudioBytes(req) {
  const limit = /^multipart\/form-data\s*;/i.test(req.headers['content-type'] ?? '') ? multipartAudioLimit : jsonAudioLimit;
  const declared = Number(req.headers['content-length']);
  return Number.isSafeInteger(declared) && declared >= 0 ? Math.min(declared, limit) : limit;
}

function send(res, status, data) {
  res.writeHead(status, { 'content-type': 'application/json; charset=utf-8' });
  res.end(JSON.stringify(data));
}

export function createGateway({ configPath, registryPath, usagePath, pilotAccounts, emailLogin, adminToken, clientToken,
  apiKey, groqKey, ollamaKey, fetchUpstream, now, cooldown, timeouts,
  maxInFlight = 8, maxAudioBytesInFlight = 24 * 1024 * 1024, localAdmin = false }) {
  const credentials = { openrouter: apiKey?.trim(), groq: groqKey?.trim(), ollama: ollamaKey?.trim() };
  const connections = Object.fromEntries(Object.entries(credentials).map(([name, key]) => [name, Boolean(key)]));
  const configured = Object.values(connections).some(Boolean);
  const validToken = (token, min) => typeof token === 'string' && token.length >= min && /^[\x21-\x7e]+$/.test(token);
  if (!validToken(adminToken, localAdmin ? 8 : 24) ||
      (clientToken !== undefined && !validToken(clientToken, 24)) || adminToken === clientToken) {
    throw new TypeError('Invalid gateway credentials / Некоректні ключі шлюзу');
  }
  const store = openRouteStore(configPath);
  const managed = Boolean(emailLogin);
  const usage = openClientUsage({ registryPath, databasePath: usagePath, clientToken, adminToken, managed, now });
  const accountPlans = openAccountPlans({ path: usagePath, pilotAccounts, managed, now });
  let accounts;
  const login = emailLogin && openAccountLogin({ ...emailLogin, path: usagePath, now,
    isBlocked: account => Boolean(accounts?.isBlocked(account)) });
  // The user console needs the account tables, so it exists only where email sign-in does.
  // Адмінці користувачів потрібні таблиці акаунтів, тож вона є лише там, де є вхід за поштою.
  accounts = login && accountPlans ? openAccountAdmin({ path: usagePath, now }) : undefined;
  const trustedLoginProxies = new Set(emailLogin?.trustedProxies);
  const identify = req => {
    const client = login?.identify(req.headers.authorization) ?? usage.identify(req.headers.authorization);
    if (client?.account) accounts?.guard(client.account);
    return client;
  };
  const router = createRouter({ store, credentials, fetchUpstream, now, cooldown, timeouts });
  const sessions = createAdminSessions({ secure: !localAdmin, now });
  const snapshot = () => ({ ...store.get(), health: router.health(), configured, connections, accounts: Boolean(accounts) });
  let inFlight = 0;
  let audioBytesInFlight = 0;
  let expandedTextInFlight = 0;

  const server = createServer({ requestTimeout: 30_000, headersTimeout: 10_000, keepAliveTimeout: 5_000 }, async (req, res) => {
    const path = req.url?.split('?')[0];
    res.setHeader('cache-control', 'no-store');
    res.setHeader('x-content-type-options', 'nosniff');
    res.setHeader('referrer-policy', 'no-referrer');
    res.setHeader('content-security-policy', "default-src 'none'; script-src 'self'; style-src 'self'; connect-src 'self'; frame-ancestors 'none'; base-uri 'none'; form-action 'none'");
    try {
      if (localAdmin && (path === '/admin' || path?.startsWith('/admin/')) && !localAdminRequest(req)) {
        throw new GatewayError(403, 'local_admin', 'The local admin is restricted to the local machine');
      }
      if (req.method === 'GET' && ['/', '/admin'].includes(path)) {
        res.writeHead(302, { location: '/admin/' }).end();
        return;
      }
      if (req.method === 'GET' && assets.has(path)) {
        const [bytes, type] = assets.get(path);
        res.writeHead(200, { 'content-type': type }).end(bytes);
        return;
      }
      if (req.method === 'GET' && path === '/healthz') return send(res, 200, { ok: true });

      if (login && req.method === 'GET' && path === '/v1/auth/status') return send(res, 200, { enabled: true });
      if (login && req.method === 'POST' && path === '/v1/auth/code') {
        const input = await readJson(req, 1024);
        const remote = req.socket.remoteAddress ?? '';
        const forwarded = req.headers['x-real-ip'];
        const source = trustedLoginProxies.has(remote) && typeof forwarded === 'string' && isIP(forwarded) ? forwarded : remote;
        return send(res, 200, await login.start(input?.email, source));
      }
      if (login && req.method === 'POST' && path === '/v1/auth/verify') {
        const input = await readJson(req, 2048);
        const result = login.verify(input);
        if (result.token && accounts && input?.transition === true && input.platform === 'macos') {
          const client = login.identify(`Bearer ${result.token}`);
          if (client) result.gift = accounts.welcomeBack(client.account, client.device);
        }
        return send(res, result.ticket ? 409 : 200, result);
      }
      if (login && req.method === 'POST' && path === '/v1/auth/device') {
        return send(res, 200, login.replace(await readJson(req, 1024)));
      }
      if (login && accounts && req.method === 'DELETE' && path === '/v1/account') {
        const client = login.identify(req.headers.authorization);
        if (!client) throw new GatewayError(401, 'unauthorized', 'Device sign-in is required');
        // A blocked account has to go through support, so a block cannot be shed by deleting.
        // Заблокований акаунт звертається до підтримки, щоб блокування не можна було зняти видаленням.
        accounts.guard(client.account);
        return send(res, 200, accounts.removeOwn(client.account, await readJson(req, 1024)));
      }
      if (login && ((req.method === 'GET' && path === '/v1/account/devices') ||
          (req.method === 'DELETE' && path?.startsWith('/v1/account/devices/')))) {
        const client = login.identify(req.headers.authorization);
        if (!client) throw new GatewayError(401, 'unauthorized', 'Device sign-in is required');
        accounts?.guard(client.account);
        return send(res, 200, req.method === 'GET' ? login.devices(client) : login.revoke(client, path.split('/').at(-1)));
      }

      if (req.method === 'GET' && path === '/v1/models') {
        if (!identify(req)) throw new GatewayError(401, 'unauthorized', 'Client token required');
        const { routes } = store.get();
        const data = Object.entries(clientModels)
          .filter(([kind]) => routes[kind].some(route => route.enabled && connections[route.connection]))
          .map(([, id]) => ({ id, object: 'model', owned_by: 'tacet' }));
        return send(res, 200, { object: 'list', data });
      }

      if (path === '/v1/account/plan' && accountPlans && ['GET', 'PUT'].includes(req.method)) {
        const client = identify(req);
        if (!client) throw new GatewayError(401, 'unauthorized', 'Client token required');
        if (req.method === 'GET') return send(res, 200, accountPlans.get(client));
        const input = await readJson(req, 1024);
        return send(res, 200, accountPlans.select(client, input?.plan));
      }

      if (path === '/admin/api/session') {
        if (req.method === 'POST') {
          requireAdminHeader(req);
          const input = await readJson(req, 2 * 1024);
          if (!keysMatch(input?.key, adminToken)) throw new GatewayError(401, 'unauthorized', 'Administrator key required');
          sessions.open(req, res);
          return send(res, 200, snapshot());
        }
        if (req.method === 'DELETE') {
          requireAdminHeader(req);
          sessions.close(req, res);
          return send(res, 200, { ok: true });
        }
      }

      if (path === '/admin/api/routes') {
        if (!allowed(req, adminToken)) {
          if (!sessions.has(req)) throw new GatewayError(401, 'unauthorized', 'Administrator session required');
          if (req.method === 'PUT') requireAdminHeader(req);
        }
        if (req.method === 'GET') return send(res, 200, snapshot());
        if (req.method === 'PUT') {
          const update = await readJson(req, 16 * 1024);
          try {
            store.save(update);
          } catch (error) {
            if (error instanceof ConfigConflict) throw new GatewayError(409, 'configuration_changed', 'Configuration changed');
            if (error instanceof TypeError) throw invalid('Invalid route configuration');
            throw error;
          }
          return send(res, 200, snapshot());
        }
      }

      if (accounts && (path === '/admin/api/users' || path?.startsWith('/admin/api/users/'))) {
        const change = req.method !== 'GET';
        if (!allowed(req, adminToken)) {
          if (!sessions.has(req)) throw new GatewayError(401, 'unauthorized', 'Administrator session required');
          if (change) requireAdminHeader(req);
        }
        const parts = path.slice('/admin/api/users'.length).split('/').slice(1);
        if (parts.length > 3 || parts.some(part => !/^[A-Za-z0-9_.-]{1,80}$/.test(part))) throw new GatewayError(404, 'not_found', 'Not found');
        const [account, action, item] = parts;
        if (!change) {
          if (!account) return send(res, 200, accounts.list(Object.fromEntries(new URL(req.url, 'http://gateway').searchParams)));
          if (account === 'summary' && !action) return send(res, 200, accounts.summary());
          if (!action) return send(res, 200, accounts.detail(account));
        } else if (account) {
          const input = await readJson(req, 2 * 1024);
          if (req.method === 'POST' && action === 'plan' && !item) return send(res, 200, accounts.setPlan(account, input));
          if (req.method === 'POST' && action === 'allowance' && !item) return send(res, 200, accounts.grantMinutes(account, input));
          if (req.method === 'POST' && action === 'block' && !item) return send(res, 200, accounts.block(account, input));
          if (req.method === 'POST' && action === 'unblock' && !item) return send(res, 200, accounts.unblock(account, input));
          if (req.method === 'POST' && action === 'payments' && !item) return send(res, 200, accounts.recordPayment(account, input));
          if (req.method === 'POST' && action === 'devices' && item) return send(res, 200, accounts.revokeDevice(account, item, input));
          if (req.method === 'POST' && action === 'delete' && !item) return send(res, 200, accounts.remove(account, input));
        }
        throw new GatewayError(404, 'not_found', 'Not found');
      }

      const kind = { '/v1/chat/completions': 'text', '/v1/audio/transcriptions': 'audio' }[path];
      if (req.method === 'POST' && ['text', 'audio'].includes(kind)) {
        const client = identify(req);
        if (!client) throw new GatewayError(401, 'unauthorized', 'Client token required');
        const audioBytes = kind === 'audio' ? reservedAudioBytes(req) : 0;
        const expanded = kind === 'text' && req.headers['x-tacet-operation'] === 'selection-edit';
        if (inFlight >= maxInFlight || audioBytesInFlight + audioBytes > maxAudioBytesInFlight || (expanded && expandedTextInFlight >= 2)) {
          throw new GatewayError(429, 'gateway_busy', 'Gateway is at capacity', { retryAfter: 1000 });
        }
        inFlight++;
        audioBytesInFlight += audioBytes;
        if (expanded) expandedTextInFlight++;
        const controller = new AbortController();
        res.once('close', () => controller.abort());
        try {
          const input = await (kind === 'audio' ? audioInput(req) : textInput(req, expanded));
          const onAttempt = usage.record ? attempt => usage.record(client, kind, attempt) : undefined;
          const settle = accountPlans?.reserve(client, kind, input, req.headers['x-tacet-onboarding'] === '1');
          let reply;
          try {
            reply = await router.forward(kind, input, controller.signal, { onAttempt, expanded });
          } finally {
            settle?.(reply);
          }
          return send(res, 200, reply);
        } finally {
          inFlight--;
          audioBytesInFlight -= audioBytes;
          if (expanded) expandedTextInFlight--;
        }
      }

      throw new GatewayError(404, 'not_found', 'Route not found');
    } catch (error) {
      if (res.destroyed) return;
      req.resume();
      if (!(error instanceof GatewayError)) {
        console.error('Gateway request failed / Помилка запиту шлюзу', error.code ?? error.name);
        return send(res, 500, { error: { code: 'internal_error', message: 'Gateway request failed' } });
      }
      if (error.retryAfter > 0) res.setHeader('retry-after', String(Math.ceil(error.retryAfter / 1000)));
      send(res, error.status, { error: { code: error.code, message: error.message } });
    }
  });
  if (usage.close) server.once('close', usage.close);
  if (accountPlans) server.once('close', accountPlans.close);
  if (login) server.once('close', login.close);
  if (accounts) server.once('close', accounts.close);
  return server;
}
