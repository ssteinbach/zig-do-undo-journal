//! Command library for an undo system

const std = @import("std");

const Hash = u64;

/// encapsulation of a state change, with a do and undo
pub const Command = struct {
    /// a context.  the provided function pointers can cast into a concrete 
    /// type and read information from in order to do or undo the command
    ///
    /// This memory is owned by the creator of the Command
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
    /// also updates the message on cmd1
    _update: *const fn (
        allocator: std.mem.Allocator,
        ctx: *anyopaque,
        new_ctx: *anyopaque
    ) error{anyerror}![]const u8,
    /// free the memory of this command
    _destroy: *const fn (ctx: *anyopaque, std.mem.Allocator) void,

    /// execute the command
    pub fn do(
        self: @This(),
    ) !void 
    {
        self._do(self.context);
    }

    /// undo the command
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
        // copy the message
        allocator.free(self.message);

        // copy the context
        self.message = try self._update(
            allocator,
            self.context,
            rhs.context,
        );
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

    /// assemble a command from another object
    ///
    /// Uses comptime reflection to pull the fields off the object and assign
    /// them to the blind pointers.
    pub fn init(
        comptime base_type: type,
        context: *anyopaque,
        message: []const u8,
        hash: Hash,
    ) Command
    {
        return .{
            .context = context,
            .message = message,
            .command_type_destination_hash = hash,

            ._do = @field(base_type, "do"),
            ._undo = @field(base_type, "undo"),
            ._update = @field(base_type, "update"),
            ._destroy = @field(base_type, "destroy"),
        };
    }
};

/// example command that produces a command for setting a value
pub fn SetValue(
    /// type of the value this command will set
    comptime T: type,
) type 
{
    return struct {
        const Context = struct {
            parameter_name: []const u8,
            parameter: *T,
            old_value: T,
            new_value: T,
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
                .parameter_name = parameter_name orelse "",
                .old_value = parameter.*,
                .new_value = newvalue,
            };

            const hash = h: {
                var hasher = std.hash.Wyhash.init(base_hash);

                std.hash.autoHash(&hasher, ctx.*.parameter);

                break :h hasher.final();
            };

            return Command.init(
                @This(),
                ctx,
                try message(
                    allocator,
                    ctx.*,
                ),
                hash,
            );
        }

        /// generate a string label for the command based on the context
        fn message(
            allocator: std.mem.Allocator,
            ctx: Context,
        ) ![]const u8
        {
            return try std.fmt.allocPrint(
                allocator,
               "[CMD: SetValue] Set the value of {s} \"{s}\" ({*}) "
               ++ "from {d} to {d}",
               .{
                   @typeName(T),
                   ctx.parameter_name,
                   ctx.parameter,
                   ctx.old_value,
                   ctx.new_value,
               },
            );
        }

        pub fn do(
            blind_ctx: *anyopaque,
        ) void
        {
            const ctx: *Context = @alignCast(@ptrCast(blind_ctx));

            ctx.*.parameter.* = ctx.*.new_value;
        }

        pub fn undo(
            blind_ctx: *anyopaque,
        ) void
        {
            const ctx: *Context = @alignCast(@ptrCast(blind_ctx));

            ctx.*.parameter.* = ctx.*.old_value;
        }

        pub fn update(
            allocator: std.mem.Allocator,
            lhs_ctx: *anyopaque, 
            rhs_ctx: *anyopaque,
        ) error{anyerror}![]const u8
        {
            const lhs: *Context = @alignCast(@ptrCast(lhs_ctx));
            const rhs: *Context = @alignCast(@ptrCast(rhs_ctx));

            lhs.*.new_value = rhs.*.new_value;

            // generate a new message
            return @errorCast(message(allocator, lhs.*));
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

test "Set Value f64"
{
    var test_parameter:f64 = 3.14;

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
        cmd2.command_type_destination_hash,
    );
}

test "Update Test"
{
    // common case in journaling - two commands have the same target, so edit
    // the one in place and preserve the old_value

    const allocator = std.testing.allocator;

    // the parameter that the commands will manipulate
    var test_parameter:i32 = 314;

    // generate the command struct
    const CMD_TYPE = SetValue(@TypeOf(test_parameter));

    var cmd1 = try CMD_TYPE.init(
        allocator,
        &test_parameter,
        12,
        "test_parameter",
    );
    defer cmd1.destroy(allocator);

    try cmd1.do();

    const cmd2 = try CMD_TYPE.init(
        std.testing.allocator,
        &test_parameter,
        15,
        "test_parameter",
    );
    defer cmd2.destroy(allocator);

    try cmd2.do();

    try cmd1.update(allocator, cmd2);

    const ctxt1 = @as(
        *CMD_TYPE.Context,
        @alignCast(@ptrCast(cmd1.context)),
    );
    const ctxt2 = @as(
        *CMD_TYPE.Context,
        @alignCast(@ptrCast(cmd2.context)),
    );

    try std.testing.expectEqualStrings(
        ctxt2.parameter_name,
        ctxt1.parameter_name,
    );

    try std.testing.expect(ctxt2.old_value != ctxt1.old_value);

    try std.testing.expectEqual(
        ctxt2.new_value,
        ctxt1.new_value,
    );
}
