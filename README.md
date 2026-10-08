<p align="center">
  <img src="src/zpeek-icon-v2.png" alt="zpeek — terminal database client" width="180">
</p>

<h1 align="center">zpeek</h1>

<p align="center">A fast terminal client for PostgreSQL, MySQL/MariaDB and SQLite, in the spirit of Claude Code.</p>

<p align="center"><a href="#english">English</a> · <a href="#русский">Русский</a></p>

---

## English

### Why

Desktop database GUIs are heavy, and `psql` / `mysql` / `sqlite3` each have their own commands and are awkward for browsing data.
zpeek gives you **one tool for all three databases** right in the terminal: type SQL or `/commands` in a prompt, see results as tables, browse data full-screen.

### Highlights

- **One binary, no dependencies.** No libpq, libmysqlclient or system SQLite needed: the drivers are written in Zig and SQLite is built in.
- **All three databases, one interface.** PostgreSQL, MySQL, MariaDB and SQLite with the same commands.
- **Schema at a glance.** Tables, views, enum values and other types, functions, triggers, and their source code.
- **Comfortable SQL console.** Syntax highlighting, Tab completion for tables, columns (including aliases) and keywords, history, multi-statement input.
- **Data browser.** Full-screen table with server-side `WHERE` filters, sorting, paging and copy to clipboard.
- **Responsive.** Queries run in the background; `ctrl+c` cancels a long query on the server.
- **Secure connections.** TLS, SCRAM-SHA-256, `caching_sha2_password`.

### Install

macOS, Linux or Windows (Git Bash / WSL). This downloads the latest release and adds `zpeek` to your `PATH`; run it again to update:

```sh
curl -fsSL https://raw.githubusercontent.com/aleksandraleksandrov/zpeek/main/install.sh | bash
```

Or build from source with Zig 0.17.0:

```sh
zig build -Doptimize=ReleaseSafe --prefix ~/.local   # installs ~/.local/bin/zpeek
```

### Connect

```sh
zpeek                                       # default connection from the config, or pick from a list
zpeek prod                                  # a named connection from the config
zpeek postgres://user:pass@host:5432/db     # URL: postgres://, mysql://, mariadb://, sqlite://
zpeek ./data.sqlite                         # SQLite file
zpeek --driver mysql --host 127.0.0.1 --user root --database shop
zpeek prod -e "select count(*) from users"  # run one query and exit
```

The password can also come from `$PGPASSWORD` / `$MYSQL_PWD`. TLS: `?sslmode=disable|prefer|require` (default `prefer`).

Save connections in `~/.config/zpeek/config.toml` (`zpeek --init-config` creates an example):

```toml
default = "local"

[connections.local]
url = "postgres://postgres@localhost:5432/app"

[connections.shop]
driver = "mysql"
host = "127.0.0.1"
user = "root"
password_env = "SHOP_DB_PASSWORD"
database = "shop"

[connections.notes]
path = "~/notes.db"
```

### Commands

| Command | |
|---|---|
| `/connect [name\|url]` | connect; without an argument, pick from the config |
| `/tables`, `/views` | list tables and views |
| `/types` | user types and enum values |
| `/functions`, `/triggers` | list functions/procedures and triggers |
| `/describe <table>` | columns, indexes, constraints |
| `/browse <table> [where …]` | open table data full-screen |
| `/def <name>` | source of a view, function, trigger or enum |
| `/databases`, `/refresh`, `/clear`, `/help`, `/quit` | |

Anything else you type is run as SQL.

### Keys

| Console | | Table view | |
|---|---|---|---|
| `enter` | run | `↑↓←→` / `hjkl` | move |
| `shift+enter` | new line | `enter` | show full value |
| `tab` | complete | `/` | filter (`WHERE …` in `/browse`) |
| `↑` `↓` | history | `s` | sort by column |
| `ctrl+o` | open last result as a table | `n` / `p` | next / previous page |
| `ctrl+c` | cancel query · clear · exit (twice) | `y` / `Y` | copy cell / row |
| `ctrl+l` | clear screen | `q` | back |

---

## Русский

### Зачем

Графические клиенты баз данных тяжёлые, а у `psql`, `mysql` и `sqlite3` свои команды, и данные в них смотреть неудобно.
zpeek — **один инструмент для трёх баз** прямо в терминале: пишете SQL или `/команды` в строке ввода, видите результат таблицей, листаете данные на весь экран.

### Преимущества

- **Один бинарник без зависимостей.** Не нужны libpq, libmysqlclient или системный SQLite: драйверы написаны на Zig, SQLite встроен.
- **Три базы, один интерфейс.** PostgreSQL, MySQL, MariaDB и SQLite с одинаковыми командами.
- **Схема под рукой.** Таблицы, view, значения enum и другие типы, функции, триггеры и их исходный код.
- **Удобная SQL-консоль.** Подсветка синтаксиса, автодополнение по Tab (таблицы, колонки, в том числе через алиасы, ключевые слова), история, несколько запросов за раз.
- **Просмотр данных.** Таблица на весь экран с фильтром `WHERE` на сервере, сортировкой, страницами и копированием.
- **Не зависает.** Запросы выполняются в фоне, `ctrl+c` отменяет долгий запрос на сервере.
- **Защищённые подключения.** TLS, SCRAM-SHA-256, `caching_sha2_password`.

### Установка

macOS, Linux или Windows (Git Bash / WSL). Команда скачает последнюю версию и добавит `zpeek` в `PATH`; для обновления запустите её снова:

```sh
curl -fsSL https://raw.githubusercontent.com/aleksandraleksandrov/zpeek/main/install.sh | bash
```

Или соберите из исходников (нужен Zig 0.17.0):

```sh
zig build -Doptimize=ReleaseSafe --prefix ~/.local   # установит ~/.local/bin/zpeek
```

### Подключение

```sh
zpeek                                       # подключение по умолчанию из конфига или выбор из списка
zpeek prod                                  # подключение по имени из конфига
zpeek postgres://user:pass@host:5432/db     # URL: postgres://, mysql://, mariadb://, sqlite://
zpeek ./data.sqlite                         # файл SQLite
zpeek --driver mysql --host 127.0.0.1 --user root --database shop
zpeek prod -e "select count(*) from users"  # выполнить запрос и выйти
```

Пароль можно передать через `$PGPASSWORD` / `$MYSQL_PWD`. TLS: `?sslmode=disable|prefer|require` (по умолчанию `prefer`).

Подключения хранятся в `~/.config/zpeek/config.toml` (пример создаёт `zpeek --init-config`). Формат — как в примере выше: `url`, либо `driver` + `host` / `port` / `user` / `password_env` / `database`, либо `path` для SQLite.

### Команды

| Команда | |
|---|---|
| `/connect [имя\|url]` | подключиться; без аргумента — выбор из конфига |
| `/tables`, `/views` | таблицы и представления |
| `/types` | пользовательские типы и значения enum |
| `/functions`, `/triggers` | функции и процедуры, триггеры |
| `/describe <таблица>` | колонки, индексы, ограничения |
| `/browse <таблица> [where …]` | данные таблицы на весь экран |
| `/def <имя>` | исходный код view, функции, триггера или enum |
| `/databases`, `/refresh`, `/clear`, `/help`, `/quit` | |

Всё остальное выполняется как SQL.

### Клавиши

| Консоль | | Просмотр таблицы | |
|---|---|---|---|
| `enter` | выполнить | `↑↓←→` / `hjkl` | перемещение |
| `shift+enter` | новая строка | `enter` | значение целиком |
| `tab` | автодополнение | `/` | фильтр (`WHERE …` в `/browse`) |
| `↑` `↓` | история | `s` | сортировка по колонке |
| `ctrl+o` | открыть последний результат таблицей | `n` / `p` | следующая / предыдущая страница |
| `ctrl+c` | отменить запрос · очистить · выйти (дважды) | `y` / `Y` | копировать ячейку / строку |
| `ctrl+l` | очистить экран | `q` | назад |
