//! Test Abstract Function Call Wrapped through a decorator

const std = @import("std");

const journal_mod = @import("journal2.zig");

var was_decorated = false;

fn before(
) void
{
    was_decorated = true;
}

fn after(
) void
{
}

const BASE_TYPE = f32;

/// function that is going to be wrapped in a command
fn some_function(
    a: BASE_TYPE,
    b: BASE_TYPE
) BASE_TYPE
{
    return a + (b*b);
}

pub fn CommandOf(
    comptime target_fn: anytype,
)type
{
    return CommandWrapper(@TypeOf(target_fn), target_fn);
}

pub fn CommandWrapper(
    comptime target_fn_type: type,
    target_fn: target_fn_type,
) type
{
    const fn_info = @typeInfo(target_fn_type).@"fn";

    // caching the return type of the function
    const return_type = fn_info.return_type orelse void;

    const arguments = arg_type: {
        var field_types: [fn_info.params.len]type = undefined;

        inline for (&field_types, fn_info.params)
            |*t, param|
        {
            t.* = param.type orelse void;
        }

        break :arg_type @Tuple(&field_types);
    };

    return struct{
        pub fn do(
            args: arguments
        ) return_type
        {
            before();

            const result =  @call(.auto, target_fn, args);

            after();

            return result;
        }
    };
}

const cmd_some_fn = CommandOf(
    some_function
);

test "test calling the function through the command interface"
{
    const a: BASE_TYPE = 12;
    const b: BASE_TYPE = 13;

    const direct_result = some_function(a, b);
    const c = direct_result;

    const cmd_direct_result = cmd_some_fn.do(
        .{ a, b }
    );

    try std.testing.expectEqual(
        direct_result,
        c,
    );
    try std.testing.expectEqual(
        cmd_direct_result,
        c,
    );
    try std.testing.expectEqual(true, was_decorated);
}

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

    fn UndoAble(
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
                    undoable: journal_mod.Undoable,
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
                    undoable: *journal_mod.Undoable,
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
                journal: *journal_mod.Journal,
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

    pub const cmd_add = UndoAble(SingleStateCalculator.add).do;
    pub const cmd_sub = UndoAble(SingleStateCalculator.sub).do;
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

    var journal: journal_mod.Journal = .empty;
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
