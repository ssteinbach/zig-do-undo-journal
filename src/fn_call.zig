const std = @import("std");

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

