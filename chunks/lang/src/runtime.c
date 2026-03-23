#include <stdio.h>
#include <stdlib.h>
#include <string.h>
#include <time.h>

// ── Print functions ──────────────────────────────────────

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

// Actor instance
typedef struct {
    void *state_ptr;
    HandlerEntry *handlers;
    int handler_count;
    Mailbox mailbox;
    int id;
} Actor;

// Global registry
static Actor actors[MAX_ACTORS];
static int actor_count = 0;

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
    return id;
}

void blimp_set_handlers(int actor_id, void *handler_table, int count) {
    // Copy the handler table (the original is on the stack)
    HandlerEntry *copy = (HandlerEntry *)malloc(count * sizeof(HandlerEntry));
    memcpy(copy, handler_table, count * sizeof(HandlerEntry));
    actors[actor_id].handlers = copy;
    actors[actor_id].handler_count = count;
}

// Send a message and wait for the reply (synchronous send-and-receive).
// This is what `target <- :msg(args)` compiles to.
//
// The flow:
//   1. Enqueue message into target's mailbox
//   2. Process the target's mailbox (run the handler)
//   3. Return the reply value
//
// In a future multi-threaded runtime, step 2 would be done by the
// scheduler on the target's thread, and the sender would spin/park
// on reply_ready. For now, we process inline to avoid deadlocks
// on a single thread.
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

    // Process immediately (single-threaded scheduler)
    Message *pending = mailbox_peek(&actor->mailbox);
    if (pending) {
        long long result = dispatch_message(actor, pending);
        pending->reply_value = result;
        pending->reply_ready = 1;
        mailbox_dequeue(&actor->mailbox);
        return result;
    }

    return 0;
}

void *blimp_get_state(int actor_id) {
    return actors[actor_id].state_ptr;
}

int blimp_actor_count(void) {
    return actor_count;
}

// Scheduler: drain all pending messages across all actors.
// Called at the end of main() to process any remaining async work.
// Round-robin: process one message per actor per pass until all empty.
void blimp_scheduler_run(void) {
    int active = 1;
    while (active) {
        active = 0;
        for (int i = 0; i < actor_count; i++) {
            Message *msg = mailbox_peek(&actors[i].mailbox);
            if (msg && !msg->reply_ready) {
                long long result = dispatch_message(&actors[i], msg);
                msg->reply_value = result;
                msg->reply_ready = 1;
                mailbox_dequeue(&actors[i].mailbox);
                active = 1;
            }
        }
    }
}
