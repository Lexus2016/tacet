# Диктування на пристрої як запасний режим / On-device dictation fallback

## Рішення

Хмара завжди перша. Модель на пристрої (Parakeet TDT v3, близько 460 МБ, 25 європейських мов) виконує диктування лише тоді, коли користувач сам її завантажив і хмара відмовила через вичерпаний ліміт або недосяжна. Відключений акаунт, відхилений ключ, тиша чи інша помилка хмари на пристрій диктування не передають: локальний режим не замінює підписку.

У цьому режимі вставляється сирий текст розпізнавання. Виправлення, переклад і голосові правки виділеного лишаються хмарними й прямо названі вимкненими. Пояснення показуємо раз на перехід, далі — коротка позначка (примітка на Mac, помаранчева крапка на мікрофоні клавіатури iPhone); повернення хмари теж повідомляємо. Оновлений або розширений тариф повертає диктування в хмару одразу.

## План

1. Зроблено: спільна логіка (`CloudAvailability`, `LocalFallback`), конвеєр Mac, мобільне розпізнавання, екран «Тариф і використання» із завантаженням і вилученням моделі, переклади, тести. Наскрізний тест на Mac з реальною моделлю проходить.
2. Заміряти на фізичному iPhone: час завантаження моделі, холодний і теплий час розпізнавання, пам’ять. Клавіатура чекає результат до 55 с; якщо холодний старт не вкладається, прогрівати модель на початку сесії, коли хмара вже відома як недоступна.
3. Перевірити на iPhone обидва переходи наживо: режим польоту та вичерпаний денний ліміт тестового тарифу, включно з поверненням у хмару.
4. Вирішити, чи пропонувати завантаження моделі під час онбордингу ([план онбордингу](onboarding.md)) і в момент першого вичерпання ліміту.

## English

Cloud first; the on-device model (Parakeet TDT v3, about 460 MB, 25 European languages) dictates only after an explicit download and only when the cloud refuses for lack of allowance or cannot be reached. No other cloud error hands dictation to the device, so the mode never replaces a subscription. Raw text is inserted; correction, translation and voice edits stay cloud-only and are named as off. Done: shared logic, Mac pipeline, mobile recognition, model download in Plan and usage, translations, tests, including an end-to-end Mac test with the real model. Pending on a physical iPhone: download and cold/warm timing, memory, and live checks of both switches and the return to the cloud.
