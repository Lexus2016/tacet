# Оплата Tacet на iPhone / Tacet iPhone subscriptions

## План

1. Активувати платіжний договір Apple, заповнити банківські й податкові дані. Налаштувати одну групу місячних підписок після затвердження спільного каталогу тарифів. [Підписки Apple](https://developer.apple.com/help/app-store-connect/manage-subscriptions/offer-auto-renewable-subscriptions/)
2. Додати покупку, відновлення і керування підпискою через StoreKit у головному застосунку. Прив’язати покупку Apple до акаунта Tacet.
3. На шлюзі перевіряти підписані повідомлення Apple та оновлювати спільний тариф і ліміти після підтвердженої покупки, поновлення, повернення або завершення. Покупка на Mac має відображатися на iPhone після входу. [Правила Apple](https://developer.apple.com/app-store/review/guidelines/#multiplatform-services)
4. Пройти тестові покупки в обох напрямках, відновлення після перевстановлення, скасування, повернення і повторні повідомлення. Зафіксувати дату, від якої спільні ліміти поновлюються.

## English

Set up the Apple agreement and a subscription group, then implement StoreKit purchasing and restoration in the iPhone app. Match Apple transactions with Tacet accounts, verify Apple server notifications, and test cross-device access and lifecycle changes.
