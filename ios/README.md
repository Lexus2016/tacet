# Tacet for iPhone

1. Open **Settings → General → Keyboard → Keyboards**. Add **Tacet** and turn on **Allow Full Access** for Tacet. Regular typing works with either access setting.
2. Open Tacet and tap **Connect to Tacet**. Enter the access key issued for this iPhone. Dictation and text processing use Tacet Gateway, which manages models and fallback routes.
3. Open a text field in any app that supports custom keyboards. Switch to Tacet with the globe key and tap its microphone. If the session is off, Tacet opens to enable it. When the session is ready, swipe right along the bottom edge on an iPhone with Face ID, or use the system back arrow. If recording has not started in the original field, tap the keyboard microphone. Tap the square to insert text at the cursor.

Assign **Enable Tacet dictation** to the iPhone Action Button or run it from Shortcuts to start a session. Choose available layouts in **Keyboard languages**. Tap the language key to switch layouts or hold it to choose directly. Hold a letter to see available accents.

Use **123** for numbers and punctuation, and **#+=** for additional symbols. A preview above a pressed key shows the character before you release it.

The selected Tacet keyboard layout sets the speech language for direct dictation. To speak one language and type another, enable **Translate to the keyboard language** under **Keyboard**. Tacet detects your spoken language, translates when needed, and inserts the result in the layout language selected when you tapped the microphone. If translation fails, it inserts your original dictation and shows a warning.

When the dictation allowance runs out or Tacet cannot be reached, dictation continues on the iPhone if you downloaded the on-device model under **Plan and usage** (about 460 MB, 25 European languages). Accuracy is lower, and correction, translation and voice edits wait for the cloud; an orange dot on the keyboard microphone marks this mode.

Keyboard spelling and word completion run locally for the active layout. See the [completion vocabulary attribution](Keyboard/Completions/ATTRIBUTION.txt).

To edit selected text, select it in the current app, start dictation, and say a command such as “Translate this into Ukrainian.” Tacet sends the selection and the instruction through the gateway. If the command fails, Tacet leaves the selection intact.

The 15-minute session keeps the microphone available until it expires or you end it. Audio is collected between the two taps. If the active text field changes, the keyboard discards the pending insertion. The host and keyboard communicate through a shared Keychain group.

## Збірка та перевірка

1. Виконайте `xcodegen generate --spec ios/project.yml`.
2. Відкрийте `ios/Tacet-iOS.xcodeproj` у Xcode. У **Signing & Capabilities** оберіть свою команду для **Tacet** і **TacetKeyboard**. Потрібні профілі Apple Development для обох ідентифікаторів і під’єднаного iPhone.
3. Оберіть схему **Tacet-iOS** і під’єднаний телефон. Після встановлення виконайте перевірку в чернетці «Збережених повідомлень» Telegram. Переконайтеся, що текст з’явився один раз у полі повідомлення. Окремо перевірте зміну поля під час розпізнавання та завершення сесії.

## Українською

Додайте Tacet у **Налаштування → Загальні → Клавіатура → Клавіатури** і дозвольте повний доступ для диктування. Розпізнавання й обробка тексту працюють через шлюз Tacet, який також керує резервними маршрутами. У будь-якому застосунку, що підтримує сторонні клавіатури, перемкніться на Tacet клавішею з глобусом і натисніть мікрофон. Якщо сесію треба ввімкнути, iPhone відкриє Tacet. Коли сесія готова, на iPhone з Face ID проведіть праворуч уздовж нижнього краю екрана або скористайтеся системною стрілкою. Якщо запис не почався в тому самому полі, натисніть мікрофон. Скажіть фразу й натисніть квадрат. Текст з’явиться біля курсора. Потрібні розкладки вибираються в **Мови клавіатури**. Натисніть клавішу з кодом мови, щоб перемкнути розкладку, або затисніть її, щоб вибрати зі списку.

Під час першого запуску натисніть **Підключитися до Tacet** і введіть виданий для цього iPhone ключ. Щоб замінити його, відкрийте **Змінити ключ доступу Tacet**.

Для звичайного диктування Tacet слухає мову вибраної розкладки. Щоб говорити однією мовою, а отримувати текст іншою, увімкніть **Перекладати мовою клавіатури** в розділі **Клавіатура**. Tacet визначить мову мовлення й за потреби перекладе текст мовою розкладки, активної в момент натискання мікрофона. Якщо перекласти не вдасться, Tacet вставить вихідний диктант і покаже попередження.

Щоб відредагувати текст, виділіть його в поточному застосунку, запустіть диктування та скажіть, наприклад, «Переклади це українською». Tacet надсилає виділення й команду через шлюз. Якщо команда не виконається, виділений текст збережеться.

Коли ліміт диктування вичерпано або Tacet недосяжний, диктування продовжується на iPhone, якщо ви завантажили модель у розділі **Тариф і використання** (близько 460 МБ, 25 європейських мов). Точність нижча, а виправлення, переклад і голосові правки чекають на хмару; цей режим позначає помаранчева крапка на мікрофоні клавіатури.

Правопис і доповнення слів працюють локально для поточної розкладки. [Джерело словника та ліцензія](Keyboard/Completions/ATTRIBUTION.txt).
