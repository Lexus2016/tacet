# Tacet Gateway · Шлюз Tacet

## Українською

Шлюз керує хмарним розпізнаванням і обробкою тексту для Tacet. У мініадмінці можна змінювати порядок спроб і вмикати або вимикати будь-яку кількість маршрутів. Збережені зміни діють для наступного запиту. Передчасне завершення чи одночасне редагування з різних вкладок не перезаписує новішу редакцію.

### Запуск локально

Потрібен Node.js 24 або новіший. Відкрийте `gateway/`, створіть `.env` і задайте свій ключ адміністратора. Ключі провайдерів потрібні тільки для відповідних маршрутів. Ключ клієнта має бути іншим. Для локального запуску шлюз згенерує тимчасовий ключ клієнта, якщо його пропустити.

```dotenv
TACET_GATEWAY_ADMIN_TOKEN=<generated-admin-token>
TACET_GATEWAY_CLIENT_TOKEN=<generated-client-token>
OPENROUTER_API_KEY=<openrouter-key>
GROQ_API_KEY=<groq-key>
OLLAMA_API_KEY=<ollama-cloud-key>
```

```sh
npm start
```

Відкрийте [http://127.0.0.1:8787/admin/](http://127.0.0.1:8787/admin/) і введіть ключ адміністратора. Для перевірки виконайте `npm test`. Тести підставляють відповіді OpenRouter та працюють у тимчасовій папці.

Локальний шлюз можна перевірити через `GET /v1/models` із клієнтським ключем. Цей запит показує доступні операції без виклику моделей. Звичайні збірки Mac та iPhone звертаються до `https://tacetapi.murable.ai/v1`. На Mac відкрийте **Налаштування → Підключення**, збережіть ключ доступу Tacet й увімкніть **Онлайн-диктування**. На iPhone натисніть **Підключитися до Tacet** і введіть ключ, виданий для цього пристрою.

Шлюз автоматично читає `gateway/.env` під час запуску. Змінні оболонки мають пріоритет. Після зміни ключів перезапустіть шлюз. Локальна адмінка приймає ключ від 8 символів і відхиляє запити через проксі. Сеанс триває до восьми годин і зберігається під час оновлення сторінки. Після перезапуску шлюзу потрібно ввійти знову.

Для публічного доступу через проксі на локальній адресі задайте `TACET_GATEWAY_PUBLIC_ADMIN=1`, ключ адміністратора від 24 символів і HTTPS. У публічному запуску явно налаштуйте клієнтські ключі й обмежте доступ до адмінки на рівні проксі.

`TACET_GATEWAY_HOST` і `TACET_GATEWAY_PORT` дозволяють вибрати адресу й порт. `TACET_GATEWAY_CONFIG` задає шлях до файлу налаштувань, типово `data/routes.json`. Папка з цим файлом має бути доступною на запис і зберігатися між перезапусками. Поточна реалізація використовує один процес шлюзу. Під час перезапуску статистика доступності починає набиратися заново.

### Маршрути й запити

- **Текст.** `openai/gpt-oss-120b` через OpenRouter із початковим порядком Groq → Amazon Bedrock → Cerebras. Додатково можна увімкнути прямий Groq із тією самою моделлю або Ollama Cloud із `gpt-oss:120b`.
- **Аудіо.** Для `openai/whisper-large-v3` шлюз надсилає OpenRouter спочатку `provider.only: ["groq"]`, а в разі переходу на резерв — `provider.only: ["together"]`. [Документація OpenRouter](https://openrouter.ai/docs/guides/overview/multimodal/stt#request-parameters) вказує, що `provider.only` не застосовується до розпізнавання аудіо. Поле `provider_name` у статистиці показує провайдера окремого запиту. Гарантії порядку Groq → Together цей інтерфейс не дає. Groq напряму й Whisper Large V3 Turbo з автоматичним вибором провайдера доступні як окремі маршрути. Для AAC шлюз використовує маршрут OpenRouter, якщо він увімкнений.
- Нові прямі маршрути спочатку вимкнено. Щоб обрати основний маршрут, увімкніть його, підніміть над іншими увімкненими маршрутами й збережіть. Шлюз пропускає маршрути без ключа. При відмові доступу або вичерпанні балансу одного підключення шлюз може перейти до іншого сервісу.
- У разі тимчасової помилки, ліміту запитів, неповної текстової відповіді або перевищення часу шлюз переходить до наступного увімкненого маршруту. Маршрут пропускається 30 секунд або довше за `Retry-After` (до 15 хвилин). Після паузи наступний запит перевіряє його знову. На всі спроби шлюз має до 20 секунд. Індикатор адмінки відображає останню фактичну спробу.
- Помилка ключа чи балансу тимчасово призупиняє запити через відповідне підключення. За замовчуванням шлюз обробляє до восьми запитів одночасно та резервує до 24 МіБ для тіл активних аудіозапитів. За перевантаження повертає `429` із `Retry-After`. Відповідь провайдера обмежена 2 МіБ.
- `POST /v1/chat/completions` приймає синхронний JSON із текстовими `messages`. `POST /v1/audio/transcriptions` приймає файл через `multipart/form-data` або JSON із `input_audio`. Для обох потрібен `Authorization: Bearer <client-token>`. Модель і провайдера визначає конфігурація шлюзу.

Ключ клієнта призначений для локальної перевірки. Перед публічним запуском потрібні HTTPS і перевірка права доступу для кожного користувача. Витрати в адміністративному API беруться з `usage.cost`, коли провайдер його повертає, і накопичуються в памʼяті процесу. Облік підписки та місячного пакета належить до інтеграції із застосунками.

## English

Tacet Gateway manages hosted recognition and text processing. The admin console can reorder routes or disable any number of them. Saves are atomic and revision checked. Saved settings apply to the next request.

Run in `gateway/` with Node.js 24+ using `npm start`. The gateway loads `gateway/.env` at startup, with environment variables taking precedence. Set `TACET_GATEWAY_ADMIN_TOKEN` and add `OPENROUTER_API_KEY`, `GROQ_API_KEY`, and `OLLAMA_API_KEY` as needed. On loopback, an omitted client token is generated for that run. Open [http://127.0.0.1:8787/admin/](http://127.0.0.1:8787/admin/). Use `npm test` to exercise the HTTP handlers against simulated upstream responses. `TACET_GATEWAY_HOST`, `TACET_GATEWAY_PORT`, and `TACET_GATEWAY_CONFIG` override the loopback address, port, and durable route file respectively.

Check a local gateway with authenticated `GET /v1/models`, which lists available operations without contacting upstream providers. Standard Mac and iPhone builds use `https://tacetapi.murable.ai/v1`. On Mac, save the Tacet access key in **Settings → Connection** and turn on **Cloud dictation**. On iPhone, tap **Connect to Tacet** and enter the key issued for that device.

Local admin accepts an admin key of at least eight characters and rejects forwarded or non-local requests. Browser sessions survive refresh for up to eight hours and are cleared on server restart. Behind an HTTPS reverse proxy on loopback, set `TACET_GATEWAY_PUBLIC_ADMIN=1`, use an admin key of at least 24 characters, restrict browser access at the proxy, and explicitly provision client credentials.

OpenRouter text defaults to `openai/gpt-oss-120b` with explicit Groq, Amazon Bedrock, and Cerebras attempts. For Whisper Large V3, the gateway sends OpenRouter `provider.only: ["groq"]` on the first route and `provider.only: ["together"]` on fallback. The [OpenRouter transcription documentation](https://openrouter.ai/docs/guides/overview/multimodal/stt#request-parameters) says transcription ignores `provider.only`. The `provider_name` in OpenRouter generation records identifies the provider for an individual request. There is no documented guarantee of Groq-then-Together ordering through this endpoint. Direct Groq works for text and audio, Whisper Large V3 Turbo uses automatic provider selection, and Ollama Cloud uses `gpt-oss:120b` for text. Select and prioritize routes in the admin console. Failover skips credentials that are missing or rejected and tries other routes where eligible within a 20-second overall deadline. Route configuration survives restarts. Health and returned `usage.cost` totals are process-local.

The two client routes are `POST /v1/chat/completions` (non-streaming text messages) and `POST /v1/audio/transcriptions` (multipart file or base64 audio JSON). They accept a client bearer token. This shared token is for local verification. Public deployment needs HTTPS and per-customer entitlement checks. Provider selection and secrets live on the server.

An authentication or balance error pauses attempts using that connection. By default the gateway accepts up to eight concurrent inference requests and reserves up to 24 MiB for admitted audio request bodies. Overload returns `429` with `Retry-After`. Upstream replies are capped at 2 MiB.


## Pilot usage measurement · Облік використання в пілоті

Для окремого обліку iPhone і Mac видайте випадкові ключі на кожен пристрій із щонайменше 32 байтів випадкових даних. Зберігайте лише відбиток SHA-256 ключа у файлі реєстру. Однаковий `account` об’єднує пристрої одного тестувальника, а `platform` визначається під час видачі ключа. Спільний пробний ключ обліковується окремо з порожнім `account` і `platform=unknown`. Щоб відкликати ключ, видаліть його запис і перезапустіть шлюз.

Issue a random key of at least 32 bytes per pilot device. Store its SHA-256 digest in the registry. Reuse an opaque `account` for the same tester on multiple devices and set `platform` at issuance. The optional shared trial key is counted under an empty `account` and `platform=unknown`. Remove a device entry and restart to revoke its key.

```dotenv
TACET_GATEWAY_CLIENT_REGISTRY=/path/to/private-data/clients.json
TACET_GATEWAY_USAGE_DATABASE=/path/to/private-data/usage.sqlite
```

```json
[
  {"sha256":"<64 lowercase hex characters>","account":"pilot-01","platform":"ios"},
  {"sha256":"<64 lowercase hex characters>","account":"pilot-01","platform":"macos"}
]
```

Шляхи мають вказувати на постійний каталог з обмеженим доступом. `usage_daily` зберігає добові підсумки за UTC, обліковим записом, платформою, операцією та налаштованим маршрутом. Записуються лічильники спроб і завершень, секунди аудіо, токени, надана провайдером сума та кількість відповідей із цими даними. Записи не містять голосу, тексту або ключів. Сума від провайдера може бути відсутня, зокрема за невідомого результату після таймауту. Ці виміри використовуються для розрахунку ціни пілоту.

Keep both files on a persistent, access-restricted volume. `usage_daily` groups by UTC day, account, platform, operation and configured route. It records attempts, usable replies, audio duration, tokens and any reported costs with sample counts. It stores no voice, text or keys. Even a failed attempt may have been billed, and reported costs can be missing. This is a pilot measurement for pricing. Compare it with provider invoices before setting limits or prices.

```sql
SELECT account, platform, operation, route, model, SUM(attempts) AS attempts,
       SUM(completed) AS completed, SUM(audio_seconds) AS audio_seconds,
       SUM(audio_seconds_samples) AS audio_samples, SUM(input_tokens) AS input_tokens,
       SUM(output_tokens) AS output_tokens, SUM(token_samples) AS token_samples,
       SUM(reported_cost_usd) AS known_cost_usd, SUM(cost_samples) AS cost_samples
FROM usage_daily
WHERE day >= '2026-11-01' AND day < '2026-12-01'
GROUP BY account, platform, operation, route, model;
```

## Private subscription pilot · Закритий пілот тарифів

The test account starts on Free with 30 dictation minutes per UTC day and 75,000 text tokens per UTC calendar month, shared across devices. Paid audio allowances still use a UTC calendar month. A plan change applies to the whole account without resetting daily or monthly consumption. Trial prices appear for evaluation and do not charge anything. An account on Pause may still open plan settings. Device slots are assigned by registry order within desktop and mobile groups. On downgrade, the earliest eligible slots keep access. Remove a device from the registry to revoke its key.

Тестовий акаунт починає з безплатного тарифу. На всіх пристроях спільні 30 хвилин диктування на добу UTC і 75 тисяч текстових токенів на календарний місяць UTC. Хвилини платних тестових тарифів також рахуються за місяць. Зміна тарифу діє для всього акаунта й зберігає денне та місячне використання. Ціни наведено для перевірки, списань немає. Коли диктування призупинено, можна відкрити параметри тарифу й вибрати потрібний режим. Місця розподіляються за порядком у реєстрі окремо для комп’ютерів і мобільних пристроїв. При зменшенні тарифу доступ зберігають перші зареєстровані в кожній групі. Видалення запису відкликає ключ пристрою після перезапуску.

| Plan / Тариф | USD/month | Audio min / Хв аудіо | Text tokens / Токени | Desktop / ПК | Mobile / Телефони | Upstream estimate / Оцінка провайдерів |
|---|---:|---:|---:|---:|---:|---:|
| Free / Безплатний | $0 | 30/day · 30/день | 75 000 | 1 | 1 | ~$1.72 for 30 days at the stated duration rate / за 30 днів за ставкою тривалості |
| Basic / Базовий | $1.99 | 200 | 200 000 | 1 | 1 | ~$0.49 |
| Plus / Плюс | $4.99 | 500 | 500 000 | 1 | 2 | ~$1.23 |
| Pro / Профі | $9.99 | 1 000 | 1 000 000 | 2 | 2 | ~$2.46 |
| Unlimited / Безлімітний | $49.99 | ∞ | ∞ | 3 | 3 | Depends on usage / Залежить від використання |

Estimates assume Groq audio at $0.000031/s and conservatively price every text token at the $0.60/M output rate. Payment fees, OpenRouter charges, infrastructure, and unsuccessful provider attempts are outside these estimates. For each supported 16-bit mono PCM WAV upload (8–192 kHz), the pilot rounds the recording duration up to a whole second and adds one second to the account quota. Provider billing is measured separately and can differ from quota usage, especially for short recordings. An unusable or failed response returns the reservation. Text admission reserves a conservative bound and normally settles from returned token counts. Consumption in unlimited mode is still recorded. A process crash after admission can leave a reservation counted in this private pilot.

Оцінка використовує $0,000031 за секунду аудіо Groq і верхню ставку $0,60 за мільйон текстових токенів. Комісії платежів, націнка OpenRouter, інфраструктура й невдалі спроби провайдерів у суму не входять. Для кожного запису монофонічного PCM WAV 16 біт (8–192 кГц) шлюз округлює тривалість вгору до цілої секунди й додає одну секунду до обліку використаного пакета. Витрати провайдера обліковуються окремо і можуть відрізнятися, особливо для коротких записів. Якщо диктант не вдалося отримати, резерв повертається. Для тексту шлюз резервує максимальну оцінку, а після відповіді зазвичай списує фактичну кількість токенів. Використання в безлімітному режимі також обліковується. Якщо процес аварійно завершиться після резервування, резерв може залишитися врахованим.

Set `TACET_GATEWAY_PILOT_ACCOUNTS` to a comma-separated allowlist of operator-designated account IDs on a separately provisioned instance, with a private registry and persistent database. The server enforces quota for registered devices and only allowlisted accounts may select a test plan. `TACET_PILOT_GATEWAY=YES` builds native clients with the single private `/pilot/v1` endpoint and a separate device credential. Public account onboarding can use OpenID Connect with OAuth 2.0 authorization code and PKCE in the system browser. Store device bindings server-side under the verified issuer and subject and use revocable per-device credentials. Plan switching in the public app should follow a verified store entitlement.

Для окремого тестового екземпляра задайте `TACET_GATEWAY_PILOT_ACCOUNTS` зі списком дозволених акаунтів, приватний реєстр і постійну базу. Ліміти діють для зареєстрованих пристроїв. Перемикати тестові тарифи можуть лише дозволені акаунти. Збірки з `TACET_PILOT_GATEWAY=YES` використовують одну адресу `/pilot/v1` та окремий ключ пристрою. Для публічного входу можна використати OpenID Connect поверх OAuth 2.0 із кодом авторизації та PKCE в системному браузері. Прив’язки пристроїв варто зберігати на сервері під перевіреним ідентифікатором акаунта, а ключ кожного пристрою має відкликатися окремо. Публічні тарифи мають активуватися за підтвердженням покупки.

### Email sign-in · Вхід за поштою

Email sign-in is available when SMTP is configured on a gateway with a persistent usage database. Run `npm ci --omit=dev` before starting it. Configure `TACET_AUTH_SMTP_HOST`, `TACET_AUTH_SMTP_PORT`, `TACET_AUTH_SMTP_USER`, `TACET_AUTH_SMTP_PASSWORD`, `TACET_AUTH_FROM`, and `TACET_AUTH_CODE_SECRET` in the server environment. Set the code secret to a random value of at least 32 bytes. Set `TACET_AUTH_ALLOWED_EMAILS` to a comma-separated list for a private pilot. If you run behind a proxy, list its socket addresses in `TACET_AUTH_TRUSTED_PROXIES`. The proxy must overwrite `X-Real-IP` with the address of the connecting client.

Вхід за поштою працює лише після налаштування SMTP та постійної бази обліку. Перед запуском виконайте `npm ci --omit=dev` і задайте перелічені вище змінні середовища. Для закритого пілоту в `TACET_AUTH_ALLOWED_EMAILS` задайте адреси учасників через кому. Якщо перед шлюзом є проксі, вкажіть його адреси у `TACET_AUTH_TRUSTED_PROXIES` і налаштуйте заміну `X-Real-IP` на фактичну адресу клієнта.

### User console · Адмінка користувачів

On a gateway with email sign-in the admin page has a **Users** tab: a searchable list with plan, usage, devices and last activity, and a user page where the operator changes the plan (with an optional end date), records a payment, blocks or unblocks the account, revokes a device or deletes the account. Blocking and plan changes apply on the next request. Every change needs a reason and is written to an append-only action log; payments and the log are kept after an account is deleted. The plans offered for sale are `free`, `basic` and `pro`; `unlimited` and `paused` can be set only here.

На шлюзі зі входом за поштою сторінка адмінки має вкладку **Користувачі**: список із пошуком, тарифом, використанням, пристроями й останньою активністю та картку користувача, де оператор змінює тариф (за потреби з датою завершення), фіксує оплату, блокує чи розблоковує акаунт, відкликає пристрій або видаляє акаунт. Блокування й зміна тарифу діють із наступного запиту. Кожна зміна потребує причини й потрапляє в журнал дій, який лише доповнюється; оплати й журнал зберігаються після видалення акаунта. У продажу тарифи `free`, `basic` і `pro`; `unlimited` і `paused` призначаються лише тут.

Codes expire in ten minutes and can be used once. Each connected device receives a revocable credential. Its usage counts toward the same account allowance. The 2, 5 and 8 device limits include all platforms. New email accounts start on Free and cannot switch to a paid plan until a verified purchase is connected. `GET /v1/account/plan` exposes `audioPeriod` and `audioResetsAt` for dictation and `resetsAt` for the monthly text allowance.

Код діє десять хвилин і використовується один раз. Кожен підключений пристрій має окремий ключ, який можна відкликати. Використання на всіх пристроях списується зі спільного пакета. Ліміти 2, 5 і 8 поширюються на всі пристрої незалежно від платформи. Нові акаунти починають із безплатного тарифу. Платний тариф потребує підтвердженої покупки. У `GET /v1/account/plan` поля `audioPeriod` й `audioResetsAt` описують період і поновлення диктування, а `resetsAt` — поновлення місячного текстового ліміту.

### Long selection edits · Довге редагування виділення

The native clients send the entire selection in one request. The expanded path accepts selections up to 90 KiB of UTF-8 and asks for up to 32,768 completion tokens. `X-Tacet-Operation: selection-edit` expands the JSON envelope, isolates normal-request health, and allows at most two concurrent expanded jobs. The gateway allows up to 140 seconds overall. For the pilot route, the HTTPS proxy allows 145 seconds and the app waits up to 150 seconds for text processing. Ordinary dictation follows its existing deadlines. A reply ending because it ran out of tokens cannot replace the selection. The account must have enough allowance for the operation.

Застосунок надсилає весь виділений документ одним запитом. Межа вхідного тексту становить 90 КіБ у UTF‑8, відповідь має до 32 768 токенів. Заголовок `X-Tacet-Operation: selection-edit` вмикає цей режим з окремим лімітом у два одночасні запити. Загальний час шлюзу становить до 140 секунд. Проксі пілоту чекає до 145 секунд, застосунок — до 150 секунд. Відповідь, обрізана за лімітом токенів, не замінює текст. Для операції потрібен достатній залишок пакета акаунта.

### Pricing proposal · Пропозиція тарифів

Proposed for a future public rollout. The private pilot limits above are the active configuration. / Пропозиція для майбутнього публічного запуску. У закритому пілоті діють ліміти з попередньої таблиці.

| Price / Ціна | Audio minutes / Хвилини | Text tokens / Токени | Desktop + mobile / ПК + телефон | Model cost scenario / Оцінка вартості моделей |
|---|---:|---:|---:|---:|
| $0 | 30 | 75 000 | 1 + 1 | $0.10 |
| $1.99 | 200 | 400 000 | 1 + 1 | $0.61 |
| $4.99 | 500 | 1 000 000 | 1 + 2 | $1.53 |
| $9.99 | 1 000 | 2 000 000 | 2 + 2 | $3.06 |

Estimates assume use of the entire plan allowance at $0.000031 per audio second and $0.60 per million text tokens. Costs for routing fees, payments, infrastructure and failed upstream attempts are excluded. Leave $49.99 as a private pilot option until actual heavy usage or a team feature set supports a public price. / Розрахунок припускає повне використання пакета за ставками $0,000031 за секунду аудіо та $0,60 за мільйон текстових токенів. Націнка маршрутизації, комісії оплати, інфраструктура та невдалі спроби провайдерів не враховані. $49,99 варто залишити в пілоті, доки використання найактивніших клієнтів або командні можливості не обґрунтують публічну ціну.
