#include <stdio.h>
#include <stdlib.h>
#include <string.h>
#include <time.h>

// ── Tagged Values ───────────────────────────────────────
// Every Blimp value at runtime is a BlimpVal*.
// This is the foundation for lists, maps, closures, etc.

typedef enum {
    VAL_INT,
    VAL_FLOAT,
    VAL_STRING,
    VAL_ATOM,
    VAL_BOOL,
    VAL_NIL,
    VAL_LIST,
    VAL_MAP,
    VAL_ACTOR_REF,
    VAL_CLOSURE,
} ValTag;

typedef struct BlimpVal BlimpVal;
typedef struct BlimpVal {
    int rc; // Perceus reference count
    ValTag tag;
    union {
        long long integer;
        double float_val;
        char *string;
        int atom_id;
        int bool_val;
        struct { BlimpVal **items; int len; int cap; } list;
        struct { char **keys; BlimpVal **vals; int len; } map;
        int actor_id;
        struct { void *func_ptr; BlimpVal **env; int env_len; int param_count; } closure;
    };
} BlimpVal;

// Forward declarations for RC
void blimp_rc_inc(BlimpVal *v);
void blimp_rc_dec(BlimpVal *v);
BlimpVal *blimp_rc_reuse(BlimpVal *v);
static const char *atom_text(int id);

// ── Value constructors ──────────────────────────────────

BlimpVal *blimp_val_int(long long n) {
    BlimpVal *v = (BlimpVal *)malloc(sizeof(BlimpVal));
    v->rc = 1;
    v->tag = VAL_INT;
    v->integer = n;
    return v;
}

BlimpVal *blimp_val_float(double f) {
    BlimpVal *v = (BlimpVal *)malloc(sizeof(BlimpVal));
    v->rc = 1;
    v->tag = VAL_FLOAT;
    v->float_val = f;
    return v;
}

BlimpVal *blimp_val_string(const char *s) {
    BlimpVal *v = (BlimpVal *)malloc(sizeof(BlimpVal));
    v->rc = 1;
    v->tag = VAL_STRING;
    v->string = strdup(s);
    return v;
}

BlimpVal *blimp_val_atom(int atom_id) {
    BlimpVal *v = (BlimpVal *)malloc(sizeof(BlimpVal));
    v->rc = 1;
    v->tag = VAL_ATOM;
    v->atom_id = atom_id;
    return v;
}

BlimpVal *blimp_val_bool(int b) {
    BlimpVal *v = (BlimpVal *)malloc(sizeof(BlimpVal));
    v->rc = 1;
    v->tag = VAL_BOOL;
    v->bool_val = b;
    return v;
}

BlimpVal *blimp_val_nil(void) {
    BlimpVal *v = (BlimpVal *)malloc(sizeof(BlimpVal));
    v->rc = 1;
    v->tag = VAL_NIL;
    return v;
}

BlimpVal *blimp_val_list(int initial_cap) {
    BlimpVal *v = (BlimpVal *)malloc(sizeof(BlimpVal));
    v->rc = 1;
    v->tag = VAL_LIST;
    v->list.len = 0;
    v->list.cap = initial_cap > 0 ? initial_cap : 4;
    v->list.items = (BlimpVal **)malloc(sizeof(BlimpVal *) * v->list.cap);
    return v;
}

BlimpVal *blimp_val_actor_ref(int actor_id) {
    BlimpVal *v = (BlimpVal *)malloc(sizeof(BlimpVal));
    v->rc = 1;
    v->tag = VAL_ACTOR_REF;
    v->actor_id = actor_id;
    return v;
}

BlimpVal *blimp_val_closure(void *func_ptr, int param_count, BlimpVal **env, int env_len) {
    BlimpVal *v = (BlimpVal *)malloc(sizeof(BlimpVal));
    v->rc = 1;
    v->tag = VAL_CLOSURE;
    v->closure.func_ptr = func_ptr;
    v->closure.param_count = param_count;
    v->closure.env = env;
    v->closure.env_len = env_len;
    return v;
}

// ── Map operations ──────────────────────────────────────

BlimpVal *blimp_val_map(int initial_cap) {
    BlimpVal *v = (BlimpVal *)malloc(sizeof(BlimpVal));
    v->rc = 1;
    v->tag = VAL_MAP;
    int cap = initial_cap > 0 ? initial_cap : 4;
    v->map.keys = (char **)malloc(sizeof(char *) * cap);
    v->map.vals = (BlimpVal **)malloc(sizeof(BlimpVal *) * cap);
    v->map.len = 0;
    return v;
}

void blimp_map_put(BlimpVal *map, const char *key, BlimpVal *val) {
    if (map->tag != VAL_MAP) return;
    // Check for existing key
    for (int i = 0; i < map->map.len; i++) {
        if (strcmp(map->map.keys[i], key) == 0) {
            blimp_rc_dec(map->map.vals[i]);
            blimp_rc_inc(val);
            map->map.vals[i] = val;
            return;
        }
    }
    // New key
    blimp_rc_inc(val);
    map->map.keys[map->map.len] = strdup(key);
    map->map.vals[map->map.len] = val;
    map->map.len++;
}

// ── List operations ─────────────────────────────────────

void blimp_list_push(BlimpVal *list, BlimpVal *item) {
    if (list->tag != VAL_LIST) return;
    if (list->list.len >= list->list.cap) {
        list->list.cap *= 2;
        list->list.items = (BlimpVal **)realloc(list->list.items, sizeof(BlimpVal *) * list->list.cap);
    }
    blimp_rc_inc(item); // list now owns a reference
    list->list.items[list->list.len++] = item;
}

BlimpVal *blimp_list_get(BlimpVal *list, int index) {
    if (list->tag != VAL_LIST || index < 0 || index >= list->list.len) return blimp_val_nil();
    return list->list.items[index];
}

int blimp_list_len(BlimpVal *list) {
    if (list->tag != VAL_LIST) return 0;
    return list->list.len;
}

// Map over a list with a closure: ...list, fn
// The closure's func_ptr has signature: BlimpVal*(BlimpVal*)
BlimpVal *blimp_list_map(BlimpVal *list, BlimpVal *closure) {
    if (list->tag != VAL_LIST || closure->tag != VAL_CLOSURE) return blimp_val_nil();
    BlimpVal *result = blimp_val_list(list->list.len);
    typedef BlimpVal *(*MapFn)(BlimpVal *);
    MapFn fn = (MapFn)closure->closure.func_ptr;
    for (int i = 0; i < list->list.len; i++) {
        blimp_list_push(result, fn(list->list.items[i]));
    }
    return result;
}

// Each over a list with a closure: ..list, fn
void blimp_list_each(BlimpVal *list, BlimpVal *closure) {
    if (list->tag != VAL_LIST || closure->tag != VAL_CLOSURE) return;
    typedef BlimpVal *(*EachFn)(BlimpVal *);
    EachFn fn = (EachFn)closure->closure.func_ptr;
    for (int i = 0; i < list->list.len; i++) {
        fn(list->list.items[i]);
    }
}

// Filter a list with a closure
BlimpVal *blimp_list_filter(BlimpVal *list, BlimpVal *closure) {
    if (list->tag != VAL_LIST || closure->tag != VAL_CLOSURE) return blimp_val_nil();
    BlimpVal *result = blimp_val_list(list->list.len);
    typedef BlimpVal *(*FilterFn)(BlimpVal *);
    FilterFn fn = (FilterFn)closure->closure.func_ptr;
    for (int i = 0; i < list->list.len; i++) {
        BlimpVal *keep = fn(list->list.items[i]);
        if (keep->tag == VAL_BOOL && keep->bool_val) {
            blimp_list_push(result, list->list.items[i]);
        } else if (keep->tag == VAL_INT && keep->integer != 0) {
            blimp_list_push(result, list->list.items[i]);
        }
    }
    return result;
}

// Reduce a list with a closure and initial value
BlimpVal *blimp_list_reduce(BlimpVal *list, BlimpVal *init, BlimpVal *closure) {
    if (list->tag != VAL_LIST || closure->tag != VAL_CLOSURE) return init;
    typedef BlimpVal *(*ReduceFn)(BlimpVal *, BlimpVal *);
    ReduceFn fn = (ReduceFn)closure->closure.func_ptr;
    BlimpVal *acc = init;
    for (int i = 0; i < list->list.len; i++) {
        acc = fn(acc, list->list.items[i]);
    }
    return acc;
}

// ── Value extraction ────────────────────────────────────

long long blimp_val_to_int(BlimpVal *v) {
    if (!v) return 0;
    if (v->tag == VAL_INT) return v->integer;
    if (v->tag == VAL_BOOL) return v->bool_val;
    if (v->tag == VAL_FLOAT) return (long long)v->float_val;
    return 0;
}

double blimp_val_to_float(BlimpVal *v) {
    if (!v) return 0.0;
    if (v->tag == VAL_FLOAT) return v->float_val;
    if (v->tag == VAL_INT) return (double)v->integer;
    return 0.0;
}

// ── Perceus Reference Counting ───────────────────────────

void blimp_rc_inc(BlimpVal *v) {
    if (v) v->rc++;
}

void blimp_rc_dec(BlimpVal *v) {
    if (!v) return;
    v->rc--;
    if (v->rc > 0) return;

    // Refcount hit zero: free this value and recursively dec children
    switch (v->tag) {
        case VAL_STRING:
            free(v->string);
            break;
        case VAL_LIST:
            for (int i = 0; i < v->list.len; i++) {
                blimp_rc_dec(v->list.items[i]);
            }
            free(v->list.items);
            break;
        case VAL_MAP:
            for (int i = 0; i < v->map.len; i++) {
                free(v->map.keys[i]);
                blimp_rc_dec(v->map.vals[i]);
            }
            free(v->map.keys);
            free(v->map.vals);
            break;
        case VAL_CLOSURE:
            for (int i = 0; i < v->closure.env_len; i++) {
                blimp_rc_dec(v->closure.env[i]);
            }
            if (v->closure.env) free(v->closure.env);
            break;
        default:
            break; // int, float, bool, nil, atom, actor_ref: no children
    }
    free(v);
}

// Perceus reuse: if rc == 1 (unique owner), return the same pointer
// for in-place mutation. Otherwise return NULL (caller must allocate new).
BlimpVal *blimp_rc_reuse(BlimpVal *v) {
    if (v && v->rc == 1) return v;
    return NULL;
}

// ── Tagged value printing ───────────────────────────────

void blimp_print_val(BlimpVal *v) {
    if (!v) { printf("nil\n"); return; }
    switch (v->tag) {
        case VAL_INT: printf("%lld\n", v->integer); break;
        case VAL_FLOAT: printf("%g\n", v->float_val); break;
        case VAL_STRING: printf("\"%s\"\n", v->string); break;
        case VAL_ATOM:
            if (atom_text(v->atom_id)) printf(":%s\n", atom_text(v->atom_id));
            else printf(":%d\n", v->atom_id);
            break;
        case VAL_BOOL: printf("%s\n", v->bool_val ? "true" : "false"); break;
        case VAL_NIL: printf("nil\n"); break;
        case VAL_ACTOR_REF: printf("ref<%d>\n", v->actor_id); break;
        case VAL_CLOSURE: printf("fn/%d\n", v->closure.param_count); break;
        case VAL_LIST:
            printf("[");
            for (int i = 0; i < v->list.len; i++) {
                if (i > 0) printf(", ");
                // Inline print without newline
                switch (v->list.items[i]->tag) {
                    case VAL_INT: printf("%lld", v->list.items[i]->integer); break;
                    case VAL_FLOAT: printf("%g", v->list.items[i]->float_val); break;
                    case VAL_STRING: printf("\"%s\"", v->list.items[i]->string); break;
                    case VAL_BOOL: printf("%s", v->list.items[i]->bool_val ? "true" : "false"); break;
                    case VAL_NIL: printf("nil"); break;
                    default: printf("?"); break;
                }
            }
            printf("]\n");
            break;
        case VAL_MAP:
            printf("%%{");
            for (int i = 0; i < v->map.len; i++) {
                if (i > 0) printf(", ");
                printf("%s: ", v->map.keys[i]);
                BlimpVal *mv = v->map.vals[i];
                switch (mv->tag) {
                    case VAL_INT: printf("%lld", mv->integer); break;
                    case VAL_FLOAT: printf("%g", mv->float_val); break;
                    case VAL_STRING: printf("\"%s\"", mv->string); break;
                    case VAL_ATOM:
                        if (atom_text(mv->atom_id)) printf(":%s", atom_text(mv->atom_id));
                        else printf(":%d", mv->atom_id);
                        break;
                    case VAL_BOOL: printf("%s", mv->bool_val ? "true" : "false"); break;
                    case VAL_NIL: printf("nil"); break;
                    case VAL_ACTOR_REF: printf("ref<%d>", mv->actor_id); break;
                    default: printf("?"); break;
                }
            }
            printf("}\n");
            break;
    }
}

// ── Print functions (legacy i64 path) ───────────────────

void blimp_print_int(long long val) {
    printf("%lld\n", val);
}

void blimp_print_float(double val) {
    printf("%g\n", val);
}

void blimp_print_bool(long long val) {
    printf("%s\n", val ? "true" : "false");
}

void blimp_print_string(const char *val) {
    printf("\"%s\"\n", val);
}

void blimp_print_atom(const char *val) {
    printf(":%s\n", val);
}

void blimp_print_nil(void) {
    printf("nil\n");
}

// puts(s) for a String: its bytes as they are, unquoted, then a newline.
// (blimp_print_string quotes it, as the interpreter prints a final value.)
void blimp_puts_string(const char *val) {
    fputs(val, stdout);
    fputc('\n', stdout);
}

// ── Builtins ─────────────────────────────────────────────

long long blimp_max(long long a, long long b) {
    return a > b ? a : b;
}

long long blimp_min(long long a, long long b) {
    return a < b ? a : b;
}

long long blimp_now(void) {
    return (long long)time(NULL);
}

// ── Canvas Event Log ─────────────────────────────────────
// Records events for animated visualization replay.

#define MAX_EVENTS 4096
#define MAX_ATOM_NAMES 256

typedef enum {
    EVT_SPAWN,      // actor spawned: {actor_id, type_name}
    EVT_SEND,       // message sent: {from_id, to_id, msg_atom_id}
    EVT_STATE,      // state changed: {actor_id, field_count, fields...}
} EventType;

typedef struct {
    EventType type;
    int actor_id;
    int target_id;
    int atom_id;
    const char *type_name;   // for spawn events
    // State snapshot (for EVT_STATE)
    int field_count;
    long long field_vals[8];
} CanvasEvent;

static CanvasEvent event_log[MAX_EVENTS];
static int event_count = 0;
static int canvas_enabled = 0;

// Atom name table: maps atom IDs to string names
static const char *atom_names[MAX_ATOM_NAMES];
static int atom_name_count = 0;

// Actor type names (set at spawn time)
static const char *actor_type_names[256];

// Actor field names and counts (set by codegen)
typedef struct {
    const char **names;
    int count;
} ActorFieldInfo;
static ActorFieldInfo actor_fields[256];

void blimp_canvas_enable(void) {
    canvas_enabled = 1;
}

void blimp_set_atom_name(int atom_id, const char *name) {
    if (atom_id < MAX_ATOM_NAMES) {
        atom_names[atom_id] = name;
        if (atom_id >= atom_name_count) atom_name_count = atom_id + 1;
    }
}

void blimp_set_actor_fields(int actor_id, const char **names, int count) {
    if (actor_id < 256) {
        actor_fields[actor_id].names = names;
        actor_fields[actor_id].count = count;
    }
}

static void log_event(CanvasEvent evt) {
    if (!canvas_enabled || event_count >= MAX_EVENTS) return;
    event_log[event_count++] = evt;
}

static const char *atom_name(int id) {
    if (id >= 0 && id < atom_name_count && atom_names[id]) return atom_names[id];
    return "?";
}

// ── Actor Runtime ────────────────────────────────────────

#define MAX_ACTORS 256
#define MAILBOX_CAPACITY 256
#define MAX_ARGS 8

// Handler result, and what `blimp_send` hands back: {status, value}.
//
// The status is how a bubble travels.  It is part of the return value of one
// handler call and of the one send that waited for it, so it cannot be read
// by anything but that send -- unlike a global "last error", which outlives
// the message that set it and is wrong the moment a catch forgets to clear it
// or the scheduler runs another actor's handler in between.
//
// For BLIMP_BUBBLE and BLIMP_FAULT, `value` is a BlimpRaise*.  Codegen
// (codegen.zig, `Status`) uses the same numbers.
enum {
    BLIMP_NOMATCH = 0, // guard failed: try the next clause (handlers only)
    BLIMP_OK = 1,      // replied with `value`
    BLIMP_NIL = 2,     // ended without a reply, or replied nil
    BLIMP_BUBBLE = 3,  // `bubble`: caught by try and orelse
    BLIMP_FAULT = 4,   // runtime error: caught by try, not by orelse
};

typedef struct {
    char status;
    long long value;
} HandlerResult;

// Where something happened, emitted by codegen as a constant per site.
typedef struct {
    int line;
    int col;
    const char *src; // the text of that source line
} BlimpSite;

// A bubble or a runtime error on its way to whoever catches it.
typedef struct {
    const char *title;
    char *message;
    BlimpVal *reason;        // what `bubble` carried, or NULL
    const char *catch_atom;  // what `catch e` binds when there is no reason
    const BlimpSite *site;
    char *hint;
} BlimpRaise;

// Message in mailbox
typedef struct {
    int handler_atom_id;
    int arg_count;
    long long args[MAX_ARGS];
    volatile int reply_ready;  // 0 = pending, 1 = done
    char reply_status;
    long long reply_value;
} Message;

// ── Raising and reporting ────────────────────────────────

// Every atom the program names, in codegen's intern order, so an atom id can
// be printed as `:name`.  Codegen always defines both.
extern const char *blimp_atom_names[];
extern int blimp_atom_count;

static const char *atom_text(int id) {
    if (id >= 0 && id < blimp_atom_count) return blimp_atom_names[id];
    return NULL;
}

static int atom_id_of(const char *name) {
    for (int i = 0; i < blimp_atom_count; i++) {
        if (strcmp(blimp_atom_names[i], name) == 0) return i;
    }
    fprintf(stderr, "blimp runtime: atom :%s was never interned by codegen\n", name);
    abort();
}

// Like the interpreter's Value.format: atoms with their colon, strings quoted.
static void format_val(FILE *out, BlimpVal *v) {
    if (!v) { fputs("nil", out); return; }
    switch (v->tag) {
        case VAL_INT: fprintf(out, "%lld", v->integer); break;
        case VAL_FLOAT: fprintf(out, "%g", v->float_val); break;
        case VAL_STRING: fprintf(out, "\"%s\"", v->string); break;
        case VAL_ATOM: {
            const char *name = atom_text(v->atom_id);
            if (name) fprintf(out, ":%s", name); else fprintf(out, ":%d", v->atom_id);
            break;
        }
        case VAL_BOOL: fputs(v->bool_val ? "true" : "false", out); break;
        case VAL_NIL: fputs("nil", out); break;
        case VAL_ACTOR_REF: fprintf(out, "ref<%d>", v->actor_id); break;
        default: fputs("<value>", out); break;
    }
}

static char *dup_printf(const char *fmt, const char *a, const char *b, const char *c) {
    int n = snprintf(NULL, 0, fmt, a, b, c);
    char *s = (char *)malloc((size_t)n + 1);
    snprintf(s, (size_t)n + 1, fmt, a, b, c);
    return s;
}

BlimpRaise *blimp_raise_bubble(BlimpVal *reason, const BlimpSite *site) {
    BlimpRaise *r = (BlimpRaise *)calloc(1, sizeof(BlimpRaise));
    r->title = "UNCAUGHT BUBBLE";
    r->reason = reason;
    r->catch_atom = "bubble";
    r->site = site;
    r->hint = (char *)"Handle it with `try ... catch` or `orelse`.";
    if (reason) {
        char *buf = NULL;
        size_t len = 0;
        FILE *m = open_memstream(&buf, &len);
        fputs("A bubble reached the top of the program: ", m);
        format_val(m, reason);
        fclose(m);
        r->message = buf;
    } else {
        r->message = (char *)"A bubble reached the top of the program.";
    }
    return r;
}

BlimpRaise *blimp_raise_div_zero(const BlimpSite *site) {
    BlimpRaise *r = (BlimpRaise *)calloc(1, sizeof(BlimpRaise));
    r->title = "DIVISION BY ZERO";
    r->message = (char *)"You're dividing by zero, which isn't defined.";
    r->catch_atom = "division_by_zero";
    r->site = site;
    r->hint = (char *)"Check the denominator before dividing.";
    return r;
}

// rem(a, 0).  The interpreter's builtin returns error.DivisionByZero, which
// it reports with its generic renderer rather than the operator's text.
BlimpRaise *blimp_raise_rem_zero(const BlimpSite *site) {
    BlimpRaise *r = (BlimpRaise *)calloc(1, sizeof(BlimpRaise));
    r->title = "RUNTIME ERROR";
    r->message = (char *)"DivisionByZero while evaluating this.";
    r->catch_atom = "division_by_zero";
    r->site = site;
    r->hint = NULL;
    return r;
}

void blimp_uncaught(BlimpRaise *r);

// f(args) where f is a local: the function to call, after checking f is a
// closure taking argc arguments.  Otherwise reports what the interpreter
// reports for that call and exits 1 (codegen refuses such a call inside a
// try or orelse, so nothing could catch it).
void *blimp_closure_fn(BlimpVal *v, int argc, const char *name, const BlimpSite *site) {
    if (v && v->tag == VAL_CLOSURE && v->closure.param_count == argc) return v->closure.func_ptr;
    BlimpRaise *r = (BlimpRaise *)calloc(1, sizeof(BlimpRaise));
    r->site = site;
    char buf[256];
    if (!v || v->tag != VAL_CLOSURE) {
        r->title = "UNKNOWN FUNCTION";
        snprintf(buf, sizeof buf, "I don't know a function called `%s`.", name);
    } else {
        r->title = "WRONG ARGUMENT COUNT";
        snprintf(buf, sizeof buf, "Handler :fn expects %d argument(s), got %d.", v->closure.param_count, argc);
    }
    r->message = strdup(buf);
    blimp_uncaught(r);
    return NULL;
}

static BlimpRaise *blimp_raise_no_handler(int actor_id, int msg_atom, const BlimpSite *site) {
    const char *msg = atom_text(msg_atom);
    if (!msg) msg = "?";
    const char *actor = (actor_id >= 0 && actor_id < 256 && actor_type_names[actor_id])
        ? actor_type_names[actor_id] : "?";
    BlimpRaise *r = (BlimpRaise *)calloc(1, sizeof(BlimpRaise));
    r->title = "NO MATCHING HANDLER";
    r->message = dup_printf("I tried to send :%s%s%s to this actor, but it doesn't know how to handle it.", msg, "", "");
    // The interpreter binds this name: the error under it is UndefinedVariable.
    r->catch_atom = "undefined";
    r->site = site;
    r->hint = dup_printf("Actor `%s` has no handler for `:%s`.\n\nDefine a handler with:\n      on :%s do ... end",
                         actor, msg, msg);
    return r;
}

// What `catch e` binds: the bubble's reason, or an atom naming the error.
BlimpVal *blimp_raise_reason(BlimpRaise *r) {
    if (r->reason) return r->reason;
    return blimp_val_atom(atom_id_of(r->catch_atom));
}

// Nothing caught it.  The same text, colours and exit status as the
// interpreter's BlimpError.format followed by main.zig's newline.
void blimp_uncaught(BlimpRaise *r) {
    fflush(stdout);
    FILE *e = stderr;
    fprintf(e, "\n\x1b[36m-- %s ", r->title);
    size_t title_len = strlen(r->title) + 4;
    size_t dashes = title_len < 50 ? 50 - title_len : 5;
    for (size_t i = 0; i < dashes; i++) fputs("\xe2\x94\x80", e);
    fputs("\x1b[0m\n\n", e);
    fprintf(e, "  %s\n\n", r->message);
    if (r->site && r->site->line > 0) {
        fprintf(e, "\x1b[90m%d|\x1b[0m \x1b[91m%s\x1b[0m\n", r->site->line, r->site->src);
        for (int i = 0; i < r->site->col + 4; i++) fputc(' ', e);
        fputs("\x1b[31m^\x1b[0m\n", e);
    }
    if (r->hint) fprintf(e, "\n  \x1b[33mHint: %s\x1b[0m\n", r->hint);
    fputs("\n\n", e);
    exit(1);
}

// Mailbox: ring buffer
typedef struct {
    Message messages[MAILBOX_CAPACITY];
    int head;  // next write position
    int tail;  // next read position
    int count; // current message count
} Mailbox;

// Handler table entry
typedef struct {
    int atom_id;
    void *func_ptr;
    int param_count;
} HandlerEntry;

// Actor status
typedef enum {
    ACTOR_IDLE,       // No pending messages
    ACTOR_RUNNABLE,   // Has messages, waiting for scheduler
    ACTOR_RUNNING,    // Currently executing a handler
} ActorStatus;

// Actor instance
typedef struct {
    void *state_ptr;
    HandlerEntry *handlers;
    int handler_count;
    Mailbox mailbox;
    int id;
    ActorStatus status;
    int in_run_queue;
    int is_processing;
} Actor;

// Global registry
static Actor actors[MAX_ACTORS];
static int actor_count = 0;
static int current_actor_id = -1;

// ── Run Queue (FIFO) ────────────────────────────────────

#define RUN_QUEUE_CAPACITY 256

static struct {
    int ids[RUN_QUEUE_CAPACITY];
    int head;
    int tail;
    int count;
} run_queue = {0};

static void run_queue_enqueue(int actor_id) {
    if (run_queue.count >= RUN_QUEUE_CAPACITY) return;
    run_queue.ids[run_queue.head] = actor_id;
    run_queue.head = (run_queue.head + 1) % RUN_QUEUE_CAPACITY;
    run_queue.count++;
}

static int run_queue_dequeue(void) {
    if (run_queue.count == 0) return -1;
    int id = run_queue.ids[run_queue.tail];
    run_queue.tail = (run_queue.tail + 1) % RUN_QUEUE_CAPACITY;
    run_queue.count--;
    return id;
}

// ── Internal: process one message ────────────────────────

static HandlerResult dispatch_message(Actor *actor, Message *msg) {
    for (int h = 0; h < actor->handler_count; h++) {
        if (actor->handlers[h].atom_id != msg->handler_atom_id)
            continue;

        void *func = actor->handlers[h].func_ptr;
        HandlerResult result;

        switch (msg->arg_count) {
            case 0: {
                HandlerResult (*fn)(void *) = (HandlerResult (*)(void *))func;
                result = fn(actor->state_ptr);
                break;
            }
            case 1: {
                HandlerResult (*fn)(void *, long long) =
                    (HandlerResult (*)(void *, long long))func;
                result = fn(actor->state_ptr, msg->args[0]);
                break;
            }
            case 2: {
                HandlerResult (*fn)(void *, long long, long long) =
                    (HandlerResult (*)(void *, long long, long long))func;
                result = fn(actor->state_ptr, msg->args[0], msg->args[1]);
                break;
            }
            case 3: {
                HandlerResult (*fn)(void *, long long, long long, long long) =
                    (HandlerResult (*)(void *, long long, long long, long long))func;
                result = fn(actor->state_ptr, msg->args[0], msg->args[1], msg->args[2]);
                break;
            }
            default: {
                HandlerResult (*fn)(void *) = (HandlerResult (*)(void *))func;
                result = fn(actor->state_ptr);
                break;
            }
        }

        if (result.status != BLIMP_NOMATCH) {
            return result;
        }
        // Guard failed, try next clause
    }
    return (HandlerResult){ .status = BLIMP_NOMATCH, .value = 0 };
}

// ── Mailbox operations ───────────────────────────────────

static Message *mailbox_enqueue(Mailbox *mb) {
    if (mb->count >= MAILBOX_CAPACITY) {
        fprintf(stderr, "blimp: mailbox full\n");
        return NULL;
    }
    Message *msg = &mb->messages[mb->head];
    mb->head = (mb->head + 1) % MAILBOX_CAPACITY;
    mb->count++;
    msg->reply_ready = 0;
    msg->reply_status = BLIMP_NOMATCH;
    msg->reply_value = 0;
    return msg;
}

static Message *mailbox_peek(Mailbox *mb) {
    if (mb->count == 0) return NULL;
    return &mb->messages[mb->tail];
}

static void mailbox_dequeue(Mailbox *mb) {
    if (mb->count == 0) return;
    mb->tail = (mb->tail + 1) % MAILBOX_CAPACITY;
    mb->count--;
}

// ── Runtime API ──────────────────────────────────────────

int blimp_register_actor(void *state_ptr) {
    if (actor_count >= MAX_ACTORS) {
        fprintf(stderr, "blimp: too many actors\n");
        exit(1);
    }
    int id = actor_count++;
    actors[id].state_ptr = state_ptr;
    actors[id].handlers = NULL;
    actors[id].handler_count = 0;
    memset(&actors[id].mailbox, 0, sizeof(Mailbox));
    actors[id].id = id;
    actors[id].status = ACTOR_IDLE;
    actors[id].in_run_queue = 0;
    actors[id].is_processing = 0;
    return id;
}

void blimp_set_actor_type(int actor_id, const char *type_name) {
    if (actor_id < 256) {
        actor_type_names[actor_id] = type_name;
        log_event((CanvasEvent){
            .type = EVT_SPAWN,
            .actor_id = actor_id,
            .type_name = type_name,
        });
    }
}

void blimp_set_handlers(int actor_id, void *handler_table, int count) {
    // Copy the handler table (the original is on the stack)
    HandlerEntry *copy = (HandlerEntry *)malloc(count * sizeof(HandlerEntry));
    memcpy(copy, handler_table, count * sizeof(HandlerEntry));
    actors[actor_id].handlers = copy;
    actors[actor_id].handler_count = count;
}

// ── Scheduler ────────────────────────────────────────────

// One round-robin pass: process one message per runnable actor.
// Returns number of messages processed.
static int scheduler_step(void) {
    int processed = 0;
    int queue_size = run_queue.count;

    for (int i = 0; i < queue_size; i++) {
        int aid = run_queue_dequeue();
        if (aid < 0) break;

        Actor *a = &actors[aid];

        // Skip actors that are already executing a handler
        // (their handler called blimp_send which re-entered the scheduler)
        if (a->is_processing) {
            // Put it back, it's still runnable
            run_queue_enqueue(aid);
            a->in_run_queue = 1;
            continue;
        }

        Message *msg = mailbox_peek(&a->mailbox);
        if (msg && !msg->reply_ready) {
            a->status = ACTOR_RUNNING;
            a->is_processing = 1;
            int prev_actor = current_actor_id;
            current_actor_id = aid;

            HandlerResult result = dispatch_message(a, msg);
            msg->reply_status = result.status;
            msg->reply_value = result.value;
            msg->reply_ready = 1;
            mailbox_dequeue(&a->mailbox);

            // Log state snapshot after handler
            if (canvas_enabled && actor_fields[aid].count > 0) {
                CanvasEvent evt = { .type = EVT_STATE, .actor_id = aid, .field_count = actor_fields[aid].count };
                long long *state = (long long *)a->state_ptr;
                for (int f = 0; f < evt.field_count && f < 8; f++) evt.field_vals[f] = state[f];
                log_event(evt);
            }

            current_actor_id = prev_actor;
            a->is_processing = 0;
            a->status = ACTOR_IDLE;
            processed++;
        }

        // Re-enqueue if still has messages
        if (a->mailbox.count > 0) {
            run_queue_enqueue(aid);
            a->in_run_queue = 1;
            a->status = ACTOR_RUNNABLE;
        } else {
            a->in_run_queue = 0;
        }
    }

    return processed;
}

// Send a message and wait for the reply.
// This is what `target <- :msg(args)` compiles to.
//
// The flow:
//   1. Enqueue message into target's mailbox
//   2. If self-send, process inline (avoid deadlock)
//   3. Otherwise, pump the scheduler round-robin until reply is ready
//   4. Return the reply value
// A send that found no handler (or whose every clause's guard failed) is a
// runtime error at the send, as it is in the interpreter.
static HandlerResult finish_send(Actor *actor, Message *msg, const BlimpSite *site) {
    if (msg->reply_status == BLIMP_NOMATCH) {
        return (HandlerResult){
            .status = BLIMP_FAULT,
            .value = (long long)blimp_raise_no_handler(actor->id, msg->handler_atom_id, site),
        };
    }
    return (HandlerResult){ .status = msg->reply_status, .value = msg->reply_value };
}

HandlerResult blimp_send(int actor_id, int handler_atom_id, int arg_count, long long *args,
                         const BlimpSite *site) {
    Actor *actor = &actors[actor_id];

    // Log the send event
    log_event((CanvasEvent){
        .type = EVT_SEND,
        .actor_id = current_actor_id,
        .target_id = actor_id,
        .atom_id = handler_atom_id,
    });

    // Enqueue
    Message *msg = mailbox_enqueue(&actor->mailbox);
    if (!msg) {
        // TODO: a full mailbox is still a silent nil reply.
        return (HandlerResult){ .status = BLIMP_NIL, .value = 0 };
    }

    msg->handler_atom_id = handler_atom_id;
    msg->arg_count = arg_count;
    for (int i = 0; i < arg_count && i < MAX_ARGS; i++) {
        msg->args[i] = args[i];
    }

    // Self-send: process inline to avoid deadlock
    // (the scheduler would skip us because is_processing == 1)
    if (actor_id == current_actor_id) {
        HandlerResult result = dispatch_message(actor, msg);
        msg->reply_status = result.status;
        msg->reply_value = result.value;
        msg->reply_ready = 1;
        mailbox_dequeue(&actor->mailbox);

        // Log state snapshot after self-send handler
        if (canvas_enabled && actor_fields[actor_id].count > 0) {
            CanvasEvent evt = { .type = EVT_STATE, .actor_id = actor_id, .field_count = actor_fields[actor_id].count };
            long long *state = (long long *)actor->state_ptr;
            for (int f = 0; f < evt.field_count && f < 8; f++) evt.field_vals[f] = state[f];
            log_event(evt);
        }

        return finish_send(actor, msg, site);
    }

    // Mark target as runnable
    if (actor->status == ACTOR_IDLE) {
        actor->status = ACTOR_RUNNABLE;
    }
    if (!actor->in_run_queue) {
        run_queue_enqueue(actor_id);
        actor->in_run_queue = 1;
    }

    // Pump the scheduler until our message gets a reply
    while (!msg->reply_ready) {
        int progress = scheduler_step();
        if (progress == 0 && !msg->reply_ready) {
            fprintf(stderr, "blimp: deadlock - actor %d waiting for reply from actor %d\n",
                    current_actor_id, actor_id);
            // TODO: a deadlock is still a nil reply after this line.
            return (HandlerResult){ .status = BLIMP_NIL, .value = 0 };
        }
    }

    return finish_send(actor, msg, site);
}

void *blimp_get_state(int actor_id) {
    return actors[actor_id].state_ptr;
}

int blimp_actor_count(void) {
    return actor_count;
}

// Scheduler: drain all pending messages across all actors.
// Called at the end of main() to process any remaining async work.
void blimp_scheduler_run(void) {
    // Seed run queue with any actors that have pending messages
    for (int i = 0; i < actor_count; i++) {
        if (actors[i].mailbox.count > 0 && !actors[i].in_run_queue) {
            run_queue_enqueue(i);
            actors[i].in_run_queue = 1;
            actors[i].status = ACTOR_RUNNABLE;
        }
    }

    // Drain until all quiet
    while (run_queue.count > 0) {
        int processed = scheduler_step();
        if (processed == 0) break;
    }
}

// ── Canvas JSON export ──────────────────────────────────

void blimp_canvas_dump(const char *path) {
    if (!canvas_enabled || event_count == 0) return;

    FILE *f = fopen(path, "w");
    if (!f) { fprintf(stderr, "blimp: cannot write canvas to %s\n", path); return; }

    fprintf(f, "[\n");
    for (int i = 0; i < event_count; i++) {
        CanvasEvent *e = &event_log[i];
        if (i > 0) fprintf(f, ",\n");
        switch (e->type) {
            case EVT_SPAWN:
                fprintf(f, "  {\"t\":\"spawn\",\"id\":%d,\"type\":\"%s\"}", e->actor_id, e->type_name ? e->type_name : "?");
                break;
            case EVT_SEND:
                fprintf(f, "  {\"t\":\"send\",\"from\":%d,\"to\":%d,\"msg\":\"%s\"}", e->actor_id, e->target_id, atom_name(e->atom_id));
                break;
            case EVT_STATE: {
                fprintf(f, "  {\"t\":\"state\",\"id\":%d,\"fields\":{", e->actor_id);
                ActorFieldInfo *fi = &actor_fields[e->actor_id];
                for (int j = 0; j < e->field_count && j < 8; j++) {
                    if (j > 0) fprintf(f, ",");
                    const char *fname = (fi->names && j < fi->count) ? fi->names[j] : "?";
                    fprintf(f, "\"%s\":%lld", fname, e->field_vals[j]);
                }
                fprintf(f, "}}");
                break;
            }
        }
    }
    fprintf(f, "\n]\n");
    fclose(f);
}
