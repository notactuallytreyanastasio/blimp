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
        case VAL_ATOM: printf(":%d\n", v->atom_id); break;
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
                    case VAL_ATOM: printf(":%d", mv->atom_id); break;
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

// ── Actor Runtime ────────────────────────────────────────

#define MAX_ACTORS 256
#define MAILBOX_CAPACITY 256
#define MAX_ARGS 8

// Handler result: {matched, value}
typedef struct {
    char matched;
    long long value;
} HandlerResult;

// Message in mailbox
typedef struct {
    int handler_atom_id;
    int arg_count;
    long long args[MAX_ARGS];
    volatile int reply_ready;  // 0 = pending, 1 = done
    long long reply_value;
} Message;

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

static long long dispatch_message(Actor *actor, Message *msg) {
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

        if (result.matched) {
            return result.value;
        }
        // Guard failed, try next clause
    }
    return 0; // No handler matched
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

            long long result = dispatch_message(a, msg);
            msg->reply_value = result;
            msg->reply_ready = 1;
            mailbox_dequeue(&a->mailbox);

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
long long blimp_send(int actor_id, int handler_atom_id, int arg_count, long long *args) {
    Actor *actor = &actors[actor_id];

    // Enqueue
    Message *msg = mailbox_enqueue(&actor->mailbox);
    if (!msg) return 0;

    msg->handler_atom_id = handler_atom_id;
    msg->arg_count = arg_count;
    for (int i = 0; i < arg_count && i < MAX_ARGS; i++) {
        msg->args[i] = args[i];
    }

    // Self-send: process inline to avoid deadlock
    // (the scheduler would skip us because is_processing == 1)
    if (actor_id == current_actor_id) {
        long long result = dispatch_message(actor, msg);
        msg->reply_value = result;
        msg->reply_ready = 1;
        mailbox_dequeue(&actor->mailbox);
        return result;
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
            return 0;
        }
    }

    return msg->reply_value;
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
