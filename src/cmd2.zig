//! Test Abstract Function Call Wrapped through a decorator

const std = @import("std");

const undo_journal = @import("journal2.zig");

const BASE_TYPE = f32;

const SingleStateCalculator = struct {
    state: BASE_TYPE,

    pub const zero = SingleStateCalculator{ .state = 0 };

    pub fn add(
        self: *SingleStateCalculator,
        rhs: BASE_TYPE,
    ) BASE_TYPE
    {
        self.state += rhs;
        return self.state;
    }

    pub fn sub(
        self: *SingleStateCalculator,
        rhs: BASE_TYPE,
    ) BASE_TYPE
    {
        self.state -= rhs;
        return self.state;
    }

    fn CommandifyCalcFn(
        comptime target_fn: anytype,
    ) type
    {
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

        return struct{
            pub const UndoContext = struct {
                parent_calculator: *SingleStateCalculator,
                last_state: BASE_TYPE,

                pub fn undo(
                    undoable: undo_journal.JournalEntry,
                ) anyerror!void
                {
                    if (undoable.maybe_blind_context)
                        |blind_context|
                    {
                        const context: *UndoContext = @alignCast(@ptrCast(blind_context));

                        context.parent_calculator.state = context.last_state;
                    }
                    else 
                    {
                        return error.NoUndoContext;
                    }
                }

                pub fn destroy(
                    allocator: std.mem.Allocator,
                    undoable: *undo_journal.JournalEntry,
                ) anyerror!void
                {
                    if (undoable.maybe_blind_context)
                        |blind_context|
                    {
                        const context: *UndoContext = @alignCast(@ptrCast(blind_context));

                        allocator.destroy(context);
                        undoable.maybe_blind_context = null;
                    }
                    else 
                    {
                        return error.NoUndoContext;
                    }
                }
            };

            pub fn do(
                calc: *SingleStateCalculator,
                allocator: std.mem.Allocator,
                journal: *undo_journal.Journal,
                args: arguments
            ) !return_type
            {
                const context = try allocator.create(UndoContext);

                context.parent_calculator = calc;
                context.last_state = calc.state;

                const result =  @call(
                    .auto,
                    target_fn,
                    .{calc} ++ args
                );

                try journal.append(
                    allocator,
                    .{
                        .maybe_blind_context = @ptrCast(context),
                        .undo = UndoContext.undo,
                        .maybe_destroy = UndoContext.destroy,
                    },
                );

                return result;
            }
        };
    }

    pub const cmd_add = CommandifyCalcFn(SingleStateCalculator.add).do;
    pub const cmd_sub = CommandifyCalcFn(SingleStateCalculator.sub).do;
};

test "Calculator basic"
{
    var calc: SingleStateCalculator = .zero;

    _ = calc.add(1);
    const result = calc.add(5);

    try std.testing.expectEqual(
        6, 
        result,
    );

    const result2 = calc.sub(2);
    try std.testing.expectEqual(
        4, 
        result2
    );
}

test "With Journal"
{
    const allocator = std.testing.allocator;

    var journal: undo_journal.Journal = .empty;
    defer journal.deinit(allocator);

    var calc: SingleStateCalculator = .zero;

    _ = try calc.cmd_add(
        allocator,
        &journal,
        .{ 1 },
    );

    const result = try calc.cmd_add(
        allocator,
        &journal,
        .{ 5 },
    );

    try std.testing.expectEqual(6, result);

    try journal.undo(allocator);

    try std.testing.expectEqual( 1, calc.state);

    _ = try calc.cmd_sub(
        allocator,
        &journal,
        .{ 1 },
    );

    try std.testing.expectEqual(0, calc.state);

    try journal.undo(allocator);

    try std.testing.expectEqual(1, calc.state);
}
