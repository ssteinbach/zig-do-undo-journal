//! Journaling Undo System.  See Journal struct for more information.

const std = @import("std");

const command = @import("command.zig");

/// a journal of commands that support undo/redo
pub const Journal = struct {
    allocator: std.mem.Allocator,

    /// sorted such that lower indices in the entries arraylist are earlier
    /// than entries with larger indices
    entries: std.ArrayListUnmanaged(command.Command),

    /// limit on the number of entries.  Entries added once the Journal is at
    /// max_depth entries will cause the first entries in the journal to be
    /// removed.
    max_depth: usize,

    /// the current head.  Undo will move this back from most recently added 
    /// entry in the .entries ArrayList
    maybe_head_entry: ?usize,

    /// ammount of time to allow updating rather than appending new commands,
    /// in milliseconds
    update_window_ms: i64 = 250, 

    /// the last time this journal was updated
    _last_append_ms: ?i64 = null,

    _mutex: std.Thread.Mutex = .{},

    pub fn init(
        allocator: std.mem.Allocator,
        max_depth: usize,
    ) !Journal
    {
        const entries = try std.ArrayListUnmanaged(
            command.Command
        ).initCapacity(allocator, max_depth);

        return .{
            .allocator = allocator,
            .entries = entries,
            .max_depth = max_depth,
            .maybe_head_entry = null,
            ._last_append_ms = null,
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
    ///
    /// Journal owns the memory of the cmd passed in.
    pub fn add(
        self: *@This(),
        cmd: command.Command,
    ) !void
    {
        self._mutex.lock();
        defer self._mutex.unlock();

        return self.add_while_locked(cmd);
    }

    /// with the mutex locked, perform the add
    fn add_while_locked(
        self: *@This(),
        cmd: command.Command,
    ) !void
    {
        // set the time stamp
        self._last_append_ms = std.time.milliTimestamp();

        self.truncate_while_locked(self.maybe_head_entry);

        try self.entries.append(self.allocator, cmd);

        // if the journal was full
        if (
            self.maybe_head_entry != null 
            and self.maybe_head_entry.? >= self.max_depth - 1
        ) 
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

    /// if it has been less than UPDATE_WINDOW and the hash of this command
    /// matches the most recent command, replace that command with this one.
    ///
    /// Otherwise add the new command to the stack.
    ///
    /// Journal owns the memory of the cmd passed in.
    pub fn update_if_new_or_add(
        self: *@This(),
        cmd: command.Command,
    ) !void
    {
        self._mutex.lock();
        defer self._mutex.unlock();

        // if outside of the update window
        if (
            self._last_append_ms == null
            or (
                std.time.milliTimestamp() 
                > self._last_append_ms.? + self.update_window_ms
            )
            or self.maybe_head_command() == null
            or (
                cmd.command_type_destination_hash 
                != self.maybe_head_command().?.command_type_destination_hash
            )
        )
        {
            return self.add_while_locked(cmd);
        }

        // otherwise replace the latest entry with this one
        try self.entries.items[self.maybe_head_entry.?].update(
            self.allocator,
            cmd,
        );
        self._last_append_ms = std.time.milliTimestamp();

        cmd.destroy(self.allocator);
    }

    /// if there is a head_entry, return the head command, otherwise return
    /// null.  does not lock the mutex
    pub fn maybe_head_command(
        self: @This(),
    ) ?command.Command
    {
        if (self.maybe_head_entry)
            |head_index|
        {
            return self.entries.items[head_index];
        }

        return null;
    }

    /// undo the last command added to the journal
     pub fn undo(
         self: *@This(),
     ) !void
     {
         self._mutex.lock();
         defer self._mutex.unlock();

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

     /// redo the next command in the journal that was undone (if one exists)
     pub fn redo(
         self: *@This(),
     ) !void
     {
         self._mutex.lock();
         defer self._mutex.unlock();

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
         // no head entry, but items in stack
         else if (self.entries.items.len > 0) 
         {
             const next_index = 0;
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
         self._mutex.lock();
         defer self._mutex.unlock();

         self.truncate_while_locked(maybe_index);
     }

     /// internal function to execute the truncation while locked
     fn truncate_while_locked(
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
             self.clear_while_locked();
         }
     }

     /// free all entries in the journal
     pub fn clear(
         self: *@This(),
     ) void
     {
         self._mutex.lock();
         defer self._mutex.unlock();

         self.clear_while_locked();
     }

     fn clear_while_locked(
         self: *@This(),
     ) void
     {
         while (self.entries.items.len > 0)
         {
             const cmd = self.entries.pop().?;
             cmd.destroy(self.allocator);
         }
         self.maybe_head_entry = null;
     }

    pub fn deinit(
        self: *@This(),
    ) void
    {
        self._mutex.lock();
        defer self._mutex.unlock();

        self.clear_while_locked();
        self.entries.deinit(self.allocator);
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
    try std.testing.expectEqual(4, value);
    try journal.undo();
    try std.testing.expectEqual(3, value);

    try std.testing.expectEqual(TEST_JOURNAL_LIMIT, journal.max_depth);
    try std.testing.expectEqual(3, journal.entries.items.len);
    try std.testing.expectEqual(0, journal.maybe_head_entry);

    try journal.redo();
    try std.testing.expectEqual(4, value);
    try std.testing.expectEqual(TEST_JOURNAL_LIMIT, journal.max_depth);
    try std.testing.expectEqual(3, journal.entries.items.len);
    try std.testing.expectEqual(1, journal.maybe_head_entry);

    try journal.undo();
    try std.testing.expectEqual(3, value);
    try journal.undo();
    try std.testing.expectEqual(2, value);
    try journal.redo();
    try std.testing.expectEqual(3, value);
}

test "Update rather than add"
{
    const TEST_TYPE = i32;
    const TEST_JOURNAL_LIMIT:usize = 3;

    var journal = try Journal.init(
        std.testing.allocator,
        TEST_JOURNAL_LIMIT, 
    );
    // big number that is hopefully bigger than computer can run this test
    journal.update_window_ms = 10000000;
    defer journal.deinit();

    const ORIGINAL_VALUE: TEST_TYPE = 12;
    var value: TEST_TYPE = ORIGINAL_VALUE;

    try std.testing.expect(journal.maybe_head_entry == null);

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

        // should update
        try cmd.do();
        try journal.update_if_new_or_add(cmd);

        try std.testing.expectEqual(i, value);

        try std.testing.expect(journal.maybe_head_entry != null);
    }

    try std.testing.expectEqual(1, journal.entries.items.len);
    try std.testing.expectEqual(0, journal.maybe_head_entry);
    try std.testing.expectEqual(5, value);

    // should return to its original value (12)
    try journal.undo();

    try std.testing.expectEqual(ORIGINAL_VALUE, value);
}
