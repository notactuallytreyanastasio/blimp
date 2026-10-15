# SQLite

## What exists

Six builtins: `sqlite_open`, `sqlite_close`, `sqlite_exec`, `sqlite_query`, `sqlite_last_id` and `sqlite_changes`. They link the system `libsqlite3` and call it directly (`src/native_ext.zig`); there is no wrapper library. The reference entries are in [../builtins.md](../builtins.md#sqlite).

```blimp
db = sqlite_open("site.db")
sqlite_exec(db, "create table if not exists notes(id integer primary key, body text)")
sqlite_query(db, "insert into notes(body) values ($1)", ["it's fine"])
# => [["changes"], ["1"]]
sqlite_query(db, "select id, body from notes", [])
# => [["id", "body"], ["1", "it's fine"]]
```

Native only. The WebAssembly build stubs all six and raises `NotSupported`; `build.zig` links `sqlite3` into the executable and the test binaries but not into `wasm`.

## Why text in, text out

SQLite is dynamically typed: a column declared `integer` can hold the string `"abc"`, and the value's type is a property of each cell, not of the column. Blimp has Int, Float, String, Bool, atoms, lists and maps, and a program that reads rows mostly wants to hand them straight to a page or a JSON encoder.

Every cell comes back as a String (`sqlite3_column_text`), NULL as `nil`. That is one rule to learn instead of a table of mappings, and it loses nothing that a program could rely on: an `integer` column's `"42"` goes to `to_int`, and the one case where a column held something else is a string that does not parse, not a silent Float. A BLOB has no sensible String form, so it comes back as lowercase hex, which `hex_decode` undoes.

The other direction does bind natively. An Int goes in as an integer and a Float as a double, so `where stars > $1` compares numbers, not text: `"10" > "9"` is false as text. A Bool or an atom binds as its text (`true`, `ok`), because SQLite has no boolean and there is no one right integer to pick.

The cost is that a Float round-trips through its text form, so what comes back is whatever SQLite printed (`"2.5"`), and a program that counts on bytes of a float has to parse it.

## Why a header row

A result is a list of lists, and the first row is the column names. The alternative was a list of maps, `[%{id: "1", body: "it's fine"}]`, and it costs more than it looks: a map per row duplicates every name, `select 1 as a, 2 as a` has no representation as a map (the second `a` overwrites the first), and a result of zero rows says nothing about its columns.

With the header, a `select` that matches nothing is still `[["id", "body"]]`: the caller can tell a query that returned no rows from one that was never run. The caller who wants maps writes five lines to zip the header with each row. The caller who wants lists does not pay for maps. The cost is that every caller has to remember row 0 is not data, and `size(rows) - 1` is the count.

A statement with no result columns (an INSERT, an UPDATE, a `create table`) answers `[["changes"], ["<n>"]]`, the same shape as a select, so a caller handles one kind of result. For the count without the shape, `sqlite_exec` answers an Int, and `sqlite_changes` reads it after the fact.

## Why `$1` and `?`

SQL text with values pasted into it is how injections happen, and `sqlite_query` is where they would happen, so it takes parameters and binds them. `?` and `?NNN` are SQLite's own, and `$1` reads like the placeholders Postgres uses. SQLite treats `$1` as a named parameter whose name happens to be `$1`, which means it numbers `$` names in the order they first appear, not by the digit:

```
sqlite_query(db, "select $2 as first, $1 as second", ["a", "b"])
=> [["first", "second"], ["a", "b"]]
sqlite_query(db, "select ?2 as first, ?1 as second", ["a", "b"])
=> [["first", "second"], ["b", "a"]]
```

Postgres would have answered `["b", "a"]` to the first. The builtin does not paper over this: write the placeholders in order, or use `?1`.

Two more rules, both about failing early. The number of params must equal the statement's parameter count, so a forgotten value is an error and not a silent NULL. And `sqlite_query` runs one statement; text after it raises `one statement per call`. With `sqlite3_exec`, which takes many statements, there is nowhere to bind a value, and a program that builds a statement by pasting a value in front of a `;` would run what follows it. `sqlite_exec` is the many-statements builtin and takes no parameters.

## Why a table of handles

A database is an Int, an index into a table of 256 slots plus one, and zero or negative numbers are never valid. A Blimp value cannot hold a C pointer, and a pointer handed to a program that can do arithmetic on Ints can be forged into a crash. An Int that names a slot can only be wrong in two ways, and both are checked: out of range, or a slot that is empty. Both raise `N is not an open database handle`.

A closed slot is reused, so the number can come back. A program that keeps a handle after `sqlite_close` and uses it may reach a different database. The table is not locked; the interpreter calls builtins from one thread at a time. 256 is a limit on open databases, not on queries: a server opens one at start.

## What `sqlite_open` sets up

```
PRAGMA journal_mode=WAL; PRAGMA busy_timeout=5000; PRAGMA foreign_keys=ON
```

- **WAL**, so a reader does not block the writer. The file grows `-wal` and `-shm` siblings; delete all three to delete the database. A `:memory:` database ignores it.
- **busy_timeout** of five seconds, so a write that finds another connection holding the lock waits and retries before it raises `database is locked`. The wait blocks the interpreter.
- **foreign_keys**, because SQLite's default is to parse `references` and then not enforce it, and a schema that says `on delete cascade` ought to cascade.

They are not options. A program that wants the other behaviour can run `PRAGMA` itself through `sqlite_exec`.

## What it does not do

- **One statement per `sqlite_query`.** A transaction is three calls: `sqlite_exec(db, "begin")`, the work, `sqlite_exec(db, "commit")`. Nothing rolls back on its own if the program raises in between.
- **No prepared statements held across calls.** Each `sqlite_query` prepares, binds, steps and finalizes.
- **No row-at-a-time cursor.** The whole result is built as a list before it returns.
- **No user functions, no blob parameters, no extension loading.** A BLOB cannot be bound; it can be written as `x'00ff'` in the SQL, or `unhex()` in SQLite 3.41 and later.
- **Native only.** There is no SQLite in the browser build.
