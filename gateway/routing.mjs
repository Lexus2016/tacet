const bases = {
  openrouter: 'https://openrouter.ai/api/v1',
  groq: 'https://api.groq.com/openai/v1',
  ollama: 'https://ollama.com/v1',
};
const operations = { text: 'chat/completions', audio: 'audio/transcriptions' };
const providerReplyLimit = 2 * 1024 * 1024;

export class GatewayError extends Error {
  constructor(status, code, message, { retryable = false, retryAfter = 0, shared = false } = {}) {
    super(message);
    Object.assign(this, { status, code, retryable, retryAfter, shared });
  }
}

function retryDelay(header, now) {
  if (!header) return 0;
  const seconds = Number(header);
  const ms = Number.isFinite(seconds) ? seconds * 1000 : Date.parse(header) - now;
  return Number.isFinite(ms) ? Math.max(0, Math.min(ms, 15 * 60_000)) : 0;
}

function upstreamError(response, now) {
  const backoff = retryDelay(response.headers.get('retry-after'), now);
  if ([401, 402, 403].includes(response.status)) {
    return new GatewayError(503, `upstream_${response.status}`, 'Provider rejected credentials, access or credits', {
      shared: true, retryAfter: backoff,
    });
  }
  if ([400, 413, 415, 422].includes(response.status)) {
    return new GatewayError(400, 'invalid_upstream_input', 'Provider rejected the supplied input');
  }
  if ([404, 408, 429].includes(response.status) || response.status >= 500) {
    return new GatewayError(503, `upstream_${response.status}`, 'The selected route did not respond successfully', {
      retryable: true, retryAfter: backoff,
    });
  }
  return new GatewayError(502, 'upstream_error', 'Unexpected provider response');
}

function validReply(kind, data, expanded) {
  if (kind === 'audio') return typeof data?.text === 'string';
  const choice = data?.choices?.[0];
  return typeof choice?.message?.content === 'string' && Boolean(choice.message.content.trim()) &&
    (!expanded || choice.finish_reason === 'stop') &&
    !['length', 'content_filter', 'error'].includes(choice.finish_reason);
}

async function readProviderReply(response) {
  const tooLarge = () => new GatewayError(502, 'reply_too_large', 'Provider response exceeds the size limit', { retryable: true });
  if (Number(response.headers.get('content-length')) > providerReplyLimit) {
    await response.body?.cancel();
    throw tooLarge();
  }
  const chunks = [];
  let length = 0;
  for await (const chunk of response.body ?? []) {
    length += chunk.length;
    if (length > providerReplyLimit) throw tooLarge();
    chunks.push(chunk);
  }
  return JSON.parse(Buffer.concat(chunks, length).toString('utf8'));
}

function upstreamRequest(kind, route, input, key, expanded) {
  const headers = { authorization: `Bearer ${key}` };
  const url = `${bases[route.connection]}/${operations[kind]}`;
  if (kind === 'audio' && route.connection === 'groq') {
    const body = new FormData();
    const { data, format } = input.input_audio;
    body.set('file', new Blob([Buffer.from(data, 'base64')]), `audio.${format}`);
    body.set('model', route.model);
    if (input.language) body.set('language', input.language);
    if (input.response_format) body.set('response_format', input.response_format);
    return { url, headers, body };
  }
  const payload = { ...input, model: route.model };
  if (route.connection === 'openrouter' && route.provider) {
    payload.provider = { only: [route.provider], allow_fallbacks: false };
  }
  if (kind === 'text') {
    payload.stream = false;
    if (expanded && route.connection === 'openrouter' && route.model === 'openai/gpt-oss-120b') {
      payload.reasoning = { effort: 'low', exclude: true };
    }
    if (route.connection === 'groq') {
      payload.max_completion_tokens = payload.max_tokens;
      delete payload.max_tokens;
    }
  }
  headers['content-type'] = 'application/json';
  return { url, headers, body: JSON.stringify(payload) };
}

export function createRouter({ store, credentials, fetchUpstream = fetch, now = Date.now, cooldown = 30_000,
  timeouts = { text: 6_000, audio: 8_000 } }) {
  const health = new Map();
  const verifying = new Set();
  const expandedHealth = new Map();
  const expandedVerifying = new Set();
  const connectionBackoffs = new Map();

  function record(states, route, previous, changed) {
    states.set(route.id, { successes: 0, failures: 0, cost: 0, metered: 0, ...previous, ...changed });
  }

  return {
    health() {
      return Object.fromEntries([...health].map(([id, status]) => [id, {
        ...status,
        state: verifying.has(id) ? 'checking' : status.until > now() ? 'cooldown' :
          status.state === 'cooldown' ? 'waiting' : status.state,
      }]));
    },
    async forward(kind, input, signal, { onAttempt, expanded = false } = {}) {
      if (!Object.values(credentials).some(Boolean)) {
        throw new GatewayError(503, 'providers_unconfigured', 'Provider credentials are not configured');
      }
      let earliest = Infinity;
      let connectionRetry = Infinity;
      let sharedError;
      let outputLimit;
      const states = expanded ? expandedHealth : health;
      const probes = expanded ? expandedVerifying : verifying;
      const blocked = new Set();
      const deadline = AbortSignal.timeout(expanded ? 140_000 : 20_000);
      for (const route of store.get().routes[kind]) {
        signal.throwIfAborted();
        if (deadline.aborted) break;
        const key = credentials[route.connection];
        if (!route.enabled || !key || blocked.has(route.connection)) continue;
        if (kind === 'audio' && route.connection === 'groq' && input.input_audio.format === 'aac') continue;
        const connection = connectionBackoffs.get(route.connection);
        if (connection && (connection.until > now() || connection.checking)) {
          sharedError ??= connection.error;
          connectionRetry = Math.min(connectionRetry, Math.max(connection.until, now() + 1_000));
          continue;
        }
        const previous = states.get(route.id);
        if (previous?.until > now()) {
          earliest = Math.min(earliest, previous.until);
          continue;
        }
        const retrying = previous?.state === 'cooldown';
        if (retrying && probes.has(route.id)) continue;
        if (retrying) probes.add(route.id);
        if (connection) connection.checking = true;
        const start = now();
        const requestSignal = AbortSignal.any([signal, deadline, AbortSignal.timeout(expanded ? 105_000 : timeouts[kind])]);
        let data;
        let attempted = false;
        let completed = false;
        try {
          const { url, headers, body } = upstreamRequest(kind, route, input, key, expanded);
          attempted = true;
          const response = await fetchUpstream(url, { method: 'POST', headers, body, redirect: 'error', signal: requestSignal });
          if (!response.ok) {
            await response.body?.cancel();
            throw upstreamError(response, now());
          }
          try {
            data = await readProviderReply(response);
          } catch (error) {
            requestSignal.throwIfAborted();
            if (error instanceof GatewayError) throw error;
            throw new GatewayError(502, 'invalid_reply', 'Provider returned invalid JSON', { retryable: true });
          }
          if (kind === 'text' && data?.choices?.[0]?.finish_reason === 'length') {
            // The output cap belongs to this request, not route health.
            // Межа відповіді стосується цього запиту, а не стану маршруту.
            outputLimit = new GatewayError(422, 'output_limit', 'The text result exceeded the requested output limit');
            if (!expanded) throw outputLimit;
            continue;
          }
          if (kind === 'text' && data?.choices?.[0]?.finish_reason === 'content_filter') {
            throw new GatewayError(422, 'content_filtered', 'The provider did not return a text result for this request');
          }
          if (!validReply(kind, data, expanded)) {
            throw new GatewayError(502, 'invalid_reply', 'Provider returned an incomplete result', { retryable: true });
          }
          const last = states.get(route.id);
          const newerFailure = last && last.state !== 'ready' && last.failures !== (previous?.failures ?? 0);
          const cost = data.usage?.cost;
          const metered = Number.isFinite(cost) && cost >= 0;
          record(states, route, last, {
            ...(newerFailure ? {} : { state: 'ready', until: 0, reason: null, checkedAt: now(), latency: now() - start }),
            successes: (last?.successes ?? 0) + 1, cost: (last?.cost ?? 0) + (metered ? cost : 0),
            metered: (last?.metered ?? 0) + Number(metered),
          });
          if (connection && connectionBackoffs.get(route.connection) === connection) {
            connectionBackoffs.delete(route.connection);
          }
          completed = true;
          return data;
        } catch (error) {
          signal.throwIfAborted();
          if (deadline.aborted) break;
          const failure = error instanceof GatewayError ? error : new GatewayError(503,
            requestSignal.aborted ? 'timeout' : 'network', 'The selected route could not be reached', { retryable: true });
          if (failure.status === 400 || failure.status === 422) throw failure;
          const last = states.get(route.id);
          const until = failure.retryable ? now() + Math.max(cooldown, failure.retryAfter) : 0;
          const keepLongerDelay = last?.state === 'cooldown' && last.until > until && last.until > now();
          record(states, route, last, {
            ...(keepLongerDelay ? {} : {
              state: failure.retryable ? 'cooldown' : 'failed', until, reason: failure.code,
              checkedAt: now(), latency: now() - start,
            }),
            failures: (last?.failures ?? 0) + 1,
          });
          if (failure.shared) {
            blocked.add(route.connection);
            sharedError ??= failure;
            // Authentication and balance affect the entire credential. A 403 can be request-specific.
            // Помилки ключа й балансу спільні для підключення. Відмова 403 може стосуватися лише запиту.
            if (failure.code === 'upstream_401' || failure.code === 'upstream_402') {
              const resumeAt = Math.max(connectionBackoffs.get(route.connection)?.until ?? 0,
                now() + Math.max(cooldown, failure.retryAfter));
              connectionBackoffs.set(route.connection, { until: resumeAt, error: failure });
              connectionRetry = Math.min(connectionRetry, resumeAt);
            }
            continue;
          }
          if (!failure.retryable) throw failure;
          earliest = Math.min(earliest, keepLongerDelay ? last.until : until);
        } finally {
          if (attempted) onAttempt?.({ route, data, completed, started: start });
          if (retrying) probes.delete(route.id);
          if (connection) connection.checking = false;
        }
      }
      if (deadline.aborted) throw new GatewayError(503, 'gateway_timeout', 'Gateway exceeded the request deadline');
      if (outputLimit) throw outputLimit;
      if (sharedError && !Number.isFinite(earliest)) {
        if (!Number.isFinite(connectionRetry)) throw sharedError;
        throw new GatewayError(sharedError.status, sharedError.code, sharedError.message,
          { retryAfter: Math.max(0, connectionRetry - now()) });
      }
      const retryAt = Math.min(earliest, connectionRetry);
      throw new GatewayError(503, 'no_route', 'No enabled route is available for this operation', {
        retryAfter: Number.isFinite(retryAt) ? Math.max(0, retryAt - now()) : 0,
      });
    },
  };
}
