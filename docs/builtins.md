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

The other builtins in this group, without an entry here: `tcp_listen`, `tcp_connect`, `tcp_accept`, `tcp_read`, `tcp_write`, `tcp_close`, `tcp_set_nonblocking`, `tcp_poll`, `tcp_write_some`, `tcp_poll_write`, `ws_open`, `ws_recv`, `ws_send`, `ws_close`, `ws_stats`, `ws_accept_key`, `ws_read_frame`, `ws_write_frame`, `http_start`, `http_result`.

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

**Parameters** are bound by position. `?`, `?1` and `$1` all work. For `$1` the number is only a name: SQLite numbers `$name` parameters in the order they first appear, so `select $2, $1` with `["a", "b"]` binds `"a"` to `$2`. Use `?1`, `?2` when the order in the SQL differs from the order of the list. The length of `params` must equal the statement's parameter count (a name used twice counts once). A `nil` binds NULL, an Int or a Float binds as that number, a String binds as TEXT, and a Bool or an atom binds as its text (`true`, `ok`). Anything else, such as a list or a map, is an error that names the parameter.

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
