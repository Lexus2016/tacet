import { mkdirSync, readFileSync, renameSync, rmSync, writeFileSync } from 'node:fs';
import { dirname } from 'node:path';
import { randomUUID } from 'node:crypto';

// Models each route may use. The first entry is the default. Only models checked against the
// provider on 2026-11-27 are listed: a model the provider does not serve would turn a route red.
// Моделі, які може використовувати маршрут. Перша — типова. Перелік містить лише моделі, перевірені
// в провайдера 27.11.2026: модель, якої провайдер не обслуговує, зробила б маршрут неробочим.
const model = (id, label) => Object.freeze({ id, label });
const gptOss120 = model('openai/gpt-oss-120b', 'GPT-OSS 120B');
const gptOss20 = model('openai/gpt-oss-20b', 'GPT-OSS 20B');
const whisperV3 = model('openai/whisper-large-v3', 'Whisper Large V3');
const whisperTurbo = model('openai/whisper-large-v3-turbo', 'Whisper Large V3 Turbo');
const groqV3 = model('whisper-large-v3', 'Whisper Large V3');
const groqTurbo = model('whisper-large-v3-turbo', 'Whisper Large V3 Turbo');
const route = (spec, models) => Object.freeze({ ...spec, model: models[0].id, models: Object.freeze(models) });

export const catalog = Object.freeze({
  text: Object.freeze([
    route({ id: 'text-groq', label: 'Groq', connection: 'openrouter', provider: 'groq' }, [gptOss120, gptOss20]),
    route({ id: 'text-bedrock', label: 'Amazon Bedrock', connection: 'openrouter', provider: 'amazon-bedrock' }, [gptOss120, gptOss20]),
    route({ id: 'text-cerebras', label: 'Cerebras', connection: 'openrouter', provider: 'cerebras' }, [gptOss120]),
    route({ id: 'text-groq-direct', label: 'Groq напряму', connection: 'groq', defaultEnabled: false }, [gptOss120, gptOss20]),
    route({ id: 'text-ollama-cloud', label: 'Ollama Cloud', connection: 'ollama', defaultEnabled: false },
      [model('gpt-oss:120b', 'GPT-OSS 120B'), model('gpt-oss:20b', 'GPT-OSS 20B')]),
  ]),
  audio: Object.freeze([
    route({ id: 'audio-whisper', label: 'Groq', connection: 'openrouter', provider: 'groq' }, [whisperV3, whisperTurbo]),
    route({ id: 'audio-whisper-together', label: 'Together', connection: 'openrouter', provider: 'together', allowMissingOnUpgrade: true }, [whisperV3]),
    route({ id: 'audio-turbo', label: 'OpenRouter, будь-який провайдер', connection: 'openrouter', defaultEnabled: false }, [whisperTurbo, whisperV3]),
    route({ id: 'audio-groq-direct', label: 'Groq напряму', connection: 'groq', defaultEnabled: false }, [groqV3, groqTurbo]),
  ]),
});

// A user-added backup route is a copy of a catalog route with another model from its list.
// Резервний маршрут, доданий користувачем, — копія маршруту з каталогу з іншою моделлю зі списку.
const extraRoute = /^x-[0-9a-f]{8}$/;
const maxExtraRoutes = 6;

export class ConfigConflict extends Error {}

function validate(config, migrate = false) {
  if (!Number.isSafeInteger(config?.revision) || config.revision < 1) {
    throw new TypeError('Invalid configuration revision / Некоректна редакція налаштувань');
  }
  const routes = {};
  let migrated = false;
  for (const [kind, available] of Object.entries(catalog)) {
    const remaining = new Set(available.map(item => item.id));
    if (!Array.isArray(config.routes?.[kind])) {
      throw new TypeError('Invalid route list / Некоректний список маршрутів');
    }
    const seen = new Set();
    const targets = new Set();
    let extras = 0;
    routes[kind] = config.routes[kind].map(route => {
      if (typeof route?.id !== 'string' || typeof route.enabled !== 'boolean' || seen.has(route.id)) {
        throw new TypeError('Invalid route entry / Некоректний запис маршруту');
      }
      seen.add(route.id);
      const copy = extraRoute.test(route.id);
      const spec = available.find(item => item.id === (copy ? route.base : route.id));
      if (!spec || (copy ? ++extras > maxExtraRoutes : !remaining.delete(route.id))) {
        throw new TypeError('Invalid route entry / Некоректний запис маршруту');
      }
      // Only a model from the route's own list can be chosen; everything else the client sends is ignored.
      // Обирати можна лише модель зі списку самого маршруту; решту, що надсилає клієнт, ігноруємо.
      const choice = route.selection ?? undefined;
      if (choice !== undefined && !spec.models.some(item => item.id === choice)) {
        throw new TypeError('Invalid model choice / Некоректний вибір моделі');
      }
      const target = `${spec.connection}|${spec.provider ?? ''}|${choice ?? spec.model}`;
      if (targets.has(target)) throw new TypeError('Duplicate model route / Дубль маршруту моделі');
      targets.add(target);
      const entry = { id: route.id, enabled: route.enabled };
      if (copy) Object.assign(entry, { base: spec.id, selection: choice ?? spec.model });
      else if (choice !== undefined && choice !== spec.model) entry.selection = choice;
      return entry;
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

function describe(kind, route) {
  const spec = catalog[kind].find(item => item.id === (route.base ?? route.id));
  const chosen = spec.models.find(item => item.id === (route.selection ?? spec.model));
  return {
    ...spec, id: route.id, enabled: route.enabled, model: chosen.id,
    ...(route.selection && { selection: route.selection }),
    ...(route.base && { base: route.base, custom: true, label: `${spec.label} · ${chosen.label}` }),
  };
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
          kind, routes.map(route => describe(kind, route)),
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
