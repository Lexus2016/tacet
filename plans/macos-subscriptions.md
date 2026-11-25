# Оплата Tacet на macOS / Tacet macOS subscriptions

## План

1. Узгодити єдині публічні тарифи, спільні ліміти, дату поновлення та умови 14-денного пробного доступу. Вибрати сервіс вебоплати, визначити порядок податків, квитанцій і повернень.
2. Додати «Оновити тариф» у «План і використання» збірки Mac з GitHub. Шлюз створює оплату для користувача, а Mac відкриває платіжну сторінку у браузері.
3. Активувати тариф після серверної перевірки платежу. Після повернення з браузера показувати фактичний статус, дату поновлення та «Керувати підпискою». Якщо тариф уже оплачений, показувати стан поточної підписки.
4. Перевірити тестову купівлю, повторне платіжне повідомлення, скасування, повернення, прострочення й перехід на безплатний тариф. Та сама підписка має з’являтися на iPhone після входу. [План iPhone](ios-subscriptions.md)

## English

Use hosted browser checkout from the GitHub-distributed Mac app. The gateway validates payment events, deduplicates them, and provides the shared account plan. Verify checkout, renewal, cancellation, refunds and access from iPhone before launch.
