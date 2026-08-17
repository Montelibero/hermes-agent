# Hermes Agent: эксплуатация fork-образа

Эта памятка относится к сборке ветки `deploy` форка
`Montelibero/hermes-agent`. Текущая базовая версия —
стабильный релиз `v2026.8.16` (`v0.20.2`).

Канонические файлы контейнера находятся в самом проекте:

- `Dockerfile`;
- `docker-compose.yml`;
- каталог `docker/`.

Если поведение памятки расходится с ними, приоритет у файлов стабильного
релиза.

## Образ и ветка

GitHub Actions собирает образ только из ветки `deploy`:

```text
ghcr.io/montelibero/hermes-agent:latest
ghcr.io/montelibero/hermes-agent:sha-<commit>
```

`latest` удобен для обычного обновления. Для воспроизводимого отката
используйте неизменяемый `sha-<commit>`.

Локальная сборка:

```bash
docker build --platform linux/amd64 --target deploy-rootless \
  -t hermes-agent:local .
```

Скрипт `build.sh` обновляет текущую ветку только через fast-forward и собирает
этот локальный образ.

## Постоянные данные

Внутри контейнера Hermes использует:

```text
HERMES_HOME=/opt/data
```

Один постоянный bind mount или volume на `/opt/data` сохраняет:

- `config.yaml`;
- `.env` с секретами Hermes;
- `auth.json`;
- сессии, память и логи;
- установленные skills и плагины;
- cron-задачи;
- профили в `/opt/data/profiles`;
- runtime-кэши и локальные зависимости.

Для серверного инстанса достаточно сопоставить отдельный каталог данных,
например `/srv/hermes/herald`, с `/opt/data`. Не монтируйте поверх
`/opt/hermes`: код и зависимости уже находятся в образе.

Если агенту нужна рабочая папка, создайте её внутри постоянного каталога
данных, например `/opt/data/workspace`, и укажите:

```yaml
terminal:
  cwd: /opt/data/workspace
```

`terminal.cwd` — каноническая настройка messaging-режима. Секреты остаются в
хранилище Hermes, а не в публичном stack-файле.

## UID и GID

Fork-образ из ветки `deploy` использует target `deploy-rootless`. Он не
запускает s6-overlay, не получает root и не меняет владельцев bind mounts.
Укажите числовой UID и GID, разрешённые на конкретном сервере:

```yaml
user: "1000:1000"
```

На другом сервере значения могут отличаться без пересборки образа. Каталоги,
подключаемые к `/opt/data` и рабочей директории, должны быть заранее доступны
этому UID/GID на запись.

Не задавайте `HERMES_UID`, `HERMES_GID`, `PUID` или `PGID`: rootless-образ не
меняет свою учётную запись во время запуска.

Рекомендуемые ограничения контейнера:

```yaml
read_only: true
cap_drop:
  - ALL
security_opt:
  - no-new-privileges:true
tmpfs:
  - /tmp:rw,noexec,nosuid,nodev,size=134217728,mode=1777
```

Не подключайте отдельный `/run`: rootless target его не использует.

## Команды контейнера

Не переопределяйте entrypoint. Образ использует:

```text
/usr/local/bin/tini -- /opt/hermes/docker/rootless-entrypoint.sh
```

Аргументы контейнера передаются CLI Hermes:

```bash
docker run --rm hermes-agent:local --version
docker run --rm hermes-agent:local --help
```

Для gateway команда контейнера:

```text
gateway run
```

Для dashboard как единственного основного процесса контейнера:

```text
dashboard --host 127.0.0.1 --no-open
```

При `docker exec` вызывайте `hermes` обычным способом. Команда выполняется под
тем же UID/GID, который задан контейнеру:

```bash
docker exec hermes hermes --version
docker exec hermes hermes logs --level warning
```

## Первичная настройка

Создайте отдельный постоянный каталог данных и запустите контейнер с
подключённым `/opt/data`. Настройку модели, API-ключей и messaging-платформ
выполняйте штатным setup-интерфейсом Hermes или через защищённый интерфейс
управления сервером.

Не публикуйте наружу dashboard без аутентификации. Стандартный
`docker-compose.yml` привязывает его к `127.0.0.1`; для удалённого доступа
используйте SSH-туннель или reverse proxy с обязательной аутентификацией.

## Несколько инстансов и профили

Есть две разные схемы:

1. Один контейнер и несколько Hermes profiles. Их данные находятся в
   `/opt/data/profiles/<name>`, а маршрутизацию включает
   `gateway.multiplex_profiles`.
2. Несколько полностью независимых контейнеров. Каждый получает собственный
   каталог `/opt/data`, имя контейнера и сетевые порты.

Для нескольких Telegram-ботов используйте разные bot token. Один токен не
должен одновременно обслуживаться несколькими gateway-инстансами.

Пример раскладки независимых данных на хосте:

```text
/srv/hermes/herald
/srv/hermes/support
/srv/hermes/research
```

Общие bind mounts между этими каталогами ломают изоляцию профилей и усложняют
откат.

## Обновление и откат

Обновление:

1. Дождаться успешной сборки ветки `deploy`.
2. Зафиксировать текущий `sha-*` образ для возможного отката.
3. Получить новый образ.
4. Пересоздать контейнер без удаления `/opt/data`.
5. Проверить логи, gateway и подключённые платформы.

Откат выполняется переключением на предыдущий `sha-*`. Постоянные данные
перед обновлением нужно резервировать отдельно: откат образа не откатывает
`config.yaml`, базу сессий и миграции данных.

## Быстрая диагностика

```bash
docker ps --filter name=hermes
docker logs --tail 200 hermes
docker exec hermes hermes --version
```

Проверяйте в первую очередь:

- доступность и владельца каталога `/opt/data`;
- корректность `terminal.cwd`;
- отсутствие ручного override entrypoint;
- уникальность токенов messaging-платформ;
- тег реально запущенного образа.
