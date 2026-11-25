# Стала висота клавіатури iPhone / Fixed iPhone keyboard height

## План

1. Зарезервувати місце під верхню смугу за будь-якого стану підказок. Висота клавіатури та верхній відступ залежать від орієнтації екрана.
2. У смузі оновлювати слова, варіанти піньїню або повідомлення диктування без зміни геометрії клавіатури. Порожні кнопки підказок залишаються неактивними.
3. У тестовому полі вводу перевірити переходи «немає підказок → є підказки → немає підказок». Порівняти координати поля і клавіш у кожному стані. Перевірити також числову розкладку та повторний показ клавіатури.
4. Запустити тести iOS і оновити локальну збірку на під’єднаному iPhone після перевірок.

## English

Reserve the suggestion strip and keep height constant for each orientation. Change its content without shifting the host field or key rows. Verify empty, populated and cleared states, the numeric page, and a signed local build.
