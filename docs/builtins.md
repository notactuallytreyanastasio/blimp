# Builtins

A reference for the functions the interpreter provides without an `import`. The registry is `BuiltinRegistry.init` in `chunks/lang/src/builtins.zig`; this page follows its groupings.

It does not describe every builtin yet. Each section below has full entries (signature, what it returns, what it raises, an example) for the builtins listed under it, and then a line naming the others in the group that have no entry here. Where an entry's example shows output, the output was checked against a run of `chunks/lang/zig-out/bin/blimp`.

Every builtin that refuses its arguments raises a runtime error that points at the call. Most say `TypeError while evaluating this.`; the newer ones carry a message, and the error is titled `BAD ARGUMENT`:

```
-- BAD ARGUMENT ----------------------------------

  sqlite_query: no such table: nope

3| sqlite_query(db, "select * from nope", [])
   ^
```

Builtins marked **native only** are stubbed in the WebAssembly build. Calling one there raises `NotSupported`; the program still compiles and loads.

## Lists

### flat_deep(list)

```
flat_deep(list: List) -> List
```

Flattens a list nested to any depth into one list, in order. Elements that are not lists (Strings, numbers, maps, `nil`) are kept as they are. `flat` takes off one level and stops; `flat_deep` takes off all of them. It uses an explicit stack, not recursion, so a list nested 100,000 levels deep is flattened without running out of native stack.

Raises TypeError if the argument is not a list.

```
flat_deep([1, [2, [3, "x"]], "y"])
=> [1, 2, 3, "x", "y"]

flat([1, [2, [3]]])
=> [1, 2, [3]]
flat_deep([1, [2, [3]]])
=> [1, 2, 3]

flat_deep([[], [[]], "a"])
=> ["a"]

flat_deep([%{a: 1}, [nil, [true]]])
=> [%{a: 1}, nil, true]

flat_deep(3)
-- RUNTIME ERROR: TypeError while evaluating this.
```

A Blimp string is not a list, so it is never taken apart. A map is not a list either, and is kept whole.

The other builtins in this group, without an entry here: `length`, `append`, `reverse`, `head`, `tail`, `sort`, `sort_by_keys`, `range`, `elem`, `set_at`, `size`, `empty?`, `flat`, `zip`, `uniq`, `sum`, `map`, `filter`, `reduce`, `each`.

## Buffers and hash maps

Native only. The design, and what it costs, is in [lang_design/handles.md](lang_design/handles.md); read the section on compaction before using these in a program run with `--serve` or the REPL.

A Blimp value is immutable, and the interpreter frees nothing inside a run, so `append(items, x)` copies the whole list and keeps the old copy. These builtins keep the mutable part outside the value heap and name it with an Int handle, the way `sqlite_open` names a database: a **list buffer** (`buf_*`), a **string buffer** (`sbuf_*`) and a **hash map** (`hmap_*`). All three kinds share one table of handles. A handle is an Int starting at 1; it is never reused, and a buffer is never freed. A handle that is not in the table raises `N is not a handle`, and a handle of the wrong kind raises `handle N is a different kind of buffer`.

What they do not do: nothing is freed, the contents are not counted by `BLIMP_HEAP_LIMIT`, and a program that creates one buffer stops `--serve` and the REPL from compacting their heap. The numbers are in the design note.

### List buffers: buf_*

```
buf_new() -> Int
buf_push(h, v) -> nil          add v at the end
buf_len(h) -> Int
buf_get(h, i) -> v | nil       nil for an index below 0 or past the end
buf_set(h, i, v) -> nil        TypeError for an index outside 0..len-1
buf_pop(h) -> v                removes and answers the last; TypeError when empty
buf_items(h) -> List           a snapshot
buf_replace(h, list) -> nil    the buffer now holds exactly list
buf_extend(h, list) -> nil     add every element of list at the end
buf_clear(h) -> nil
```

`buf_push` is amortised O(1): the array doubles as it grows and the old array is freed. `buf_items` answers an ordinary immutable list, a copy, so later pushes do not change one already taken. The copy is cached until the next write, so reading a buffer that is not changing is O(1) after the first read. A loop that writes and reads in turn pays O(n) for each pair.

```
b = buf_new()
buf_push(b, "a")
buf_push(b, "b")
buf_items(b)
=> ["a", "b"]
buf_get(b, 5)
=> nil
buf_pop(b)
=> "b"
```

### String buffers: sbuf_*

```
sbuf_new() -> Int
sbuf_append(h, s) -> nil       s must be a String
sbuf_len(h) -> Int             bytes, not characters
sbuf_string(h) -> String       a snapshot, cached until the next write
sbuf_clear(h) -> nil
```

`sbuf_append` is amortised O(1) per byte. `sbuf_len` counts bytes: after appending `"hello, "` and `"é"` it is 9.

### Hash maps: hmap_*

```
hmap_new() -> Int
hmap_get(h, key, default) -> v | default
hmap_has(h, key) -> Bool
hmap_put(h, key, v) -> nil
hmap_remove(h, key, default) -> old value | default
hmap_len(h) -> Int
hmap_clear(h) -> nil
hmap_keys(h) -> List
hmap_values(h) -> List
hmap_entries(h) -> List        [[key, value], ...]
hmap_assign(h, src) -> nil     h becomes a copy of src (not an alias)
```

Lookup, insert and remove are O(1) on average. Keys may be Strings, Ints, Floats, atoms, Bools, `nil`, actor references, and lists or tuples of those; the match is exactly the one `==` makes, so Int `1` and String `"1"` are different keys, and `["a", "bc"]` is not `["ab", "c"]`. Any other key (a map, a closure, a view node) raises `hmap: a map cannot be a map key` (with the kind in place of "map"), not a quiet miss. Iteration is in insertion order, and putting an existing key replaces its value and keeps its place. `hmap_keys`, `hmap_values` and `hmap_entries` are snapshots, cached until the next write.

```
m = hmap_new()
hmap_put(m, "k", 1)
hmap_put(m, 1, 2)
hmap_entries(m)
=> [["k", 1], [1, 2]]
hmap_remove(m, "nope", :absent)
=> :absent
```

## Files

### append_file(path, data)

```
append_file(path: String, data: String) -> nil
```

Adds `data` to the end of the file at `path`, creating the file (mode 0644) if it is missing. `write_file` replaces the contents; this keeps them. The file is opened with `O_APPEND`, so the kernel moves to the end of the file and writes in one step, and two processes appending to the same log (a server and the children it forked) do not overwrite each other's lines as long as each call is one write. The descriptor is closed before the call returns and is not inherited by `exec`.

Raises if `path` has a NUL byte in it, or if the file cannot be opened or written; the message carries the `errno` (`2` is "no such file or directory", `13` is "permission denied").

```
append_file("/tmp/demo.log", "one\n")
append_file("/tmp/demo.log", "two\n")
read_file("/tmp/demo.log")
=> "one\ntwo\n"

write_file("/tmp/demo.log", "three\n")
read_file("/tmp/demo.log")
=> "three\n"

append_file("/no/such/dir/x.log", "x")
-- BAD ARGUMENT: append_file: cannot open /no/such/dir/x.log: errno 2
```

It does not create directories, add a newline, or sync to disk.

The other builtins in this group, without an entry here: `read_file`, `write_file`, `write_bytes`, `list_dir`, `file_exists?`, `file_size`.

## Sockets

Native only.

### fd_close(fd)

```
fd_close(fd: Int) -> nil
```

Closes a descriptor with a plain `close(2)`, and nothing else. For a parent process that has `fork`ed a child to handle a connection: the connection is now the child's, and the parent only has to let go of its own copy of the descriptor.

`tcp_close` is the wrong call there. It does `shutdown(fd, SHUT_WR)`, which acts on the connection and not on the one descriptor, so the child's connection has its write side shut under it: the client sees the end of the stream before the child has written anything. Then it keeps the descriptor open for up to 30 seconds, reading and discarding, so the peer gets its FIN after the last queued byte. That is right for a process that wrote the response itself and is about to forget the socket, and wrong for a process that gave the socket away.

```
# the parent accepts, forks a child that writes after 300 ms, then lets go
s = tcp_accept(l)
handler = fork()
# child: sleep_ms(300); tcp_write(s, "hello from the child"); exit(0)

tcp_close(s)    # the client reads ""
fd_close(s)     # the client reads "hello from the child"
```

If `fd` is on the list `tcp_close` keeps for lingering, `fd_close` takes it off, so a descriptor is never closed twice (a second close could close an unrelated socket that has since been given the same number). Raises TypeError if `fd` is not an Int. It does not check that `fd` is open; closing one that is not is ignored.

The design is in [lang_design/processes.md](lang_design/processes.md#a-forked-child-owns-the-socket).

The other builtins in this group, without an entry here: `tcp_listen`, `tcp_connect`, `tcp_accept`, `tcp_read`, `tcp_write`, `tcp_close`, `tcp_set_nonblocking`, `tcp_poll`, `tcp_write_some`, `tcp_poll_write`, `ws_open`, `ws_recv`, `ws_send`, `ws_close`, `ws_stats`, `ws_accept_key`, `ws_read_frame`, `ws_write_frame`, `http_start`, `http_result`. Postgres (`pg_start`, `pg_result`, `pg_stats`) has its own entry, next.

### pg_start(conn, sql, params) and pg_result(handle)

```
pg_start(conn: Map | String, sql: String, params: List) -> Int
pg_start(conn: Map | String, sql: String, params: List, %{timeout_ms: Int}) -> Int
pg_result(handle: Int) -> nil | {:ok, rows} | {:error, reason}
pg_stats() -> %{in_flight: Int, idle: Int}
```

A Postgres query on a thread of its own, so a program that serves everyone from one thread does not stop while Postgres thinks. `pg_start` answers a handle at once; `pg_result` answers `nil` until the query is done, then its answer, once. 32 queries may be in flight; past that `pg_start` answers `-1`, which `pg_result` refuses.

`conn` is `%{host:, port:, user:, password:, database:}` or `"postgres://user:password@host:port/database"` (`ecto://` too; `%XX` in the user or password is decoded, `+` is a plus). Parameters are `$1`, `$2`, ... in the extended protocol, sent as text: `nil` is NULL, `true`/`false` are `t`/`f`, an Int or Float as `to_string` writes it, a Map or List as `json_encode` writes it. A row is a map from column name to value: `bool` is a Bool, `int2`/`int4`/`int8`/`oid` an Int, `json`/`jsonb` what `json_decode` makes of it, NULL is `nil`, and anything else is its text as Postgres writes it. A server error is `{:error, "ERROR 42P01: relation \"x\" does not exist"}`.

Every query has a deadline, `timeout_ms` (15000 unless given, at most 600000), for connecting, logging in and the query together. At the deadline `pg_result` answers `{:error, "timeout"}` and the worker sends Postgres a CancelRequest, so the statement stops on the server too. Login is trust, SCRAM-SHA-256 or md5; a cleartext password request is refused, and there is no TLS. Up to 4 idle connections are kept per process and reused by queries to the same place; two queries in flight at once run on different connections and are not ordered against each other.

Raises TypeError for a `conn` it cannot read (a missing or unknown key, a URL that is not one), SQL with a NUL in it, a parameter of another type, or an option other than `timeout_ms` in range. Native only.

## Process

Native only.

### exec(argv, stdin, cwd)

```
exec(argv: List[String], stdin: String, cwd: String | nil) -> [status, stdout, stderr]
```

Runs `argv[0]` (looked up on `PATH`) with the rest of the list as its arguments, writes `stdin` to it, and answers when it has exited. There is no shell: `exec(["ls -l"], ...)` looks for a program named `ls -l`. To use a shell, say so: `exec(["sh", "-c", "ls -l | wc -l"], "", nil)`.

Returns a three-element list: the status (an Int), what the program wrote to stdout (a String) and what it wrote to stderr (a String). A list rather than a map because a Temper program receives lists without help.

The status is the exit code. Three cases are not an exit code:

| status | meaning |
|--------|---------|
| `127`  | `execvp` failed: no such program, or not executable |
| `126`  | `chdir` to `cwd` failed |
| `-N`   | a signal ended it; `-9` is `kill -9` |

126 and 127 are the shell's conventions, used because the child has no other way to report an errno to the parent. A real program that exits 127 looks the same.

`cwd` is the directory to run in, or `nil` for the interpreter's own. Descriptors 3 to 1023 are closed in the child, so it does not inherit the listening socket or a client's connection (`tcp_listen` and `tcp_accept` do not set close-on-exec). Stdout and stderr are drained together with `poll`, and stdin is written in the same loop, so a child that fills its stdout pipe before reading its input does not deadlock (a 1.3 MB payload through `cat` takes 2 ms).

Raises TypeError for an `argv` that is not a list, is empty, or holds anything but Strings; for a String with a NUL byte in it; and for a `cwd` that is neither a String nor `nil`. Raises NotSupported if `pipe` or `fork` fails.

```
exec(["echo", "hi there"], "", nil)
=> [0, "hi there\n", ""]

exec(["sh", "-c", "tr a-z A-Z; echo oops 1>&2; exit 3"], "shout", nil)
=> [3, "SHOUT", "oops\n"]

exec(["pwd"], "", "/usr")
=> [0, "/usr\n", ""]

exec(["no-such-program"], "", nil)
=> [127, "", ""]

exec(["sh", "-c", "kill -9 $$"], "", nil)
=> [-9, "", ""]
```

What it does not do:

- **No timeout.** `exec` blocks the whole interpreter until the child exits, and under `--serve` every other request waits with it. Run something that might hang through `timeout(1)`: `exec(["timeout", "5", "slow-thing"], "", nil)`.
- **No streaming.** Output is collected whole and returned at the end.
- **No environment argument.** The child gets the interpreter's environment.

The design is in [lang_design/processes.md](lang_design/processes.md).

The other builtins in this group, without an entry here: `fork`, `waitpid`, `exit`, `sleep_ms`, `getenv`, `argv`, `read_line`, `process_stats`.

## Crypto

Native only for `pbkdf2_sha256` and `constant_time_eq`.

### pbkdf2_sha256(password, salt_hex, iterations, dklen)

```
pbkdf2_sha256(password: String, salt_hex: String, iterations: Int, dklen: Int) -> String
```

PBKDF2 with HMAC-SHA256 (RFC 8018), for storing a password so that a stolen table is slow to guess against. The salt is passed as hex, as the other binary-carrying builtins (`sha256`, `hmac_sha256`, `random_bytes`) do, and the answer is the derived key as `2 * dklen` lowercase hex characters.

Raises when `salt_hex` is not an even number of hex digits, when `iterations` is not between 1 and 2147483647, or when `dklen` is not between 1 and 1024.

```
pbkdf2_sha256("password", hex_encode("salt"), 1, 32)
=> "120fb6cffcf8b32c43e7225256c4f837a86548c92ccc35480805987cb70be17b"

pbkdf2_sha256("password", hex_encode("salt"), 2, 20)
=> "ae4d0c95af6b46d32d0adff928f06dd02a303f8e"

pbkdf2_sha256("p", "zz", 1, 32)
-- BAD ARGUMENT: pbkdf2_sha256: salt_hex is not hex
```

The first two agree with Python's `hashlib.pbkdf2_hmac`, and the test file checks RFC 7914 section 11's vector. A salt wants to be random and per-password: `hex_encode(random_bytes(16))`. 600,000 iterations (the figure OWASP gives for PBKDF2-HMAC-SHA256 as of 2023) took 67 ms on an Apple silicon laptop. That is 67 ms in which the interpreter does nothing else, which under `--serve` stalls every request; there is no way to run it off the main thread.

### constant_time_eq(a, b)

```
constant_time_eq(a: String, b: String) -> Bool
```

True when the two Strings hold the same bytes. For two Strings of the same length it looks at every byte whatever they contain, so how long it takes does not say where they first differ. Use it to compare a token or a derived key with the one a client sent; `==` stops at the first byte that differs.

Strings of different lengths answer false at once. The length is not treated as secret, so compare values of a fixed size (the hex of a key, a fixed-length token), not values whose length is private.

```
constant_time_eq("abc", "abc")
=> true
constant_time_eq("abc", "abd")
=> false
constant_time_eq("abc", "ab")
=> false
```

The other builtins in this group, without an entry here: `sha256`, `hmac_sha256`, `hex_encode`, `hex_decode`, `xor_bytes`, `base64_encode`, `base64_decode`, `base64url_encode`, `base64url_decode`, `random_bytes`, `random_token`, `p256_keypair`, `p256_public_key`, `p256_ecdh`, `ecdsa_p256_sign`, `ecdsa_p256_verify`, `aes128gcm_encrypt`, `aes128gcm_decrypt`.

## SQLite

Native only. The interpreter links the system `libsqlite3` (`-lsqlite3`; on Debian and Ubuntu, `libsqlite3-dev`). The design is in [lang_design/sqlite.md](lang_design/sqlite.md).

A database is an Int handle. Handles start at 1, at most 256 can be open at once, and a closed handle's number is reused, so a handle kept after `sqlite_close` may name a different database. Every builtin below raises, with SQLite's own message, when the handle is not open.

### sqlite_open(path)

```
sqlite_open(path: String) -> Int
```

Opens the database at `path`, creating the file if it is missing, and answers a handle. `":memory:"` gives a database private to that handle. Every connection is opened with `PRAGMA journal_mode=WAL; PRAGMA busy_timeout=5000; PRAGMA foreign_keys=ON`, so foreign keys are enforced (SQLite's own default is off), readers do not block the writer, and a write that finds the database locked retries for five seconds before it fails.

Raises with SQLite's message if the file cannot be opened (`sqlite_open: cannot open /no/such/dir/x.db: unable to open database file`), or if 256 databases are open already.

### sqlite_close(db)

```
sqlite_close(db: Int) -> nil
```

Closes the database and frees the handle number. Raises if `db` is not open.

### sqlite_exec(db, sql)

```
sqlite_exec(db: Int, sql: String) -> Int
```

Runs `sql`, which may hold any number of statements separated by `;`, and throws away any rows they produce. There are no parameters, so this is for schema and fixed statements; use `sqlite_query` for anything that carries a value. Returns the number of rows the statements changed in all.

If a statement fails it raises with SQLite's message, and the statements before it have already run: wrap a script in `begin; ...; commit` if that matters.

```
db = sqlite_open(":memory:")
sqlite_exec(db, "create table notes(id integer primary key, body text, stars integer)")
=> 0
sqlite_exec(db, "create table t(x); insert into t values (1); insert into t values (2); delete from t")
=> 4
```

### sqlite_query(db, sql, params)

```
sqlite_query(db: Int, sql: String, params: List) -> List[List[String | nil]]
```

Runs one statement with `params` bound to its parameters, and answers the result as text.

**Parameters** are bound like Postgres when the SQL uses `$N`: param `i` (counting from 1) goes to `$i`, in whatever order the placeholders appear, so `select $2, $1` with `["a", "b"]` answers `b, a`. A `$N` used twice takes the same param twice. With `?` and `?NNN` the params bind by position, and `?2, ?1` also answers `b, a`. A statement that has any `$N` placeholder must have only `$N` placeholders; a `$N` with no param (`select $2` with one param), a param with no `$N` (`select $1` with two), or a `?` next to a `$1` raises, naming the placeholder. Without `$N`, the length of `params` must equal the statement's parameter count (a name used twice counts once). A `nil` binds NULL, an Int or a Float binds as that number, a String binds as TEXT, and a Bool or an atom binds as its text (`true`, `ok`). Anything else, such as a list or a map, is an error that names the parameter.

**The result** is a list of rows, and every cell is a String or `nil`:

- The first row is the column names.
- Then one row per result row. NULL is `nil`. Integers and floats come back in their text form (`"5"`, `"2.5"`). A BLOB comes back as lowercase hex.
- A SELECT that matches nothing is just the header row, so you still learn the columns.
- A statement with no result columns (INSERT, UPDATE, DELETE, DDL, `PRAGMA` that sets) answers `[["changes"], ["<n>"]]`, n being the rows it changed. Empty SQL, or only a comment, answers `[["changes"], ["0"]]`.

Raises with SQLite's message (`no such table: nope`), and for a second statement after the first (`one statement per call, found more after the first`), a wrong number of params, or an unbindable param.

```
db = sqlite_open(":memory:")
sqlite_query(db, "insert into notes(body, stars) values ($1, $2), ($3, $4)", ["it's fine", 5, "later", nil])
=> [["changes"], ["2"]]

sqlite_query(db, "select id, body, stars from notes order by id", [])
=> [["id", "body", "stars"], ["1", "it's fine", "5"], ["2", "later", nil]]

sqlite_query(db, "select body from notes where stars > $1", [9])
=> [["body"]]

sqlite_query(db, "select x'00ff' as b, 2.5 as f, 7 as i", [])
=> [["b", "f", "i"], ["00ff", "2.5", "7"]]
```

The column names are not made unique: `select 1 as a, 2 as a` has the header `["a", "a"]`.

### sqlite_last_id(db)

```
sqlite_last_id(db: Int) -> Int
```

The rowid of the most recent INSERT on this handle (SQLite's `last_insert_rowid`), or 0 if there has not been one.

### sqlite_changes(db)

```
sqlite_changes(db: Int) -> Int
```

The number of rows the most recent INSERT, UPDATE or DELETE on this handle changed.

```
sqlite_last_id(db)
=> 2
sqlite_changes(db)
=> 2
```
