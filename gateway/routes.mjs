import { mkdirSync, readFileSync, renameSync, rmSync, writeFileSync } from 'node:fs';
import { dirname } from 'node:path';
import { randomUUID } from 'node:crypto';

const textModel = 'openai/gpt-oss-120b';
const whisperModel = 'openai/whisper-large-v3';
export const catalog = Object.freeze({
  text: Object.freeze([
    { id: 'text-groq', label: 'Groq', model: textModel, connection: 'openrouter', provider: 'groq' },
    { id: 'text-bedrock', label: 'Amazon Bedrock', model: textModel, connection: 'openrouter', provider: 'amazon-bedrock' },
    { id: 'text-cerebras', label: 'Cerebras', model: textModel, connection: 'openrouter', provider: 'cerebras' },
    { id: 'text-groq-direct', label: 'Groq напряму', model: textModel, connection: 'groq', defaultEnabled: false },
    { id: 'text-ollama-cloud', label: 'Ollama Cloud', model: 'gpt-oss:120b', connection: 'ollama', defaultEnabled: false },
  ]),
  audio: Object.freeze([
    { id: 'audio-whisper', label: 'Groq', model: whisperModel, connection: 'openrouter', provider: 'groq' },
    { id: 'audio-whisper-together', label: 'Together', model: whisperModel, connection: 'openrouter', provider: 'together', allowMissingOnUpgrade: true },
    { id: 'audio-turbo', label: 'Whisper Large V3 Turbo', model: 'openai/whisper-large-v3-turbo', connection: 'openrouter', defaultEnabled: false },
    { id: 'audio-groq-direct', label: 'Groq напряму', model: 'whisper-large-v3', connection: 'groq', defaultEnabled: false },
  ]),
});

export class ConfigConflict extends Error {}

function validate(config, migrate = false) {
  if (!Number.isSafeInteger(config?.revision) || config.revision < 1) {
    throw new TypeError('Invalid configuration revision / Некоректна редакція налаштувань');
  }
  const routes = {};
  let migrated = false;
  for (const [kind, available] of Object.entries(catalog)) {
    const remaining = new Set(available.map(route => route.id));
    if (!Array.isArray(config.routes?.[kind])) {
      throw new TypeError('Invalid route list / Некоректний список маршрутів');
    }
    routes[kind] = config.routes[kind].map(route => {
      if (!remaining.delete(route?.id) || typeof route.enabled !== 'boolean') {
        throw new TypeError('Invalid route entry / Некоректний запис маршруту');
      }
      return { id: route.id, enabled: route.enabled };
    });
    for (const route of available.filter(({ id }) => remaining.has(id))) {
      if (!migrate || (route.defaultEnabled !== false && !route.allowMissingOnUpgrade)) {
        throw new TypeError('Missing route / Відсутній маршрут');
      }
      routes[kind].push({ id: route.id, enabled: false });
      migrated = true;
    }
  }
  return { revision: config.revision + Number(migrated), routes };
}

export function openRouteStore(filePath) {
  let state;
  try {
    state = validate(JSON.parse(readFileSync(filePath, 'utf8')), true);
  } catch (error) {
    if (error.code !== 'ENOENT') throw error;
    state = {
      revision: 1,
      routes: Object.fromEntries(Object.entries(catalog).map(([kind, routes]) => [
        kind, routes.map(({ id, defaultEnabled = true }) => ({ id, enabled: defaultEnabled })),
      ])),
    };
  }

  return {
    get() {
      return {
        revision: state.revision,
        routes: Object.fromEntries(Object.entries(state.routes).map(([kind, routes]) => [
          kind, routes.map(route => ({ ...catalog[kind].find(item => item.id === route.id), ...route })),
        ])),
      };
    },
    save(update) {
      const validated = validate(update);
      if (validated.revision !== state.revision) throw new ConfigConflict();
      const next = { ...validated, revision: state.revision + 1 };
      mkdirSync(dirname(filePath), { recursive: true, mode: 0o700 });
      const temporary = `${filePath}.${randomUUID()}.tmp`;
      try {
        writeFileSync(temporary, `${JSON.stringify(next, null, 2)}\n`, { mode: 0o600, flag: 'wx', flush: true });
        renameSync(temporary, filePath);
      } catch (error) {
        rmSync(temporary, { force: true });
        throw error;
      }
      state = next;
      return this.get();
    },
  };
}
