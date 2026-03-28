const std = @import("std");
const Value = @import("value.zig").Value;

/// A message waiting in an actor's mailbox.
pub const Message = struct {
    name: []const u8, // handler name (e.g. "increment")
    args: []const *const Value, // deep-copied argument values
    reply_slot: ?*?*const Value, // if non-null, sender is blocked waiting for reply here
};

/// Per-actor FIFO message queue.
pub const Mailbox = struct {
    messages: std.ArrayListUnmanaged(Message),

    pub fn init() Mailbox {
        return .{ .messages = .{} };
    }

    pub fn enqueue(self: *Mailbox, allocator: std.mem.Allocator, msg: Message) void {
        self.messages.append(allocator, msg) catch {};
    }

    pub fn dequeue(self: *Mailbox, allocator: std.mem.Allocator) ?Message {
        if (self.messages.items.len == 0) return null;
        const msg = self.messages.items[0];
        // Shift remaining messages forward
        if (self.messages.items.len > 1) {
            std.mem.copyForwards(Message, self.messages.items[0 .. self.messages.items.len - 1], self.messages.items[1..]);
        }
        self.messages.shrinkRetainingCapacity(self.messages.items.len - 1);
        _ = allocator;
        return msg;
    }

    pub fn isEmpty(self: *const Mailbox) bool {
        return self.messages.items.len == 0;
    }

    pub fn len(self: *const Mailbox) usize {
        return self.messages.items.len;
    }
};
