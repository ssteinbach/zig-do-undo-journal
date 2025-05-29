//! The do-undo-journal library implements a Journal of Commands, which
//! encapsulate a do/undo function along with some state context that those
//! functions use to perform their task.  It also supplies an example Command -
//! SetValue, which takes a pointer to a value and can set/unset the value the
//! pointer is pointing at.

const command = @import("command.zig");
pub const Command = command.Command;
pub const SetValue = command.SetValue;

const journal_mod = @import("journal.zig");
pub const Journal = journal_mod.Journal;

test {
    _ = @import("command.zig");
    _ = @import("journal.zig");
}
