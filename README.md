<p align="center">
  <img src="src/zpeek-icon-v2.png" alt="zpeek — terminal database client" width="180">
</p>

<h1 align="center">zpeek</h1>

<p align="center">A fast terminal client for PostgreSQL, MySQL/MariaDB, SQLite, ClickHouse and compatible databases, in the spirit of Claude Code.</p>

<p align="center"><a href="#english">English</a> · <a href="#русский">Русский</a></p>

---

## English

### Why

Desktop database GUIs are heavy, and `psql`, `mysql`, `sqlite3` and `clickhouse-client` each have their own commands and are awkward for browsing data.
zpeek gives you **one tool for all of them** right in the terminal: type SQL or `/commands` in a prompt, see results as tables, browse data full-screen.

### Highlights

- **One binary, no dependencies.** No libpq, libmysqlclient or system SQLite needed: the drivers are written in Zig and SQLite is built in.
- **Many databases, one interface.** The same commands everywhere — see [supported databases](#supported-databases).
- **Schema at a glance.** Tables, views, enum values and other types, functions, triggers, and their source code.
- **Comfortable SQL console.** Syntax highlighting; completion that knows the SQL dialect and the current schema (`SE` → `SELECT`, tables after `FROM`, columns after `WHERE`, including aliases); history; saved queries.
- **Data browser.** Full-screen table with server-side `WHERE` filters, row count on demand, sorting, paging, hiding columns, copying, and deleting a row with confirmation.
- **Safe by default.** `DELETE` without `WHERE` is refused; queries run in the background and `ctrl+c` cancels them on the server.
- **Secure connections.** TLS with optional certificate verification, SCRAM-SHA-256, `caching_sha2_password`.

### Supported databases

| Database | Connect with | Status |
|---|---|---|
| PostgreSQL | `postgres://` | full support |
| MySQL, MariaDB | `mysql://`, `mariadb://` | full support |
| SQLite | file path or `sqlite://` | full support (no types/functions in SQLite) |
| ClickHouse | `clickhouse://` (HTTP interface) | full support; row delete in `/browse` is disabled |
| CockroachDB, YugabyteDB | `postgres://` | tested |
| TiDB | `mysql://` | tested (TiDB has no functions/triggers) |
| Redshift, Aurora, Neon, Supabase, AlloyDB | `postgres://` | PostgreSQL protocol, not tested |
| PlanetScale/Vitess, Aurora MySQL, SingleStore | `mysql://` | MySQL protocol, not tested |

### Install

**macOS, Linux, WSL, Git Bash** — downloads the latest release, verifies its checksum and adds `zpeek` to your `PATH`; run it again to update:

```sh
curl -fsSL https://raw.githubusercontent.com/aleksandraleksandrov/zpeek/main/install.sh | bash
```

**Windows (PowerShell):**

```powershell
irm https://raw.githubusercontent.com/aleksandraleksandrov/zpeek/main/install.ps1 | iex
```

Set `ZPEEK_VERSION=v1.2.3` to install a specific release, `ZPEEK_INSTALL_DIR` to choose the folder. Linux builds are static and run on any distribution. Check with `zpeek --version`.

Or build from source with Zig 0.17.0:

```sh
zig build -Doptimize=ReleaseSafe --prefix ~/.local   # installs ~/.local/bin/zpeek
```

### Connect

```sh
zpeek                                          # default connection from the config, or pick from a list
zpeek prod                                     # a named connection from the config
zpeek postgres://user:pass@host:5432/db        # URL; the scheme picks the driver
zpeek clickhouse://user:pass@host:8123/db
zpeek ./data.sqlite                            # SQLite file
zpeek "host=localhost dbname=app user=me"      # libpq keyword string
zpeek "user:pass@tcp(host:3306)/db"            # Go MySQL DSN
zpeek --driver mysql --host 127.0.0.1 --user root --database shop
zpeek prod -e "select count(*) from users"     # run SQL, print the result and exit
zpeek --list                                   # configured connections
zpeek --init-config                            # write an example config
```

- **Password:** from the URL, `--password`, or `$PGPASSWORD` / `$MYSQL_PWD` / `$CLICKHOUSE_PASSWORD`.
- **TLS:** `?sslmode=disable|prefer|require|verify-ca|verify-full` (MySQL spellings `ssl-mode`, `tls=true` work too). The default `prefer` uses TLS when the server offers it; `require` encrypts without checking the certificate; `verify-ca` checks it against the system CA store, `verify-full` also checks the host name.
- **ClickHouse** uses the HTTP interface: port 8123, or HTTPS on 8443 / with `sslmode=require`.

### Config

`~/.config/zpeek/config.toml` (or `$ZPEEK_CONFIG`, `$XDG_CONFIG_HOME/zpeek/`, `%APPDATA%\zpeek\` on Windows):

```toml
default = "local"

[connections.local]
url = "postgres://postgres@localhost:5432/app"
color = "#2F6B43"                   # connection name badge background throughout the UI

[connections.shop]
driver = "mysql"                    # postgres | mysql | mariadb | sqlite | clickhouse
host = "127.0.0.1"
port = 3306
user = "root"
password_env = "SHOP_DB_PASSWORD"   # or password = "…"
database = "shop"
sslmode = "require"

[connections.notes]
path = "~/notes.db"
```

Fields override the matching parts of `url`. Saved queries live in `queries/*.sql` next to the config; history in `~/.local/state/zpeek/history`.

### Commands

| Command | Alias | |
|---|---|---|
| `/connect [name\|url]` | `/c` | connect; without an argument, pick from the config |
| `/disconnect` | | close the connection |
| `/tables`, `/views` | `/t`, `/v` | tables (with size and row estimate) and views |
| `/types` | `/enums` | user types and enum values |
| `/functions`, `/triggers` | `/fn` | functions/procedures and triggers |
| `/describe <table>` | `/d` | columns, indexes, constraints |
| `/browse <table> [where …]` | `/b` | table data full-screen; without an argument, pick a table |
| `/def <name>` | | source of a view, function, trigger or enum |
| `/save <name>` | | save the last SQL you ran |
| `/queries [name]` | `/sq` | pick a saved query (it goes into the input, not run) |
| `/unsave <name>` | | delete a saved query |
| `/databases`, `/refresh`, `/clear`, `/help`, `/quit` | `/dbs`, `/q` | |

Anything else is run as SQL; several statements can be separated by `;`. The feed shows the first 50 rows of a result (`ctrl+o` opens all of it); ad-hoc queries keep at most 10,000 rows and 16 MiB of row data. Scrollback keeps up to 200 entries and roughly 64 MiB of results. A lost connection is re-established once without replaying the failed SQL. `DELETE` without `WHERE` is refused.

### Keys

**Console**

| Key | |
|---|---|
| `enter` | run |
| `shift+enter`, `alt+enter`, `ctrl+j`, `\` at line end | new line |
| `tab` | complete; with the suggestion list open, `tab`/`enter` insert, `esc` closes it |
| `↑` `↓` | history (or move between lines) |
| `ctrl+o` | open the last result as a table |
| `pgup` `pgdn`, mouse wheel | scroll |
| `ctrl+c` | cancel query · clear input · exit (twice) |
| `ctrl+d` | exit (on empty input) |
| `ctrl+l` | clear the screen |

**Table view**

| Key | |
|---|---|
| `↑↓←→` / `hjkl`, `pgup` `pgdn`, `g` `G`, `0` `$` | move |
| `enter` | show the full value |
| `/` | filter: `WHERE …` in `/browse`; otherwise `text`, `column:text` or `column=value` |
| `t` | count rows matching the current `WHERE` in `/browse` |
| `s` | sort by the column (asc → desc → off) |
| `c` / `x` | choose columns / hide the current one |
| `n` / `p` | next / previous page (500 rows) |
| `r` / `F5` | refresh |
| `d` | delete the row (shows the SQL, `y` confirms; needs a primary key; not for ClickHouse) |
| `y` / `Y` | copy cell / row (OSC 52) |
| `q` / `esc` | back |

---

## Русский

### Зачем

Графические клиенты баз данных тяжёлые, а у `psql`, `mysql`, `sqlite3` и `clickhouse-client` свои команды, и данные в них смотреть неудобно.
zpeek — **один инструмент для всех этих баз** прямо в терминале: пишете SQL или `/команды` в строке ввода, видите результат таблицей, листаете данные на весь экран.

### Преимущества

- **Один бинарник без зависимостей.** Не нужны libpq, libmysqlclient или системный SQLite: драйверы написаны на Zig, SQLite встроен.
- **Много баз, один интерфейс.** Одинаковые команды везде — см. [поддерживаемые базы](#поддерживаемые-базы).
- **Схема под рукой.** Таблицы, view, значения enum и другие типы, функции, триггеры и их исходный код.
- **Удобная SQL-консоль.** Подсветка синтаксиса; автодополнение с учётом диалекта и текущей схемы (`SE` → `SELECT`, таблицы после `FROM`, колонки после `WHERE`, в том числе через алиасы); история; сохранённые запросы.
- **Просмотр данных.** Таблица на весь экран с фильтром `WHERE` на сервере, подсчётом строк по запросу, сортировкой, страницами, скрытием колонок, копированием и удалением строки с подтверждением.
- **Безопасно по умолчанию.** `DELETE` без `WHERE` не выполняется; запросы идут в фоне, `ctrl+c` отменяет их на сервере.
- **Защищённые подключения.** TLS с проверкой сертификата по желанию, SCRAM-SHA-256, `caching_sha2_password`.

### Поддерживаемые базы

| База | Как подключаться | Статус |
|---|---|---|
| PostgreSQL | `postgres://` | полная поддержка |
| MySQL, MariaDB | `mysql://`, `mariadb://` | полная поддержка |
| SQLite | путь к файлу или `sqlite://` | полная поддержка (типов и функций в SQLite нет) |
| ClickHouse | `clickhouse://` (HTTP-интерфейс) | полная поддержка; удаление строк в `/browse` отключено |
| CockroachDB, YugabyteDB | `postgres://` | проверено |
| TiDB | `mysql://` | проверено (функций и триггеров в TiDB нет) |
| Redshift, Aurora, Neon, Supabase, AlloyDB | `postgres://` | протокол PostgreSQL, не проверялось |
| PlanetScale/Vitess, Aurora MySQL, SingleStore | `mysql://` | протокол MySQL, не проверялось |

### Установка

**macOS, Linux, WSL, Git Bash** — скачает последнюю версию, проверит контрольную сумму и добавит `zpeek` в `PATH`; для обновления запустите снова:

```sh
curl -fsSL https://raw.githubusercontent.com/aleksandraleksandrov/zpeek/main/install.sh | bash
```

**Windows (PowerShell):**

```powershell
irm https://raw.githubusercontent.com/aleksandraleksandrov/zpeek/main/install.ps1 | iex
```

`ZPEEK_VERSION=v1.2.3` ставит конкретную версию, `ZPEEK_INSTALL_DIR` задаёт папку. Сборки для Linux статические и работают в любом дистрибутиве. Проверить: `zpeek --version`.

Или соберите из исходников (нужен Zig 0.17.0):

```sh
zig build -Doptimize=ReleaseSafe --prefix ~/.local   # установит ~/.local/bin/zpeek
```

### Подключение

```sh
zpeek                                          # подключение по умолчанию из конфига или выбор из списка
zpeek prod                                     # подключение по имени из конфига
zpeek postgres://user:pass@host:5432/db        # URL; драйвер определяется по схеме
zpeek clickhouse://user:pass@host:8123/db
zpeek ./data.sqlite                            # файл SQLite
zpeek "host=localhost dbname=app user=me"      # строка в формате libpq
zpeek "user:pass@tcp(host:3306)/db"            # DSN в стиле Go MySQL
zpeek --driver mysql --host 127.0.0.1 --user root --database shop
zpeek prod -e "select count(*) from users"     # выполнить SQL, вывести результат и выйти
zpeek --list                                   # подключения из конфига
zpeek --init-config                            # создать пример конфига
```

- **Пароль:** из URL, `--password` или `$PGPASSWORD` / `$MYSQL_PWD` / `$CLICKHOUSE_PASSWORD`.
- **TLS:** `?sslmode=disable|prefer|require|verify-ca|verify-full` (для MySQL также `ssl-mode`, `tls=true`). По умолчанию `prefer`: TLS, если сервер его предлагает; `require` шифрует без проверки сертификата; `verify-ca` проверяет сертификат по системным корневым сертификатам, `verify-full` — ещё и имя хоста.
- **ClickHouse** подключается через HTTP-интерфейс: порт 8123, HTTPS — порт 8443 или `sslmode=require`.

### Конфиг

`~/.config/zpeek/config.toml` (или `$ZPEEK_CONFIG`, `$XDG_CONFIG_HOME/zpeek/`, `%APPDATA%\zpeek\` в Windows):

```toml
default = "local"

[connections.local]
url = "postgres://postgres@localhost:5432/app"
color = "#2F6B43"                   # фон плашки с названием подключения во всём интерфейсе

[connections.shop]
driver = "mysql"                    # postgres | mysql | mariadb | sqlite | clickhouse
host = "127.0.0.1"
port = 3306
user = "root"
password_env = "SHOP_DB_PASSWORD"   # или password = "…"
database = "shop"
sslmode = "require"

[connections.notes]
path = "~/notes.db"
```

Отдельные поля переопределяют соответствующие части `url`. Сохранённые запросы лежат в `queries/*.sql` рядом с конфигом, история — в `~/.local/state/zpeek/history`.

### Команды

| Команда | Сокращение | |
|---|---|---|
| `/connect [имя\|url]` | `/c` | подключиться; без аргумента — выбор из конфига |
| `/disconnect` | | закрыть подключение |
| `/tables`, `/views` | `/t`, `/v` | таблицы (с размером и оценкой числа строк) и view |
| `/types` | `/enums` | пользовательские типы и значения enum |
| `/functions`, `/triggers` | `/fn` | функции и процедуры, триггеры |
| `/describe <таблица>` | `/d` | колонки, индексы, ограничения |
| `/browse <таблица> [where …]` | `/b` | данные таблицы на весь экран; без аргумента — выбор таблицы |
| `/def <имя>` | | исходный код view, функции, триггера или enum |
| `/save <имя>` | | сохранить последний выполненный SQL |
| `/queries [имя]` | `/sq` | выбрать сохранённый запрос (попадает в строку ввода, не выполняется) |
| `/unsave <имя>` | | удалить сохранённый запрос |
| `/databases`, `/refresh`, `/clear`, `/help`, `/quit` | `/dbs`, `/q` | |

Всё остальное выполняется как SQL; несколько запросов разделяются `;`. В ленте показываются первые 50 строк результата (`ctrl+o` открывает весь), для произвольных запросов хранится не больше 10 000 строк и 16 МиБ данных строк. Лента хранит до 200 записей и примерно 64 МиБ результатов. После обрыва соединения zpeek один раз переподключается без повторного выполнения неудавшегося SQL. `DELETE` без `WHERE` не выполняется.

### Клавиши

**Консоль**

| Клавиша | |
|---|---|
| `enter` | выполнить |
| `shift+enter`, `alt+enter`, `ctrl+j`, `\` в конце строки | новая строка |
| `tab` | автодополнение; при открытом списке `tab`/`enter` вставляют вариант, `esc` закрывает список |
| `↑` `↓` | история (или переход между строками) |
| `ctrl+o` | открыть последний результат таблицей |
| `pgup` `pgdn`, колесо мыши | прокрутка |
| `ctrl+c` | отменить запрос · очистить ввод · выйти (дважды) |
| `ctrl+d` | выйти (при пустом вводе) |
| `ctrl+l` | очистить экран |

**Просмотр таблицы**

| Клавиша | |
|---|---|
| `↑↓←→` / `hjkl`, `pgup` `pgdn`, `g` `G`, `0` `$` | перемещение |
| `enter` | значение целиком |
| `/` | фильтр: `WHERE …` в `/browse`; иначе `текст`, `колонка:текст` или `колонка=значение` |
| `t` | подсчитать строки с учётом текущего `WHERE` в `/browse` |
| `s` | сортировка по колонке (по возрастанию → по убыванию → выкл.) |
| `c` / `x` | выбрать колонки / скрыть текущую |
| `n` / `p` | следующая / предыдущая страница (по 500 строк) |
| `r` / `F5` | обновить |
| `d` | удалить строку (показывает SQL, `y` подтверждает; нужен первичный ключ; не для ClickHouse) |
| `y` / `Y` | копировать ячейку / строку (OSC 52) |
| `q` / `esc` | назад |
