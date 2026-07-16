const std = @import("std");

pub const JournalEntry = struct {
    maybe_blind_context: ?*anyopaque,

    /// undo the operation
    undo: *const fn (JournalEntry) anyerror!void,

    /// destroy the blind context, if it exists
    maybe_destroy: ?*const fn (std.mem.Allocator, *JournalEntry) anyerror!void,
};

/// Stripped down undo journal for testing
pub const Journal = struct {
    entries: std.ArrayList(JournalEntry) = .empty,

    pub const empty: Journal = .{ .entries = .empty };

    pub fn deinit(
        self: *Journal,
        allocator: std.mem.Allocator,
    ) void
    {
        for (self.entries.items)
            |*entry|
        {
            if (entry.maybe_destroy)
                |destroy|
            {
                destroy(allocator, entry) catch {};
            }
        }

        self.entries.deinit(allocator);
    }

    pub fn append(
        self: *Journal,
        allocator: std.mem.Allocator,
        undoable: JournalEntry,
    ) anyerror!void
    {
        try self.entries.append(allocator, undoable);
    }

    pub fn undo(
        self: *Journal,
        allocator: std.mem.Allocator,
    ) !void
    {
        var maybe_entry = self.entries.pop();
        if (maybe_entry)
            |*entry|
        {
            try entry.undo(entry.*);
            if (entry.maybe_destroy)
                |destroy|
            {
                try destroy(allocator, entry);
            }
        }
    }
};
