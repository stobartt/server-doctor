# server-doctor

`server-doctor` собирает read-only снимок ресурсов Debian/Ubuntu-сервера в одну
папку и ZIP-архив для последующего локального анализа, в том числе с помощью
ИИ. Основная задача отчёта — объяснить нехватку памяти или диска, показать
ресурсоёмкие процессы и Docker-объекты, а также выделить категории ошибок и
кандидатов на очистку.

Makefile служит интерфейсом; сбор выполняют отдельные Bash-коллекторы. Утилита
ничего не устанавливает и не исправляет: не меняет конфигурацию, не
перезапускает сервисы и никогда не удаляет Docker-объекты.

## Установка и запуск из домашней папки

Для установки требуется пакет `make`. Если его нет, установите пакет обычным
для сервера способом, затем в каталоге checkout выполните установку без `sudo`:

```bash
sudo apt-get install --yes make
make install-user
```

Установка сохраняет runtime в версионированной папке внутри
`~/.local/share/server-doctor/` и атомарно создаёт symlink `~/server-doctor`.
Повторная установка создаёт чистую новую release-папку, поэтому удалённый из
новой версии коллектор не останется от старой. Других путей установки или имён
launcher утилита не поддерживает. Если `~/server-doctor` уже занят обычным
файлом или каталогом, установка завершится ошибкой и ничего не перезапишет.

После этого из домашней папки или любого другого рабочего каталога запускайте:

```bash
cd ~
~/server-doctor doctor --profile standard --since 24h
```

Preflight выполняется до создания отчёта. Если обязательной команды нет, он
останавливается, печатает название нужного Debian/Ubuntu-пакета и готовую
команду установки. Установите пакет сами и повторите `doctor`; неполный архив с
тихой деградацией не создаётся. Отсутствие самой технологии, например Docker,
ошибкой не считается.

Профили `standard` и `deep` требуют накопленной истории PCP; все профили —
истории sysstat. Если сервисы ещё не включены, preflight напечатает команды.
После первого включения прошлые данные не появятся задним числом: дождитесь
накопления новых samples и повторите проверку.

Когда `doctor` завершился успешно:

```bash
sudo ~/server-doctor audit --profile standard --since 24h
```

Архив появится в `./artifacts` относительно текущего каталога. При запуске из
домашней папки это будет `~/artifacts`. После скачивания проверьте архив:

```bash
~/server-doctor verify --archive /path/to/server-doctor_20260813T120000Z.zip
```

## Профили

| Профиль | Что собирает | Активный замер |
|---|---|---:|
| `quick` | Текущий ресурсный снимок, процессы, Docker, systemd и агрегаты ошибок; без полного обхода диска, размеров Docker volumes и PCP | 15 с |
| `standard` | Рекомендуемый: всё основное, топ файлов/каталогов, размеры Docker volumes, история PCP/sysstat | 60 с |
| `deep` | Standard плюс расширенный SMART health/attributes | 120 с |

Примеры:

```bash
sudo ~/server-doctor audit --profile quick --since 6h
sudo ~/server-doctor audit --profile standard --since 24h
sudo ~/server-doctor audit --profile deep --since 48h --observe-seconds 180
sudo ~/server-doctor audit --output /srv/secure-export --max-report-mib 2048
```

`SINCE` принимает положительное число и единицу `m`, `h`, `d` или `w`, максимум
30 дней. Полный сбор требует root, иначе PSS, journal, Docker, SMART и сведения
об открытых удалённых файлах могут оказаться неполными. Поэтому `audit`
останавливается заранее, если запущен без root.

## Зависимости без деградации

Базово проверяются Bash 4+, `make`, coreutils, procps, util-linux, findutils,
gawk, grep, sed, sysstat, jq, zip/unzip и lsof. Для `standard/deep` дополнительно
требуется PCP, для `deep` — smartmontools. При шифровании требуется `age`.

Правило условных технологий:

- Docker отсутствует — раздел помечается `NOT_APPLICABLE`, аудит продолжается;
- Docker обнаружен — CLI и доступ к daemon обязательны, иначе preflight
  показывает пакет/ошибку и останавливает сбор;
- необязательный инструмент не установлен — preflight предлагает пакет,
  пользователь устанавливает его и заново запускает аудит.

Утилита не устанавливает пакеты автоматически и не создаёт «облегчённую»
версию отчёта вместо заявленного профиля.

## На какие вопросы отвечает архив

- сколько RAM действительно доступно с учётом reclaimable cache, используется
  ли swap и есть ли memory pressure/OOM;
- какие процессы занимают больше всего RSS, PSS, private memory и swap, как
  менялась их CPU/memory/I/O активность во время наблюдения; если per-process
  metrics уже логировались PCP, сохраняются и их исторические min/max/average;
- какие systemd services и Docker containers потребляют память/CPU/I/O,
  перезапускались, были OOM-killed или unhealthy;
- какие Docker volumes самые тяжёлые и какие из них не привязаны ни к одному
  контейнеру;
- какие images не используются ни одним, включая остановленные, контейнером;
- какие stopped containers являются кандидатами на ручную проверку и очистку;
- сколько места занимают writable layers и log-файлы контейнеров;
- какие локальные filesystems/inodes близки к заполнению, какие файлы и каталоги
  занимают больше всего места, остаются ли открытые удалённые файлы;
- какие категории ошибок встречались за окно `SINCE`: OOM, panic, segfault,
  timeout, storage, permission, connection и общие failure/error;
- были ли kernel storage/hung-task события, нужен ли reboot и доступны ли
  обновления пакетов.

Кандидаты на очистку не удаляются автоматически. «Stopped container» сам по
себе не доказывает, что объект больше не нужен. Image считается unreferenced,
только если на неё не ссылается ни один контейнер; volume — если Docker помечает
её dangling. Перед удалением всё равно нужна ручная проверка.

Суммировать размеры отдельных images нельзя: слои могут быть общими. Поэтому
`docker/disk-usage.jsonl` содержит безопасную агрегированную оценку Docker для
images, containers, local volumes и build cache, а таблицы отдельных объектов
используются для ранжирования и поиска кандидатов, но не как сумма reclaimable.

## Что намеренно не попадает в отчёт

Отчёт спроектирован как privacy-minimized пакет для внешнего анализа. В него не
включаются:

- имена и списки пользователей, UID/account/group inventory и пользовательские
  домашние пути;
- hostname, сетевые адреса, routes, sockets, listening endpoints, DNS, firewall
  и Docker networks;
- SSH, sysctl, firewall, daemon, container и application configuration;
- аргументы и environment процессов, shell history, `.env`, secrets, keys,
  certificates, Docker configs/secrets;
- repository names/digests images, bind-mount source paths, Docker log paths;
- сырые system/application/container log messages и сырой PCP archive.

Ошибки приложений и контейнеров экспортируются только как фиксированные
категории, счётчики и идентификатор соответствующего service/container. Для
kernel-событий сохраняется диагностический текст, но он проходит редактирование.
Пути топ-файлов сохраняются для поиска потребителя диска; компоненты домашних
каталогов пользователей заменяются маркером.

Перед упаковкой выполняется fail-closed privacy scan всего отчёта. Если после
редактирования остаётся похожая на адрес, endpoint или пользовательский home
path строка, ZIP не создаётся, а локальная `.partial`-папка остаётся для
проверки администратором. Результат успешного контроля записывается в
`privacy-scan.txt`.

Операционные идентификаторы процессов, services, containers, volumes, devices
и путей вне пользовательских home сохраняются: без них нельзя привязать
потребление ресурсов к объекту. Их нужно передавать в соответствии с внутренней
политикой компании.

## Состав результата

```text
server-doctor_20260813T120000Z/
├── README.md
├── summary.md
├── manifest.json
├── privacy-scan.txt
├── checks.tsv
├── collection.log
├── system/
├── performance/
├── storage/
├── systemd/
├── docker/
├── logs/
├── security/
├── pcp/
└── SHA256SUMS
server-doctor_20260813T120000Z.zip
server-doctor_20260813T120000Z.zip.sha256
```

Начинайте анализ с `summary.md`. Подробные process PSS находятся в
`performance/process-memory.tsv`, временные samples — рядом; Docker cleanup
candidates и volume sizes лежат в `docker/`; агрегаты ошибок — в `logs/` и
`docker/error-summary.tsv`; историческая сводка процессов при наличии данных —
в `pcp/process-summary.tsv`. `checks.tsv` показывает runtime-сбои, timeout и
truncation каждой проверки.

## Ограничение нагрузки и целостность

- `umask 077`, каталог отчёта имеет режим `0700`;
- каждая команда имеет timeout и лимит размера результата;
- полный отчёт ограничен `MAX_REPORT_MIB`;
- тяжёлые обходы выполняются с `nice`/`ionice` и не переходят границы локальной
  filesystem;
- одновременно для одного output-каталога выполняется только один audit;
- после `sudo` итоговые файлы возвращаются исходному пользователю;
- внутри отчёта и рядом с архивом создаются SHA-256 checksums.

Для дополнительного шифрования публичным ключом age:

```bash
sudo ~/server-doctor audit --profile standard --encrypt-to age1example...
~/server-doctor verify --archive ./artifacts/server-doctor_timestamp.zip.age
```

После успешного шифрования plaintext ZIP удаляется; остаются `.zip.age` и его
checksum. Для проверки структуры сначала расшифруйте архив.

## Разработка

```bash
make lint
make test
make check
```

Коллекторы находятся в `collectors/`, общие timeout/лимиты/редактирование — в
`lib/`. Новая проверка должна быть read-only, не читать конфигурацию или secret
sources, использовать allowlist полей и проходить общий privacy scan.
