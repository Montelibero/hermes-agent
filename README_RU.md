# Hermes Agent: заметки по запуску в Docker

Этот файл собран как короткая практическая памятка по тому, что мы обсудили:

- запуск Hermes Agent в Docker
- хранение всех записываемых данных в `~/.hermes`
- запуск нескольких независимых инстансов
- особенности использования в Telegram

## Базовая идея

Для этого проекта удобно считать `~/.hermes` основной writable-зоной.

Именно там Hermes обычно хранит:

- `config.yaml`
- `.env`
- `state.db`
- `sessions/`
- `logs/`
- `skills/`
- `memories/`
- `pairing/`
- `image_cache/`
- `audio_cache/`
- `document_cache/`

Это хорошо сочетается с Docker-схемой, где:

- код проекта лежит в контейнере
- все пользовательские данные и runtime-состояние пишутся в `~/.hermes`
- рабочая папка монтируется отдельно, если агенту нужен доступ к файлам

Для Telegram gateway на практике нужен ещё один writable-путь:

- `~/.local/state/hermes/gateway-locks`

Иначе контейнер может падать при старте с ошибкой про read-only filesystem.

Если используются локальные browser tools, нужен ещё один writable-путь:

- `~/.agent-browser`

Иначе `agent-browser` не сможет нормально управлять локальным браузерным демоном и сессиями.

## Файлы Docker

В репозитории добавлены:

- [`Dockerfile`](/home/attid/projects/hermes-agent/Dockerfile)
- [`docker-compose.yml`](/home/attid/projects/hermes-agent/docker-compose.yml)
- [`.dockerignore`](/home/attid/projects/hermes-agent/.dockerignore)

Текущий Docker-образ также включает локальные browser tools:

- `agent-browser`
- локальный Chromium для `browser_navigate`, `browser_click` и связанных инструментов

Текущая схема запуска:

- `HERMES_HOME=/home/hermes/.hermes`
- `HOME=/home/hermes`
- `MESSAGING_CWD=/workspace`
- volume `${HOME}/.hermes:/home/hermes/.hermes`
- volume `${HOME}/.local:/home/hermes/.local`
- volume `${HOME}/.agent-browser:/home/hermes/.agent-browser`
- volume `./workspace:/workspace`

То есть Hermes пишет всё важное в примонтированную папку `.hermes`, а рабочие файлы держит отдельно.
Для gateway также нужен writable-каталог `.local`.
Локальные browser tools теперь могут работать прямо внутри контейнера, без Browserbase.
Для них также нужен writable-каталог `.agent-browser`.

## Быстрый старт

Создать каталоги:

```bash
mkdir -p ~/.hermes ~/.local ~/.agent-browser ./workspace
```

Подготовить конфиг:

```bash
cp cli-config.yaml.example ~/.hermes/config.yaml
touch ~/.hermes/.env
```

Минимум для Telegram в `~/.hermes/.env`:

```env
TELEGRAM_BOT_TOKEN=...
TELEGRAM_ALLOWED_USERS=123456789
OPENROUTER_API_KEY=...
```

Запуск:

```bash
docker compose build
docker compose up -d
docker compose logs -f
```

## Почему удобно писать именно в `~/.hermes`

Плюсы такой схемы:

- всё состояние лежит в одном месте
- проще делать backup
- проще переносить инстанс между серверами
- проще запускать несколько отдельных агентов
- не нужно отдельно вылавливать десятки runtime-папок

Это не максимально жёсткая изоляция, но для обычной практической эксплуатации это нормальный баланс.

## Важное уточнение по `.local`

Во время реального запуска в Docker/Swarm выяснилось, что Hermes gateway пытается создать lock-файлы в:

- `/home/hermes/.local/state/hermes/gateway-locks`

Если `/home/hermes/.local` недоступен на запись, gateway падает с ошибкой вида:

```text
OSError: [Errno 30] Read-only file system: '/home/hermes/.local'
```

Поэтому для контейнерного Telegram-инстанса нужно считать обязательными writable-каталоги:

- `.hermes`
- `.local`
- `.agent-browser`
- `workspace`

## Несколько инстансов

Да, можно запускать несколько независимых контейнеров.

Главное правило: у каждого инстанса должен быть свой отдельный каталог данных.

Пример идеи:

- `/srv/hermes/a`
- `/srv/hermes/b`
- `/srv/hermes/c`

У каждого инстанса свои:

- `.env`
- `config.yaml`
- `state.db`
- `sessions/`
- `logs/`
- навыки и память

Если нужен отдельный рабочий каталог, можно дать каждому ещё и свой `workspace`.

Пример логики:

- инстанс A -> `/srv/hermes/a` и `/srv/hermes/a-work`
- инстанс B -> `/srv/hermes/b` и `/srv/hermes/b-work`
- инстанс C -> `/srv/hermes/c` и `/srv/hermes/c-work`

## Важное про Telegram и несколько инстансов

Если это три разных Telegram-бота, всё нормально: у каждого должен быть свой `TELEGRAM_BOT_TOKEN`.

Если попытаться запустить несколько контейнеров с одним и тем же `TELEGRAM_BOT_TOKEN`, возможны конфликты polling/webhook-сессий. Проще считать это плохой схемой.

Практически:

- один бот = один токен = один контейнер gateway
- если нужно три независимых бота, делай три токена и три отдельных каталога данных

## Работа в чатах с несколькими пользователями

Hermes можно использовать в Telegram не только в личке, но тут важно понимать ограничения.

Что у него есть:

- allowlist пользователей
- DM pairing для подтверждения доступа
- approval для опасных команд в messaging-режиме
- возможность ограничить доступ к файловым и терминальным инструментам

Чего у него нет как гарантии безопасности:

- он не умеет надёжно "сам понять", кто владелец, а кто вредитель
- он не является полноценной системой trust/identity для групповых чатов
- нельзя полагаться на то, что агент по контексту переписки безопасно отличит легитимную команду от атаки

Вывод:

- безопасность строится на конфиге доступа и ограничениях инструментов
- не на "умном распознавании" намерений пользователей

## Практическая безопасная схема для Telegram

Если бот используется в основном через Telegram, разумно придерживаться такой модели:

- полный доступ давать только в личке
- в группах использовать сильно урезанный набор инструментов
- обязательно настраивать `TELEGRAM_ALLOWED_USERS`
- по возможности держать `MESSAGING_CWD` в отдельной рабочей папке
- не давать слишком широкий доступ к хостовым каталогам

Если боту не нужен доступ ко всей файловой системе, не надо монтировать весь home.

Лучше так:

- `~/.hermes` для данных агента
- `~/.local` для gateway lock/state файлов
- `~/.agent-browser` для локального browser backend
- отдельная папка типа `./workspace` для рабочих файлов

## Что считать хорошей практикой

- хранить конфиг и секреты в `~/.hermes`
- для Docker/Swarm дополнительно монтировать writable `~/.local`
- для локальных browser tools дополнительно монтировать writable `~/.agent-browser`
- запускать один Telegram gateway на один bot token
- для каждого инстанса иметь свой отдельный каталог данных
- ограничивать рабочую директорию
- не давать общий терминальный доступ в публичные чаты
- проверять, какие toolsets реально нужны для конкретного инстанса

## Browser tools в Docker

В текущем Docker-образе уже встроены локальные browser tools:

- установлен `agent-browser`
- во время сборки устанавливается локальный Chromium

Это значит, что для базового browser automation в контейнере не нужен Browserbase.

Cloud-варианты по-прежнему опциональны:

- `BROWSERBASE_API_KEY` + `BROWSERBASE_PROJECT_ID`
- или `BROWSER_USE_API_KEY`

Если этих переменных нет, Hermes должен использовать локальный headless browser внутри контейнера.

### Важное уточнение по `.agent-browser`

Во время реального запуска в Docker выяснилось, что локальный browser backend пишет служебные файлы в:

- `/home/hermes/.agent-browser`

Если контейнер read-only и этот путь не примонтирован как writable volume, browser tools не смогут нормально работать, даже если:

- `agent-browser` установлен
- Chromium успешно скачан в образ

Типичный симптом:

```text
~/.agent-browser — read-only файловая система
```

## Короткий итог

Для обычного self-hosted сценария схема такая:

1. Docker-контейнер с Hermes Agent
2. Все основные записи в отдельный каталог `~/.hermes`
3. Отдельный writable-каталог `~/.local` для gateway lock/state файлов
4. Отдельный writable-каталог `~/.agent-browser` для локального browser backend
5. Отдельный `workspace` для файловой работы
6. Отдельный каталог данных на каждый инстанс
7. Для Telegram-групп полагаться на allowlist и ограничения toolsets, а не на "интуицию" агента

Этого достаточно, чтобы запуск был удобным, переносимым и без лишнего хаоса в файловой системе.

## Пример Portainer / Swarm stack

Рабочий минимальный вариант для одного инстанса:

```yaml
version: "3.8"

services:
  herald:
    image: hermes-agent:latest
    command: ["python", "-m", "hermes_cli.main", "gateway"]
    environment:
      HOME: /home/hermes
      HERMES_HOME: /home/hermes/.hermes
      MESSAGING_CWD: /workspace
    volumes:
      - /apps/hermes/herald/.hermes:/home/hermes/.hermes
      - /apps/hermes/herald/.local:/home/hermes/.local
      - /apps/hermes/herald/.agent-browser:/home/hermes/.agent-browser
      - /apps/hermes/herald/workspace:/workspace
    tmpfs:
      - /tmp:size=536870912
      - /var/tmp:size=268435456
    deploy:
      replicas: 1
      restart_policy:
        condition: any
```

Перед deploy:

```bash
mkdir -p /apps/hermes/herald/.hermes
mkdir -p /apps/hermes/herald/.local
mkdir -p /apps/hermes/herald/.agent-browser
mkdir -p /apps/hermes/herald/workspace
```
