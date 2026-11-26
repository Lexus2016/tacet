// The owner's user console: list, usage, and manual decisions about accounts.
// Адмінка користувачів для власника: список, використання та ручні рішення щодо акаунтів.

const date = new Intl.DateTimeFormat('uk', { dateStyle: 'short', timeStyle: 'short' });
const number = new Intl.NumberFormat('uk');
const planNames = { free: 'Free', basic: 'Basic', pro: 'Pro', unlimited: 'Безліміт', paused: 'Пауза' };
const sources = { default: 'за замовчуванням', operator: 'призначено вручну', payment: 'за оплатою' };
const actionNames = {
  plan: 'Тариф змінено', plan_expired: 'Тариф завершився', block: 'Заблоковано', unblock: 'Розблоковано',
  payment: 'Оплата', allowance: 'Додано хвилини', device_revoked: 'Пристрій відкликано', account_deleted: 'Акаунт видалено',
};
const platforms = { macos: 'Mac', ios: 'iPhone', windows: 'Windows', android: 'Android' };
const operations = { audio: 'Диктування', text: 'Текст' };
const failures = {
  400: 'Перевірте введені дані.', 404: 'Запис не знайдено.', 401: 'Сеанс завершився.',
  409: 'Платіж із таким номером уже зафіксовано.',
};

function el(tag, props = {}, ...children) {
  const node = document.createElement(tag);
  for (const [name, value] of Object.entries(props)) {
    if (name === 'class') node.className = value;
    else if (name === 'text') node.textContent = value;
    else if (name.startsWith('on')) node.addEventListener(name.slice(2), value);
    else if (value !== false && value !== null && value !== undefined) node.setAttribute(name, value === true ? '' : value);
  }
  node.append(...children.flat(Infinity).filter(child => child !== null && child !== undefined && child !== false));
  return node;
}

const when = time => (time ? date.format(time) : '—');
const minutes = seconds => `${number.format(Math.round(seconds / 60))} хв`;
const limit = (used, max, format) => (max === null ? `${format(used)} / без ліміту` : `${format(used)} / ${format(max)}`);
const money = (cents, currency) => `${(cents / 100).toFixed(2)} ${currency}`;

// The conditions of a plan in one line, so the operator does not have to look them up.
// Умови тарифу одним рядком, щоб операторові не доводилося їх шукати.
function terms(plan) {
  if (plan.id === 'paused') return 'диктування й обробку тексту вимкнено';
  const tokens = plan.textTokens >= 1_000_000 ? `${number.format(plan.textTokens / 1_000_000)} млн` : `${number.format(plan.textTokens / 1000)} тис.`;
  return [
    plan.priceCents ? `$${(plan.priceCents / 100).toFixed(2)}/міс` : plan.id === 'free' ? 'безплатно' : 'не продається',
    plan.audioSeconds === null ? 'диктування без ліміту' : `${number.format(plan.audioSeconds / 60)} хв ${plan.id === 'free' ? 'разово, без поновлення' : 'на місяць'}`,
    plan.textTokens === null ? 'текст без ліміту' : `${tokens} токенів ${plan.id === 'free' ? 'разово' : 'на місяць'}`,
    `до ${plan.devices} пристроїв`,
  ].join(' · ');
}

export function createUsers({ root, api, unauthorized }) {
  const filters = { query: '', status: '', plan: '', sort: 'active' };
  let opened;
  let token = 0;
  const status = el('p', { role: 'status', 'aria-live': 'polite', class: 'users-status' });
  const summary = el('div', { class: 'summary' });
  const list = el('div', { class: 'panel users-list' });
  const detail = el('div', { class: 'user-detail' });

  function say(message, error = false) {
    status.textContent = message;
    status.classList.toggle('error', error);
  }

  async function call(method, path, data) {
    try {
      return await api(method, data, `api/users${path}`);
    } catch (error) {
      if (error.status === 401) unauthorized();
      else say(failures[error.status] ?? 'Шлюз не підтвердив операцію.', true);
      return undefined;
    }
  }

  function select(name, options, value) {
    return el('select', { name, 'aria-label': name },
      options.map(([id, label]) => el('option', { value: id, selected: id === value, text: label })));
  }

  function field(label, control) {
    return el('label', { class: 'field' }, el('span', { text: label }), control);
  }

  function renderSummary(data) {
    const plans = Object.entries(data.plans).map(([id, count]) => `${planNames[id] ?? id}: ${count}`).join(' · ');
    const paid = data.payments.map(entry => `${money(entry.amountCents, entry.currency)} (${entry.count})`).join(', ') || 'немає';
    const cells = [
      ['Акаунтів', `${data.accounts}`, plans],
      ['Нових за 7 днів', `${data.newThisWeek}`, `активних: ${data.activeThisWeek} · заблокованих: ${data.blocked}`],
      [`Використано за ${data.month}`, minutes(data.used.audioSeconds), `${number.format(data.used.textTokens)} токенів`],
      ['Вартість провайдерів', `$${data.providerCost.usd.toFixed(2)}`,
        `нижня межа: ціну повідомлено для ${data.providerCost.reportedRequests} з ${data.providerCost.requests} запитів`],
      ['Оплати за місяць', paid, ''],
    ];
    summary.replaceChildren(...cells.map(([title, value, note]) => el('div', { class: 'panel stat' },
      el('span', { class: 'stat-title', text: title }), el('strong', { text: value }), note && el('span', { class: 'stat-note', text: note }))));
  }

  function renderList(data) {
    const rows = data.users.map(user => el('tr', { class: user.account === opened ? 'selected' : '' },
      el('td', {}, el('button', { class: 'link', type: 'button', text: user.email ?? user.account, onclick: () => open(user.account) })),
      el('td', {}, el('span', { class: 'badge', 'data-state': user.blocked ? 'failed' : user.plan === 'free' ? '' : 'ready',
        text: user.blocked ? 'Заблоковано' : planNames[user.plan] ?? user.plan })),
      el('td', { text: limit(user.used.audioSeconds, user.limits.audioSeconds, minutes) }),
      el('td', { text: limit(user.used.textTokens, user.limits.textTokens, value => number.format(value)) }),
      el('td', { text: `${user.devices} / ${user.limits.devices}` }),
      el('td', { text: when(user.lastActive) })));
    const head = ['Користувач', 'Тариф', 'Диктування за місяць', 'Текст за місяць', 'Пристрої', 'Остання активність'];
    list.replaceChildren(...[
      el('table', {}, el('thead', {}, el('tr', {}, head.map(text => el('th', { scope: 'col', text })))), el('tbody', {}, rows)),
      !rows.length && el('p', { class: 'empty', text: 'Користувачів за цим запитом немає.' }),
      data.total > data.users.length && el('p', { class: 'empty', text: `Показано ${data.users.length} з ${data.total}. Уточніть пошук.` }),
    ].filter(Boolean));
  }

  async function refresh() {
    const current = ++token;
    const search = new URLSearchParams(Object.entries(filters).filter(([, value]) => value));
    const [users, totals] = await Promise.all([call('GET', `?${search}`), call('GET', '/summary')]);
    if (current !== token || !users || !totals) return;
    renderSummary(totals);
    renderList(users);
  }

  function action(title, fields, button, submit, danger = false) {
    const form = el('form', { class: 'action' }, el('h3', { text: title }), fields,
      el('button', { type: 'submit', class: danger ? 'danger' : 'primary', text: button }));
    form.addEventListener('submit', async event => {
      event.preventDefault();
      const control = form.querySelector('button[type="submit"]');
      control.disabled = true;
      say('');
      const updated = await submit(Object.fromEntries(new FormData(form)));
      control.disabled = false;
      if (!updated) return;
      say('Зміну застосовано.');
      if (updated.ok) {
        opened = undefined;
        detail.replaceChildren();
      } else renderDetail(updated);
      refresh();
    });
    return form;
  }

  const reason = (placeholder = 'Причина (потрапить у журнал)') =>
    el('input', { name: 'reason', required: true, maxlength: 200, placeholder, 'aria-label': 'Причина' });
  const end = value => (value ? new Date(`${value}T23:59:59Z`).getTime() : null);

  function renderDetail(user) {
    const post = (path, data) => call('POST', `/${user.account}${path}`, data);
    const planOptions = user.plans.map(plan => [plan.id, `${planNames[plan.id] ?? plan.id} — ${terms(plan)}`]);
    // The closed list cuts a long label, so the chosen plan's conditions are repeated under it.
    // Закритий список обрізає довгий підпис, тож умови вибраного тарифу повторено під ним.
    const planField = (label, options, value) => {
      const control = select('plan', options, value);
      const hint = el('span', { class: 'hint' });
      const show = () => {
        const plan = user.plans.find(plan => plan.id === control.value);
        hint.textContent = plan ? terms(plan) : '';
      };
      control.addEventListener('change', show);
      show();
      return el('label', { class: 'field' }, el('span', { text: label }), control, hint);
    };
    const facts = [
      ['Акаунт', user.account],
      ['Тариф', `${planNames[user.plan] ?? user.plan} · ${sources[user.planSource] ?? user.planSource}` +
        (user.planUntil ? ` · до ${when(user.planUntil)}` : '')],
      ['Стан', user.blocked ? `Заблоковано: ${user.blocked}` : 'Активний'],
      ['Диктування сьогодні', minutes(user.usedToday.audioSeconds)],
      [user.period === 'once' ? 'Диктування з разового запасу' : 'Диктування за місяць',
        limit(user.used.audioSeconds, user.limits.audioSeconds, minutes) +
        (user.bonusAudioSeconds ? ` (з них додано ${minutes(user.bonusAudioSeconds)})` : '')],
      [user.period === 'once' ? 'Текст із разового запасу' : 'Текст за місяць',
        limit(user.used.textTokens, user.limits.textTokens, value => number.format(value))],
      ['Зареєстровано', when(user.created)], ['Остання активність', when(user.lastActive)],
    ];
    const table = (head, rows, empty) => (rows.length
      ? el('table', {}, el('thead', {}, el('tr', {}, head.map(text => el('th', { scope: 'col', text })))),
        el('tbody', {}, rows.map(cells => el('tr', {}, cells.map(cell => el('td', {}, cell))))))
      : el('p', { class: 'empty', text: empty }));

    detail.replaceChildren(el('section', { class: 'panel user' },
      el('div', { class: 'user-head' }, el('h2', { text: user.email ?? user.account }),
        el('button', { type: 'button', text: 'Закрити', onclick: () => { opened = undefined; detail.replaceChildren(); refresh(); } })),
      el('dl', {}, facts.map(([name, value]) => [el('dt', { text: name }), el('dd', { text: value })])),

      el('div', { class: 'actions-grid' },
        action('Тариф', [
          planField('Тариф', planOptions, user.plan),
          field('Діє до (порожньо — безстроково)', el('input', { type: 'date', name: 'until' })), reason(),
        ], 'Застосувати', data => post('/plan', { plan: data.plan, until: end(data.until), reason: data.reason })),

        action('Оплата', [
          field('Сума', el('input', { name: 'amount', type: 'number', min: '0.01', step: '0.01', required: true })),
          field('Валюта', el('input', { name: 'currency', value: 'USD', maxlength: 3, required: true })),
          field('Спосіб', el('input', { name: 'method', required: true, maxlength: 40, placeholder: 'переказ, картка…' })),
          field('Номер платежу', el('input', { name: 'reference', maxlength: 120 })),
          planField('Увімкнути тариф', [['', 'не змінювати'], ...planOptions.filter(([id]) => id !== 'paused')], ''),
          field('Діє до', el('input', { type: 'date', name: 'until' })),
          el('input', { name: 'note', maxlength: 200, placeholder: 'Примітка', 'aria-label': 'Примітка' }),
        ], 'Зафіксувати оплату', data => post('/payments', {
          amountCents: Math.round(Number(data.amount) * 100), currency: data.currency, method: data.method,
          reference: data.reference, note: data.note || 'Оплату зафіксовано', ...(data.plan && { plan: data.plan, until: end(data.until) }),
        })),

        action('Безплатний запас', [
          el('p', { text: 'Додає хвилини хмарного диктування до разового запасу Free. Діє, поки акаунт на Free.' }),
          field('Хвилин', el('input', { name: 'minutes', type: 'number', min: '1', max: '10000', step: '1', required: true })),
          reason(),
        ], 'Додати хвилини', data => post('/allowance', { minutes: Number(data.minutes), reason: data.reason })),

        user.blocked
          ? action('Розблокування', [reason()], 'Розблокувати', data => post('/unblock', data))
          : action('Блокування', [reason('Причина блокування')], 'Заблокувати', data => post('/block', data), true),

        user.email && action('Видалення акаунта', [
          el('p', { text: 'Видаляє акаунт, пристрої й використання. Оплати та журнал дій лишаються. Дію не можна скасувати.' }),
          field('Введіть пошту акаунта для підтвердження', el('input', { name: 'confirm', required: true, autocomplete: 'off' })),
          reason('Причина (без імені й пошти користувача)'),
        ], 'Видалити акаунт', data => post('/delete', data), true)),

      el('h3', { text: 'Пристрої' }),
      table(['Назва', 'Платформа', 'Останній вхід', ''], user.deviceList.map(device => [
        device.name, platforms[device.platform] ?? device.platform, when(device.lastLogin),
        el('button', { type: 'button', text: 'Відкликати', onclick: async () => {
          const updated = await post(`/devices/${device.id}`, { reason: 'Відкликано в адмінці' });
          if (updated) { say('Пристрій відкликано.'); renderDetail(updated); refresh(); }
        } }),
      ]), 'Під’єднаних пристроїв немає.'),

      el('h3', { text: 'Використання за 30 днів' }),
      table(['День', 'Платформа', 'Операція', 'Запитів', 'Обсяг', 'Вартість'], user.usage.map(row => [
        row.day, platforms[row.platform] ?? row.platform, operations[row.operation] ?? row.operation,
        `${row.completed} з ${row.attempts}`,
        row.operation === 'audio' ? minutes(row.audioSeconds) : `${number.format(row.tokens)} токенів`,
        row.costUSD ? `$${row.costUSD.toFixed(4)}` : '—',
      ]), 'Запитів за цей період не було.'),

      el('h3', { text: 'Оплати' }),
      table(['Дата', 'Сума', 'Спосіб', 'Номер', 'Примітка'], user.payments.map(entry => [
        when(entry.time), money(entry.amountCents, entry.currency), entry.method, entry.reference || '—', entry.note || '—',
      ]), 'Оплат не зафіксовано.'),

      el('h3', { text: 'Журнал дій' }),
      table(['Час', 'Дія', 'Причина'], user.actions.map(entry => [
        when(entry.time), actionNames[entry.action] ?? entry.action, entry.reason,
      ]), 'Ручних дій не було.')));
  }

  async function open(account) {
    opened = account;
    const user = await call('GET', `/${account}`);
    if (!user || opened !== account) return;
    renderDetail(user);
    refresh();
    detail.scrollIntoView({ block: 'start', behavior: 'smooth' });
  }

  const search = el('input', { type: 'search', placeholder: 'Пошук за поштою', 'aria-label': 'Пошук за поштою' });
  let typing;
  search.addEventListener('input', () => {
    clearTimeout(typing);
    typing = setTimeout(() => { filters.query = search.value; refresh(); }, 250);
  });
  const pick = (name, options) => {
    const control = select(name, options, filters[name]);
    control.addEventListener('change', () => { filters[name] = control.value; refresh(); });
    return control;
  };
  root.replaceChildren(
    summary,
    el('div', { class: 'filters' }, search,
      pick('status', [['', 'Усі стани'], ['active', 'Активні'], ['blocked', 'Заблоковані']]),
      pick('plan', [['', 'Усі тарифи'], ...Object.entries(planNames)]),
      pick('sort', [['active', 'За активністю'], ['created', 'За реєстрацією'], ['audio', 'За диктуванням'],
        ['text', 'За текстом'], ['email', 'За поштою']])),
    status, list, detail);

  return {
    show: refresh,
    reset() {
      token++;
      opened = undefined;
      summary.replaceChildren();
      list.replaceChildren();
      detail.replaceChildren();
      say('');
    },
  };
}
