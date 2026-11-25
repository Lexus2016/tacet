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

async function api(method, data, path = '/admin/api/routes') {
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
    kind, routes.map(({ id, enabled }) => ({ id, enabled })),
  ]));
}

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
      row.querySelector('.model').textContent = `${connectionNames[route.connection]} · ${route.model}`;
      const checkbox = row.querySelector('input');
      checkbox.checked = route.enabled;
      checkbox.setAttribute('aria-label', `Увімкнути ${route.label}`);
      checkbox.addEventListener('change', () => {
        route.enabled = checkbox.checked;
        renderHealth();
        updateActions();
        flash(changed() ? 'Є незбережені зміни' : '');
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
          flash(changed() ? 'Є незбережені зміни' : '');
        });
      }
      group.querySelector('ol').append(row);
    }
    fragment.append(group);
  }
  groups.replaceChildren(fragment);
  renderHealth();
  updateActions();
}

function load(snapshot) {
  current = snapshot;
  draft = structuredClone(snapshot.routes);
  render();
}

function showDashboard(snapshot) {
  load(snapshot);
  session++;
  opening.hidden = login.hidden = true;
  dashboard.hidden = connection.hidden = false;
}

function showLogin(message = '') {
  session++;
  current = draft = undefined;
  busy = false;
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
    showDashboard(await api('POST', { key: password.value }, '/admin/api/session'));
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
    await api('DELETE', undefined, '/admin/api/session');
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
