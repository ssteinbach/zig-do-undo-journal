const std = @import("std");

/// Takes a `target_fn` and an optional undo context.  Returns a structure
/// with a `do` function that, when called, calls the function and then
/// interacts with the undo journal.
///
/// If no MaybeUndoContext is provided, then the function is non-undoable, and
/// calling the resulting `do` function will clear the journal after calling
/// `target_fn`.
///
/// See below for a description of what is expected to exist on
/// `MaybeUndoContext`.
pub fn JournalledWrapperFnOf(
    /// The target function that will be wrapped with undo journal entry
    /// (or marked as not-undoable, which clears the journal out).
    comptime target_fn: anytype,

    /// If a parent class is provided, it is assumed to be the first argument
    /// to do function, so that you can do something like:
    ///
    /// ```zig
    /// const ParentStruct = struct {
    ///    const cmd_some_func = JournalledWrapperFnOf(some_func);
    ///    ...
    /// }
    ///
    /// const p = ParentStruct{};
    /// p.cmd_some_func(journal);
    ///
    /// And `p` will be automatically passed in as the first argument to the
    /// argument vector.
    comptime MaybeMethodParentClass: ?type,

    /// The UndoContext is a structure that defines (optionally) two
    /// functions:
    /// undo(UndoContext) anyerror!void
    /// redo(UndoContext) anyerror!void
    ///
    /// If UndoContext is null, then this function is considered
    /// not-undoable and will clear the journal when the function is called.
    comptime MaybeUndoContext: ?type,
) type
{
    // TODO: handle functions that don't need an error

    const target_fn_type = @TypeOf(target_fn);
    const fn_info = @typeInfo(target_fn_type).@"fn";

    // caching the return type of the function
    const return_type = fn_info.return_type orelse void;

    const arguments = arg_type: {
        // skip the first argument (the calculator, we'll pass that
        // through separately)
        var field_types: [fn_info.params.len - 1]type = undefined;

        inline for (&field_types, fn_info.params[1..])
            |*t, param|
            {
                t.* = param.type orelse void;
            }

        break :arg_type @Tuple(&field_types);
    };

    if (MaybeUndoContext) 
        |UndoContext|
    {
        if (MaybeMethodParentClass)
            |ParentStruct|
        {
            return struct {
                // Calls target_fn and clears the journal.
                pub fn do(
                    allocator: std.mem.Allocator,
                    journal: *Journal,
                    parent: *ParentStruct,
                    undo_context: *UndoContext,
                    args: arguments,
                ) !return_type
                {
                    const result = @call(
                        .auto,
                        target_fn,
                        .{parent} ++ args
                    );

                    try journal.append(
                        allocator,
                        .{
                            .maybe_blind_context = @ptrCast(undo_context),
                            .undo = UndoContext.undo,
                            .maybe_destroy = UndoContext.destroy,
                        },
                    );

                    return result;
                }
            };
        }
        else 
        {
            return struct {
                // Calls target_fn and clears the journal.
                pub fn do(
                    journal: *Journal,
                    args: arguments,
                ) !return_type
                {
                    const result = try @call(
                        .auto,
                        target_fn,
                        args,
                    );

                    try journal.clear();
                    return result;
                }
            };
        }
    }
    else
    {
        // Not Undoable
        if (MaybeMethodParentClass)
            |ParentStruct|
        {
            return struct {
                // Calls target_fn and clears the journal.
                pub fn do(
                    parent: ParentStruct,
                    journal: *Journal,
                    args: arguments,
                ) !return_type
                {
                    const result = try target_fn(.{parent} ++ args);
                    try journal.clear();
                    return result;
                }
            };
        }
        else 
        {
            return struct {
                // Calls target_fn and clears the journal.
                pub fn do(
                    journal: *Journal,
                    args: arguments,
                ) !return_type
                {
                    const result = try target_fn(args);
                    try journal.clear();
                    return result;
                }
            };
        }

    }
}

pub const JournalEntry = struct {
    maybe_blind_context: ?*anyopaque,

    /// undo the operation
    undo: *const fn (
        JournalEntry,
    ) anyerror!void,

    /// destroy the blind context, if it exists
    maybe_destroy: ?*const fn (
        std.mem.Allocator,
        *JournalEntry,
    ) anyerror!void,
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
