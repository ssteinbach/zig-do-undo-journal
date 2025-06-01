const std = @import("std");
const Hash = u64;

/// encapsulation of a state change, with a do and undo
pub const Command = struct {
    /// a context.  the provided function pointers can cast into a concrete 
    /// type and read information from in order to do or undo the command
    context: *anyopaque,

    /// a user friendly message that describes the command
    message: []const u8,

    /// a unique identifier for a command that combines the Command type and
    /// the destination.
    command_type_destination_hash: Hash,

    // function pointers that need to be defined

    /// do the command
    _do: *const fn (ctx: *anyopaque) void,
    /// undo the command
    _undo: *const fn (ctx: *anyopaque) void,
    /// update the command in place (typically in the journal). if an "old
    /// value" is present in the undo, preserve that such that:
    /// cmd1: valA -> valB (undo: valB->valA)
    /// cmd2: valB -> valC (undo: valC->valB)
    /// cmd1.update(cmd2)
    /// cmd1.undo() (valC->valA)
    _update: *const fn (ctx: *anyopaque, new_ctx: *anyopaque) void,
    /// free the memory of this command
    _destroy: *const fn (ctx: *anyopaque, std.mem.Allocator) void,

    pub fn do(
        self: @This(),
    ) !void 
    {
        self._do(self.context);
    }

    pub fn undo(
        self: @This(),
    ) !void 
    {
        self._undo(self.context);
    }

    /// update this command with the details from the other command in place
    pub fn update(
        self: *@This(),
        allocator: std.mem.Allocator,
        rhs: Command,
    ) !void
    {
        // copy the context
        self._update(self.context, rhs.context);

        // copy the message
        allocator.free(self.message);
        self.message = try allocator.dupe(u8, rhs.message);
    }

    /// free the memory associated with this command
    pub fn destroy(
        self: @This(),
        allocator: std.mem.Allocator,
    ) void 
    {
        allocator.free(self.message);
        self._destroy(self.context, allocator);
    }
};

/// example command that produces a command for setting a value
pub fn SetValue(
    comptime T: type,
) type 
{
    return struct {
        const Context = struct {
            parameter: *T,
            oldvalue: T,
            newvalue: T,
        };

        const base_hash = h: {
            var hasher = std.hash.Wyhash.init(0);

            const KEY = "SetValue_" ++ @typeName(T);

            // comptime requires walking across the characters in the string
            // (as of zig 0.14.0)
            for (KEY)
                |k|
            {
                std.hash.autoHash(&hasher, k);
            }

            break :h hasher.final();
        };

        pub fn init(
            allocator: std.mem.Allocator,
            parameter: *T,
            newvalue: T,
            parameter_name: ?[]const u8,
        ) !Command
        {
            const ctx: *Context  = try allocator.create(Context);
            ctx.* = .{
                .parameter = parameter,
                .oldvalue = parameter.*,
                .newvalue = newvalue,
            };

            const hash = h: {
                var hasher = std.hash.Wyhash.init(base_hash);

                std.hash.autoHash(&hasher, ctx.*.parameter);

                break :h hasher.final();
            };

            const message = try std.fmt.allocPrint(
                allocator,
               "[CMD: SetValue] Set the value of {s} \"{?s}\" ({*}) "
               ++ "from {d} to {d}",
               .{
                   @typeName(T),
                   parameter_name,
                   parameter,
                   parameter.*,
                   newvalue,
               },
            );

            return .{
                .context = @ptrCast(ctx),
                ._do = do,
                ._undo = undo,
                ._update = update,
                ._destroy = destroy,
                .message = message,
                .command_type_destination_hash = hash,
            };
        }

        pub fn do(
            blind_ctx: *anyopaque
        ) void
        {
            const ctx: *Context = @alignCast(@ptrCast(blind_ctx));

            ctx.*.parameter.* = ctx.*.newvalue;
        }

        pub fn undo(
            blind_ctx: *anyopaque
        ) void
        {
            const ctx: *Context = @alignCast(@ptrCast(blind_ctx));

            ctx.*.parameter.* = ctx.*.oldvalue;
        }

        pub fn update(
            lhs_ctx: *anyopaque, 
            rhs_ctx: *anyopaque
        ) void
        {
            const lhs: *Context = @alignCast(@ptrCast(lhs_ctx));
            const rhs: *Context = @alignCast(@ptrCast(rhs_ctx));

            lhs.*.newvalue = rhs.*.newvalue;
        }

        pub fn destroy(
            blind_ctx: *anyopaque,
            allocator: std.mem.Allocator,
        ) void
        {
            const ctx: *Context = @alignCast(@ptrCast(blind_ctx));
            allocator.destroy(ctx);
        }
    };
}
const SetValue_f64 = SetValue(f64);
const SetValue_i32 = SetValue(i32);

test "Set Value f64"
{
    var test_parameter:f64 = 3.14;

    const cmd = try SetValue_f64.init(
        std.testing.allocator,
        &test_parameter,
        12,
        "test_parameter",
    );
    defer cmd.destroy(std.testing.allocator);

    try cmd.do();
    try std.testing.expectEqual(12, test_parameter);

    try cmd.undo();
    try std.testing.expectEqual(3.14, test_parameter);
}

test "Set Value i32"
{
    var test_parameter:i32 = 314;

    const cmd = try SetValue(@TypeOf(test_parameter)).init(
        std.testing.allocator,
        &test_parameter,
        12,
        "test_parameter",
    );
    defer cmd.destroy(std.testing.allocator);

    try cmd.do();
    try std.testing.expectEqual(12, test_parameter);

    try cmd.undo();
    try std.testing.expectEqual(314, test_parameter);
}

test "Hash Test"
{
    var test_parameter:i32 = 314;

    const cmd1 = try SetValue(@TypeOf(test_parameter)).init(
        std.testing.allocator,
        &test_parameter,
        12,
        "test_parameter",
    );
    defer cmd1.destroy(std.testing.allocator);

    try cmd1.do();

    const cmd2 = try SetValue(@TypeOf(test_parameter)).init(
        std.testing.allocator,
        &test_parameter,
        15,
        "test_parameter",
    );
    defer cmd2.destroy(std.testing.allocator);

    try std.testing.expectEqual(
        cmd1.command_type_destination_hash,
        cmd2.command_type_destination_hash
    );
}

test "Update Test"
{
    // common case in journaling - two commands have similar targets, so edit
    // the one in place and preserve the old_value

    var test_parameter:i32 = 314;

    const CMD_TYPE = SetValue(@TypeOf(test_parameter));

    var cmd1 = try SetValue(@TypeOf(test_parameter)).init(
        std.testing.allocator,
        &test_parameter,
        12,
        "test_parameter",
    );
    defer cmd1.destroy(std.testing.allocator);

    try cmd1.do();

    const cmd2 = try CMD_TYPE.init(
        std.testing.allocator,
        &test_parameter,
        15,
        "test_parameter",
    );
    defer cmd2.destroy(std.testing.allocator);

    try cmd2.do();

    try cmd1.update(std.testing.allocator, cmd2);

    try std.testing.expectEqualStrings(
        cmd2.message,
        cmd1.message,
    );

    try std.testing.expect(
        @as(*CMD_TYPE.Context, @alignCast(@ptrCast(cmd2.context))).oldvalue
        != @as(*CMD_TYPE.Context, @alignCast(@ptrCast(cmd1.context))).oldvalue
    );

    try std.testing.expectEqual(
        @as(*CMD_TYPE.Context, @alignCast(@ptrCast(cmd2.context))).newvalue,
        @as(*CMD_TYPE.Context, @alignCast(@ptrCast(cmd1.context))).newvalue,
    );
}
