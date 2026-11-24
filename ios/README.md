# Tacet for iPhone

1. Open **Settings → General → Keyboard → Keyboards**. Add **Tacet** and turn on **Allow Full Access** for Tacet. Regular typing works with either access setting.
2. Open Tacet and choose a primary recognition model. Turn on **Use fallback model** to try a second model when the first fails. Apple recognition runs on the device for supported languages. Groq, OpenAI and OpenRouter use online recognition after you save a key and authorize audio sharing for the selected provider.
3. Open a text field in any app that supports custom keyboards. Switch to Tacet with the globe key and tap its microphone. If the session is off, Tacet opens to enable it. The iPhone’s back arrow returns you to the previous app. Tap the square to insert text at the cursor.

Assign **Enable Tacet dictation** to the iPhone Action Button or run it from Shortcuts to start a session. Choose available layouts in **Keyboard languages**. Tap the language key to switch layouts or hold it to choose directly. Hold a letter to see available accents.

Use **123** for numbers and punctuation, and **#+=** for additional symbols. A preview above a pressed key shows the character before you release it.

The selected Tacet keyboard layout sets the speech language for direct dictation. To speak one language and type another, enable **Translate to the keyboard language** under **Text processing**. Select an online speech model with audio sharing enabled and configure a text model. Tacet detects your spoken language, translates only when needed, and inserts the result in the layout language selected when you tapped the microphone. If translation fails, it inserts your original dictation and shows a warning.

Text processing shares one primary model and one optional fallback for correction and translation. Groq, OpenAI and OpenRouter are supported. Enabling either feature allows Tacet to send the transcript to the selected providers for that purpose.

The 15-minute session keeps the microphone available until it expires or you end it. Audio is collected between the two taps. If the active text field changes, the keyboard discards the pending insertion. The host and keyboard communicate through a shared Keychain group.

## Збірка та перевірка

1. Виконайте `xcodegen generate --spec ios/project.yml`.
2. Відкрийте `ios/Tacet-iOS.xcodeproj` у Xcode. У **Signing & Capabilities** оберіть свою команду для **Tacet** і **TacetKeyboard**. Потрібні профілі Apple Development для обох ідентифікаторів і під’єднаного iPhone.
3. Оберіть схему **Tacet-iOS** і під’єднаний телефон. Після встановлення виконайте перевірку в чернетці «Збережених повідомлень» Telegram. Переконайтеся, що текст з’явився один раз у полі повідомлення. Окремо перевірте зміну поля під час розпізнавання та завершення сесії.

## Українською

Додайте Tacet у **Налаштування → Загальні → Клавіатура → Клавіатури** і дозвольте повний доступ для диктування. Оберіть провайдера в Tacet. У будь-якому застосунку, що підтримує сторонні клавіатури, перемкніться на Tacet клавішею з глобусом і натисніть мікрофон. Якщо сесію треба ввімкнути, iPhone відкриє Tacet. Системна стрілка поверне до попереднього застосунку. Скажіть фразу й натисніть квадрат. Текст з’явиться біля курсора. Потрібні розкладки вибираються в **Мови клавіатури**. Натисніть клавішу з кодом мови, щоб перемкнути розкладку, або затисніть її, щоб вибрати зі списку.

Для звичайного диктування Tacet слухає мову вибраної розкладки. Щоб говорити однією мовою, а отримувати текст іншою, увімкніть **Перекладати мовою клавіатури** в розділі **Обробка тексту**. Виберіть онлайн-модель розпізнавання, дозвольте їй отримувати аудіо й налаштуйте текстову модель. Tacet визначить мову мовлення й за потреби перекладе текст мовою розкладки, активної в момент натискання мікрофона. Якщо перекласти не вдасться, Tacet вставить вихідний диктант і покаже попередження.

Виправлення й переклад використовують одну основну текстову модель і, за потреби, одну резервну. Доступні Groq, OpenAI та OpenRouter. Увімкнення відповідної функції дозволяє Tacet надіслати розпізнаний текст вибраним провайдерам.
