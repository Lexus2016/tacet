import { createUsers } from './users.js';

const login = document.querySelector('#login');
const opening = document.querySelector('#opening');
const loginForm = document.querySelector('#login-form');
const password = document.querySelector('#password');
const loginError = document.querySelector('#login-error');
const dashboard = document.querySelector('#dashboard');
const groups = document.querySelector('#groups');
const connection = document.querySelector('#connection');
const save = document.querySelector('#save');
const reload = document.querySelector('#reload');
const status = document.querySelector('#status');

const labels = {
  audio: ['Розпізнавання аудіо', 'Виберіть прямий Groq або одну з моделей з автоматичним вибором провайдера OpenRouter.'],
  text: ['Обробка тексту', 'Кожен маршрут використовує вказане підключення й модель.'],
};
const connectionNames = { openrouter: 'OpenRouter', groq: 'Groq API', ollama: 'Ollama API' };
const descriptions = {
  upstream_401: 'Провайдер відхилив ключ', upstream_402: 'Потрібно поповнити баланс',
  upstream_403: 'Провайдер відмовив у доступі', upstream_404: 'Модель або маршрут недоступні',
  upstream_408: 'Провайдер завершив запит через очікування',
  upstream_429: 'Ліміт запитів провайдера', timeout: 'Перевищено час очікування',
  network: 'Помилка зʼєднання', invalid_reply: 'Неповна або некоректна відповідь',
  upstream_error: 'Неочікувана відповідь провайдера',
};
const states = {
  off: 'Вимкнено', unconfigured: 'Потрібен ключ', unknown: 'Очікує запиту', ready: 'Працює',
  cooldown: 'Тимчасово пропущено', waiting: 'Готовий до повтору',
  checking: 'Перевіряється', failed: 'Потребує уваги',
};
const time = new Intl.DateTimeFormat('uk', { dateStyle: 'short', timeStyle: 'medium' });

let current;
let draft;
let busy = false;
let session = 0;
let polling = false;

async function api(method, data, path = 'api/routes') {
  const response = await fetch(path, {
    method,
    credentials: 'same-origin',
    headers: { 'x-tacet-admin': '1', ...(data && { 'content-type': 'application/json' }) },
    body: data && JSON.stringify(data),
  });
  if (!response.ok) throw Object.assign(new Error(), { status: response.status });
  return response.json();
}

function routeSettings(routes) {
  return Object.fromEntries(Object.entries(routes).map(([kind, routes]) => [
    kind, routes.map(({ id, enabled, selection, base }) => ({
      id, enabled, ...(selection && { selection }), ...(base && { base }),
    })),
  ]));
}

const modelLabel = (route, id) => route.models.find(model => model.id === id)?.label ?? id;
const unsaved = () => flash(changed() ? 'Є незбережені зміни' : '');

function changed() {
  return JSON.stringify(routeSettings(draft)) !== JSON.stringify(routeSettings(current.routes));
}

function flash(message, error = false) {
  status.textContent = message;
  status.classList.toggle('error', error);
}

function updateActions() {
  save.disabled = busy || !changed();
  reload.disabled = busy;
  save.textContent = busy ? 'Зачекайте…' : 'Зберегти зміни';
  for (const control of groups.querySelectorAll('input, button')) {
    control.disabled = busy || control.dataset.edge === 'true';
  }
}

function renderHealth() {
  const keys = Object.values(current.connections);
  connection.textContent = `Ключі провайдерів ${keys.filter(Boolean).length} з ${keys.length}`;
  connection.dataset.state = current.configured ? 'ready' : 'waiting';
  for (const row of groups.querySelectorAll('.route')) {
    const route = draft[row.dataset.kind].find(route => route.id === row.dataset.id);
    const result = current.health[route.id];
    const hasKey = current.connections[route.connection];
    const state = !route.enabled ? 'off' : !hasKey ? 'unconfigured' : result?.state ?? 'unknown';
    const badge = row.querySelector('.badge');
    badge.textContent = states[state];
    badge.dataset.state = state;
    const detail = row.querySelector('.detail');
    const code = result?.reason;
    const reason = /^upstream_5\d\d$/.test(code) ? `Помилка провайдера (${code.slice(-3)})` :
      descriptions[code] ?? '';
    const checked = Number.isFinite(result?.checkedAt) ? time.format(result.checkedAt) : '';
    const retry = state === 'cooldown' ? `до ${time.format(result.until)}` : '';
    detail.textContent = [!hasKey && !route.enabled && 'Потрібен ключ', reason, checked, retry].filter(Boolean).join(' · ');
    detail.hidden = !detail.textContent;
  }
}

function render() {
  const fragment = document.createDocumentFragment();
  for (const [kind, [name, description]] of Object.entries(labels)) {
    const group = document.querySelector('#group-template').content.cloneNode(true);
    group.querySelector('h2').textContent = name;
    group.querySelector('p').textContent = description;
    for (const [index, route] of draft[kind].entries()) {
      const row = document.querySelector('#route-template').content.firstElementChild.cloneNode(true);
      row.dataset.kind = kind;
      row.dataset.id = route.id;
      row.querySelector('.position').textContent = `${index + 1}`;
      row.querySelector('strong').textContent = route.label;
      const modelText = row.querySelector('.model');
      const choice = row.querySelector('.model-choice');
      modelText.textContent = `${connectionNames[route.connection]} · ${route.model}`;
      if (route.models.length > 1) {
        // A route with a single known model shows it as text; with several, the model can be chosen.
        // Маршрут з однією відомою моделлю показує її текстом; з кількома — модель можна обрати.
        modelText.textContent = connectionNames[route.connection];
        choice.hidden = false;
        choice.setAttribute('aria-label', `Модель для ${route.label}`);
        choice.replaceChildren(...route.models.map(model => new Option(model.label, model.id, false, model.id === route.model)));
        choice.addEventListener('change', () => {
          const base = route.custom ? draft[kind].find(item => item.id === route.base) : route;
          route.model = choice.value;
          if (route.custom) route.label = `${base.label} · ${modelLabel(route, choice.value)}`;
          // The first model of a route is its default and needs no saved choice.
          // Перша модель маршруту — типова, окремо її зберігати не треба.
          route.selection = route.custom || choice.value !== route.models[0].id ? choice.value : undefined;
          render();
          unsaved();
        });
      }
      const remove = row.querySelector('.remove');
      remove.hidden = !route.custom;
      remove.setAttribute('aria-label', `Прибрати ${route.label}`);
      remove.addEventListener('click', () => {
        draft[kind] = draft[kind].filter(item => item.id !== route.id);
        render();
        unsaved();
      });
      const checkbox = row.querySelector('input');
      checkbox.checked = route.enabled;
      checkbox.setAttribute('aria-label', `Увімкнути ${route.label}`);
      checkbox.addEventListener('change', () => {
        route.enabled = checkbox.checked;
        renderHealth();
        updateActions();
        unsaved();
      });
      for (const button of row.querySelectorAll('[data-move]')) {
        const offset = Number(button.dataset.move);
        const destination = index + offset;
        button.dataset.edge = String(destination < 0 || destination >= draft[kind].length);
        button.setAttribute('aria-label', `${offset < 0 ? 'Підняти' : 'Опустити'} ${route.label}`);
        button.addEventListener('click', () => {
          draft[kind].splice(index, 1);
          draft[kind].splice(destination, 0, route);
          render();
          const controls = groups.querySelector(`[data-id="${route.id}"] .controls`);
          (controls.querySelector(`[data-move="${offset}"]:enabled`) ?? controls.querySelector('button:enabled'))?.focus();
          unsaved();
        });
      }
      group.querySelector('ol').append(row);
    }
    group.querySelector('.group').append(addRouteForm(kind));
    fragment.append(group);
  }
  groups.replaceChildren(fragment);
  renderHealth();
  updateActions();
}

// Adds a backup route: another model from the list of one of the standard routes.
// Додає резервний маршрут: іншу модель зі списку одного зі стандартних маршрутів.
function addRouteForm(kind) {
  const form = document.querySelector('#add-template').content.firstElementChild.cloneNode(true);
  const bases = draft[kind].filter(route => !route.custom && route.models.length > 1);
  const baseSelect = form.querySelector('.add-base');
  const modelSelect = form.querySelector('.add-model');
  const fill = () => {
    const base = bases.find(route => route.id === baseSelect.value);
    modelSelect.replaceChildren(...(base?.models ?? []).map(model => new Option(model.label, model.id)));
  };
  baseSelect.replaceChildren(...bases.map(route => new Option(`${route.label} · ${connectionNames[route.connection]}`, route.id)));
  baseSelect.addEventListener('change', fill);
  fill();
  const extras = draft[kind].filter(route => route.custom).length;
  form.hidden = !bases.length;
  form.querySelector('button').disabled = extras >= 6;
  form.addEventListener('submit', event => {
    event.preventDefault();
    const base = bases.find(route => route.id === baseSelect.value);
    const model = modelSelect.value;
    if (!base || !model || busy) return;
    if (draft[kind].some(route => route.connection === base.connection && route.provider === base.provider && route.model === model)) {
      flash('Такий маршрут уже є в списку.', true);
      return;
    }
    const id = `x-${[...crypto.getRandomValues(new Uint8Array(4))].map(byte => byte.toString(16).padStart(2, '0')).join('')}`;
    const added = { ...base, id, base: base.id, custom: true, model, selection: model, enabled: true };
    added.label = `${base.label} · ${modelLabel(base, model)}`;
    draft[kind].push(added);
    render();
    unsaved();
  });
  return form;
}

// Unsaved changes survive a forced sign-out: they are kept for this tab and restored after signing
// in again, as long as nobody saved a newer configuration in the meantime.
// Незбережені зміни переживають примусовий вихід: їх тримаємо для цієї вкладки й відновлюємо після
// нового входу, якщо за цей час ніхто не зберіг новішу конфігурацію.
const draftKey = 'tacet.admin.routes.draft';

function stashDraft() {
  try {
    if (current && draft && changed()) sessionStorage.setItem(draftKey, JSON.stringify({ revision: current.revision, draft }));
  } catch {
    // Storage may be unavailable; the changes are then lost as before.
  }
}

function restoreDraft(revision) {
  try {
    const saved = JSON.parse(sessionStorage.getItem(draftKey) ?? 'null');
    sessionStorage.removeItem(draftKey);
    return saved?.revision === revision ? saved.draft : undefined;
  } catch {
    return undefined;
  }
}

function load(snapshot) {
  current = snapshot;
  draft = structuredClone(snapshot.routes);
  const kept = restoreDraft(snapshot.revision);
  if (kept) draft = kept;
  render();
  if (kept) flash('Незбережені зміни відновлено. Натисніть «Зберегти зміни».');
}

const tabs = document.querySelector('#tabs');
const views = { routes: document.querySelector('#routes-view'), users: document.querySelector('#users-view') };
const users = createUsers({
  root: document.querySelector('#users'), api,
  unauthorized: () => showLogin('Сеанс завершився. Увійдіть знову.'),
});

function showView(name) {
  for (const [id, view] of Object.entries(views)) view.hidden = id !== name;
  for (const tab of tabs.querySelectorAll('button')) tab.setAttribute('aria-pressed', String(tab.dataset.view === name));
  if (name === 'users') users.show();
}

for (const tab of tabs.querySelectorAll('button')) tab.addEventListener('click', () => showView(tab.dataset.view));

function showDashboard(snapshot) {
  load(snapshot);
  tabs.hidden = !snapshot.accounts;
  session++;
  opening.hidden = login.hidden = true;
  dashboard.hidden = connection.hidden = false;
}

function showLogin(message = '') {
  session++;
  stashDraft();
  current = draft = undefined;
  busy = false;
  users.reset();
  showView('routes');
  groups.replaceChildren();
  dashboard.hidden = connection.hidden = opening.hidden = true;
  login.hidden = false;
  loginError.textContent = message;
  loginError.hidden = !message;
  flash('');
}

loginForm.addEventListener('submit', async event => {
  event.preventDefault();
  const button = loginForm.querySelector('button');
  button.disabled = true;
  loginError.hidden = true;
  try {
    showDashboard(await api('POST', { key: password.value }, 'api/session'));
    password.value = '';
    document.querySelector('#logout').focus();
  } catch (error) {
    loginError.textContent = error.status === 401 ? 'Перевірте ключ адміністратора.' : 'Шлюз недоступний.';
    loginError.hidden = false;
  } finally {
    button.disabled = false;
  }
});

document.querySelector('#logout').addEventListener('click', async event => {
  const button = event.currentTarget;
  button.disabled = true;
  try {
    await api('DELETE', undefined, 'api/session');
    showLogin();
    password.focus();
  } catch {
    flash('Не вдалося завершити сеанс.', true);
  } finally {
    button.disabled = false;
  }
});

async function apply(method) {
  const expectedSession = session;
  busy = true;
  updateActions();
  try {
    const update = method === 'PUT' ? { revision: current.revision, routes: routeSettings(draft) } : undefined;
    const snapshot = await api(method, update);
    if (session !== expectedSession) return;
    load(snapshot);
    flash(method === 'PUT' ? 'Зміни збережено' : 'Стан оновлено');
  } catch (error) {
    if (session !== expectedSession) return;
    if (error.status === 401) return showLogin('Сеанс завершився. Увійдіть знову.');
    flash(error.status === 409 ? 'Налаштування змінилися в іншому вікні. Перечитайте їх.' : 'Шлюз не підтвердив операцію.', true);
  } finally {
    if (session === expectedSession) {
      busy = false;
      updateActions();
    }
  }
}

save.addEventListener('click', () => apply('PUT'));
reload.addEventListener('click', () => apply('GET'));

setInterval(async () => {
  if (!current || busy || polling || document.hidden) return;
  polling = true;
  const expectedSession = session;
  try {
    const snapshot = await api('GET');
    if (session !== expectedSession || busy || snapshot.revision < current.revision) return;
    if (!changed() && snapshot.revision !== current.revision) load(snapshot);
    else {
      current.health = snapshot.health;
      current.configured = snapshot.configured;
      current.connections = snapshot.connections;
      renderHealth();
    }
  } catch (error) {
    if (session !== expectedSession || busy) return;
    if (error.status === 401) return showLogin('Сеанс завершився. Увійдіть знову.');
    connection.textContent = 'Шлюз недоступний';
    connection.dataset.state = 'failed';
  } finally {
    polling = false;
  }
}, 5_000);

api('GET').then(showDashboard).catch(error => showLogin(error.status === 401 ? '' : 'Шлюз недоступний.'));
