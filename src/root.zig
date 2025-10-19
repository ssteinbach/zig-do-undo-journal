//! Simple journaling undo system.
//!
//! The do-undo-journal library implements a `Journal` of `Command`s, which
//! encapsulate a do/undo function along with some state context that those
//! functions use to perform their task.  
//!
//! It also supplies an example Command - `SetValue`, which takes a pointer to a
//! value and can set/unset the value the pointer is pointing at.

const command = @import("command.zig");

/// Commands that can be done or undone
pub const Command = command.Command;

/// An example command that can set/unset a value through a pointer
pub const SetValue = command.SetValue;

const journal_mod = @import("journal.zig");

/// A journal of commands which can have a specific size, have commands undone
/// or redone, etc.
pub const Journal = journal_mod.Journal;

test {
    _ = @import("command.zig");
    _ = @import("journal.zig");
}
