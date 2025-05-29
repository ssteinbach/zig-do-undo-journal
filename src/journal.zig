//! Journaling system for dealing with undos

const std = @import("std");

const command = @import("command.zig");

/// a journal of commands that support undo/redo
const Journal = struct {
    allocator: std.mem.Allocator,

    /// sorted such that lower indices in the entries arraylist are earlier
    /// than entries with larger indices
    entries: std.ArrayList(command.Command),

    /// limit on the number of entries.  Entries added once the Journal is at
    /// max_depth entries will cause the first entries in the journal to be
    /// removed.
    max_depth: usize,

    /// the current head.  Undo will move this back from most recently added 
    /// entry in the .entries ArrayList
    maybe_head_entry: ?usize,

    pub fn init(
        allocator: std.mem.Allocator,
        max_depth: usize,
    ) !Journal
    {
        var entries = std.ArrayList(command.Command).init(allocator);
        try entries.ensureTotalCapacity(max_depth);

        return .{
            .allocator = allocator,
            .entries = entries,
            .max_depth = max_depth,
            .maybe_head_entry = null,
        };
    }

    /// returns whether this journal has any entries that can be undone
    pub fn can_undo(
        self: @This(),
    ) bool
    {
        return self.maybe_head_entry != null;
    }

    /// add a command to the end of the journal
    pub fn add(
        self: *@This(),
        cmd: command.Command,
    ) !void
    {
        if (self.maybe_head_entry)
            |head_index|
        {
            self.truncate(head_index);
        }

        try self.entries.append(cmd);

        // if the journal was full
        if (self.entries.items.len > self.max_depth) 
        {
            var popped_thing = self.entries.orderedRemove(0);
            popped_thing.destroy(self.allocator);
        }
        // if it wasn't, increment the head index pointer
        else
        {
            self.maybe_head_entry = (
                if (self.maybe_head_entry == null) 0 
                else (self.maybe_head_entry.? + 1)
            );
        }
    }

    /// undo the last command added to the journal
     pub fn undo(
         self: *@This(),
     ) !void
     {
         // nothing else to undo
         if (self.entries.items.len == 0 or self.maybe_head_entry == null) 
         {
             return;
         }

         const head_index = self.maybe_head_entry.?;

         try self.entries.items[head_index].undo();

         self.maybe_head_entry = (
             if (head_index > 0) head_index - 1
             else null
         );
     }

     pub fn redo(
         self: *@This(),
     ) !void
     {
         // nothing to redo
         if (self.maybe_head_entry)
             |index|
         {
             if (index >= self.entries.items.len - 1)
             {
                 self.maybe_head_entry = self.entries.items.len - 1;
                 return;
             }

             const next_index = index + 1;
             try self.entries.items[next_index].do();
             self.maybe_head_entry = next_index;
         }
     }

     /// clears the history from the end until the given index is reached.
     /// For example, if the Journal includes 5 entries, and 2 is passed as the
     /// until_index, then it will remove the [4] and the [3] entry but leave
     /// the [2] entry.
     pub fn truncate(
         self: *@This(),
         maybe_index: ?usize,
     ) void
     {
         if (maybe_index)
             |index|
         {
             if (index >= self.entries.items.len)
             {
                 return;
             }

             while (self.entries.items.len - 1 > index)
             {
                 const cmd = self.entries.pop().?;
                 cmd.destroy(self.allocator);
             }

             self.maybe_head_entry = index;
         }
         else
         {
             self.clear();
         }
     }

     /// free all entries in the journal
     pub fn clear(
         self: *@This(),
     ) void
     {
         while (self.entries.items.len > 0)
         {
             const cmd = self.entries.pop().?;
             cmd.destroy(self.allocator);
             self.maybe_head_entry = null;
         }
     }

    pub fn deinit(
        self: *@This(),
    ) void
    {
        while (self.entries.items.len > 0)
        {
            const cmd = self.entries.pop();
            cmd.?.destroy(self.allocator);
        }

        self.entries.deinit();
        self.max_depth = 0;
    }
};

test "Journal Test"
{
    const TEST_TYPE = i32;
    const TEST_JOURNAL_LIMIT:usize = 3;

    var journal = try Journal.init(
        std.testing.allocator,
        TEST_JOURNAL_LIMIT, 
    );
    defer journal.deinit();

    var value: TEST_TYPE = 12;

    {
        const cmd = try command.SetValue(TEST_TYPE).init(
            std.testing.allocator,
            &value,
            142,
            "value",
        );

        try cmd.do();
        try std.testing.expectEqual(142, value);

        try std.testing.expectEqual(
            TEST_JOURNAL_LIMIT,
            journal.max_depth
        );
        try std.testing.expectEqual(
            0,
            journal.entries.items.len
        );

        try journal.add(cmd);
        try std.testing.expectEqual(TEST_JOURNAL_LIMIT, journal.max_depth);
        try std.testing.expectEqual(1, journal.entries.items.len);
        try std.testing.expectEqual(0, journal.maybe_head_entry);
    }

    try journal.undo();
    try std.testing.expectEqual(TEST_JOURNAL_LIMIT, journal.max_depth);
    try std.testing.expectEqual(1, journal.entries.items.len);
    try std.testing.expectEqual(null, journal.maybe_head_entry);

    var i:TEST_TYPE = 1;
    while (i <= 5)
        : (i+=1)
    {
        const cmd = try command.SetValue(TEST_TYPE).init(
            std.testing.allocator,
            &value,
            i,
            "value",
        );

        try cmd.do();
        try std.testing.expectEqual(i, value);

        try journal.add(cmd);
    }

    // should have been 1,2,3,4,5, with the resulting journal being 3,4,5
    try std.testing.expectEqual(5, value);

    try std.testing.expectEqual(TEST_JOURNAL_LIMIT, journal.max_depth);
    try std.testing.expectEqual(TEST_JOURNAL_LIMIT, journal.entries.items.len);

    while (journal.can_undo())
        : (try journal.undo())
    {
    }

    try std.testing.expectEqual(2, value);

    try std.testing.expectEqual(TEST_JOURNAL_LIMIT, journal.max_depth);
    try std.testing.expectEqual(3, journal.entries.items.len);
    try std.testing.expectEqual(null, journal.maybe_head_entry);

}

test "Journal Test (undo/redo)"
{
    const TEST_TYPE = i32;
    const TEST_JOURNAL_LIMIT:usize = 3;

    var journal = try Journal.init(
        std.testing.allocator,
        TEST_JOURNAL_LIMIT, 
    );
    defer journal.deinit();

    var value: TEST_TYPE = 12;

    var i:TEST_TYPE = 1;
    while (i <= 5)
        : (i+=1)
    {
        const cmd = try command.SetValue(TEST_TYPE).init(
            std.testing.allocator,
            &value,
            i,
            "value",
        );

        try cmd.do();
        try std.testing.expectEqual(i, value);

        try journal.add(cmd);
    }

    // should have been 1,2,3,4,5, with the resulting journal being 3,4,5
    try std.testing.expectEqual(5, value);

    try std.testing.expectEqual(TEST_JOURNAL_LIMIT, journal.max_depth);
    try std.testing.expectEqual(TEST_JOURNAL_LIMIT, journal.entries.items.len);

    // undo twice, leaving one action in the journal
    try journal.undo();
    try journal.undo();

    try std.testing.expectEqual(3, value);

    try std.testing.expectEqual(TEST_JOURNAL_LIMIT, journal.max_depth);
    try std.testing.expectEqual(3, journal.entries.items.len);
    try std.testing.expectEqual(0, journal.maybe_head_entry);

    try journal.redo();
}
