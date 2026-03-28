const std = @import("std");
const Value = @import("value.zig").Value;
const Registry = @import("registry.zig").Registry;
const Mailbox = @import("mailbox.zig");

/// The actor scheduler. Manages the run queue and drives message processing.
///
/// Design: cooperative scheduling with reduction counting.
/// Each actor gets a timeslice (default 4000 reductions). After exhausting
/// its reductions, it yields and goes to the back of the queue.
///
/// For now, the scheduler processes one message per actor per tick (round-robin).
/// This is sufficient for concurrent web connections.
pub const Scheduler = struct {
    allocator: std.mem.Allocator,
    /// Actors with pending messages, in FIFO order
    run_queue: std.ArrayListUnmanaged(u64), // actor instance IDs
    /// Default reductions per timeslice
    default_reductions: u32 = 4000,

    pub fn init(allocator: std.mem.Allocator) Scheduler {
        return .{
            .allocator = allocator,
            .run_queue = .{},
        };
    }

    /// Add an actor to the run queue (if not already queued).
    pub fn enqueue(self: *Scheduler, actor_id: u64) void {
        // Avoid duplicates
        for (self.run_queue.items) |id| {
            if (id == actor_id) return;
        }
        self.run_queue.append(self.allocator, actor_id) catch {};
    }

    /// Remove and return the next actor ID from the front of the queue.
    pub fn dequeue(self: *Scheduler) ?u64 {
        if (self.run_queue.items.len == 0) return null;
        const id = self.run_queue.items[0];
        if (self.run_queue.items.len > 1) {
            std.mem.copyForwards(u64, self.run_queue.items[0 .. self.run_queue.items.len - 1], self.run_queue.items[1..]);
        }
        self.run_queue.shrinkRetainingCapacity(self.run_queue.items.len - 1);
        return id;
    }

    /// Number of actors in the run queue.
    pub fn queueLen(self: *const Scheduler) usize {
        return self.run_queue.items.len;
    }

    /// Is the run queue empty?
    pub fn isEmpty(self: *const Scheduler) bool {
        return self.run_queue.items.len == 0;
    }
};
