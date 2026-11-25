# Випуск Tacet і TestFlight / Tacet release and TestFlight

## План

1. Звірити кандидат зі збірками та змінами, перевіреними на Mac і фізичному iPhone. Перевірити встановлення, звичайне диктування, голосовий переклад виділення, буфер обміну, клавіатуру, доступ до акаунта й спільний облік.
2. Перевірити файли для коміту, перелік файлів сервера і вміст підписаних пакетів на наявність секретів і локальних даних. Для публічного випуску підтвердити робочий вхід за поштою. [План входу](public-account-access.md)
3. Після оцінки 10/10 зберегти зміни й відправити їх у GitHub. Зібрати й нотаризувати версії Apple Silicon та Intel локально. Перевірити підпис, обидві стрічки оновлень Sparkle і встановлення оновлення.
4. Зібрати й перевірити точний пакет iPhone. Внутрішній і зовнішній TestFlight потребують пакетів, придатних для відповідного каналу. Перевірити статус оброблення та доступ для обраної групи в App Store Connect.

## English

Validate the exact candidate on macOS and a physical iPhone, scan staged source and distribution packages, and verify public sign-in. Publish only after the 10/10 gate. Build the two notarized Mac architectures locally, verify their Sparkle feeds, and confirm the selected TestFlight build and audience.
