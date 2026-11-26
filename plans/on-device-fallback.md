# Диктування на пристрої як запасний режим / On-device dictation fallback

## Рішення

Хмара завжди перша. Модель на пристрої (Parakeet TDT v3, близько 460 МБ, 25 європейських мов) виконує диктування лише тоді, коли користувач сам її завантажив і хмара відмовила через вичерпаний ліміт або недосяжна. Відключений акаунт, відхилений ключ, тиша чи інша помилка хмари на пристрій диктування не передають: локальний режим не замінює підписку.

У цьому режимі вставляється сирий текст розпізнавання. Виправлення, переклад і голосові правки виділеного лишаються хмарними й прямо названі вимкненими. Пояснення показуємо раз на перехід, далі — коротка позначка (примітка на Mac, помаранчева крапка на мікрофоні клавіатури iPhone); повернення хмари теж повідомляємо. Оновлений або розширений тариф повертає диктування в хмару одразу.

## План

1. Зроблено: спільна логіка (`CloudAvailability`, `LocalFallback`), конвеєр Mac, мобільне розпізнавання, екран «Тариф і використання» із завантаженням і вилученням моделі, переклади, тести. Наскрізний тест на Mac з реальною моделлю проходить.
2. Зроблено: заміри на iPhone 15 Pro (iOS 27.2). Завантаження моделі разом із першим запуском — 75 с, на диску 460 МБ. Розпізнавання 8 с української мови — 0,1 с із завантаженою моделлю і 0,27 с після вивантаження з пам’яті. Пам’ять застосунку: близько 500 МБ із завантаженою моделлю, 40 МБ після вивантаження. Клавіатура чекає результат до 55 с, тож запас великий; окремий прогрів не потрібен. Заміри зроблено на синтезованому мовленні; точність на живому голосі ще не оцінено.
3. Перевірити на iPhone обидва переходи наживо: режим польоту та вичерпаний денний ліміт тестового тарифу, включно з поверненням у хмару.
4. Вирішити, чи пропонувати завантаження моделі під час онбордингу ([план онбордингу](onboarding.md)) і в момент першого вичерпання ліміту.

## English

Cloud first; the on-device model (Parakeet TDT v3, about 460 MB, 25 European languages) dictates only after an explicit download and only when the cloud refuses for lack of allowance or cannot be reached. No other cloud error hands dictation to the device, so the mode never replaces a subscription. Raw text is inserted; correction, translation and voice edits stay cloud-only and are named as off. Done: shared logic, Mac pipeline, mobile recognition, model download in Plan and usage, translations, tests, including an end-to-end Mac test with the real model. Measured on an iPhone 15 Pro: 75 s to download and first-load the 460 MB model, 0.1 s to transcribe 8 s of Ukrainian speech warm and 0.27 s after an unload, about 500 MB resident while loaded and 40 MB after unloading. Pending: accuracy on live speech and live checks of both switches and the return to the cloud.
