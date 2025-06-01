# Do/Undo Journal

## Overview

A simple do/undo journal implementation in zig.

## How To Use

Add to your `build.zig.zon`:

```zsh
zig fetch --save "git+https://github.com/ssteinbach/zig-do-undo-journal.git"
```

Add to your `build.zig`:

```zig
    // in your buind function...
    const dep_undo_journal = b.dependency(
        "zig_do_undo_journal",
        .{
            .target = target,
            .optimize = optimize,
        },
    );

    // ...add the import
    my_module.addImport(
        "undo",
        dep_undo_journal.module("do_undo_journal")
    );
```

Then use in your code:

```zig
// initialize the journal
var journal = try Journal.init(
    allocator,
    // maximum number of entries in the journal
    500, 
);
defer journal.deinit();

var value: i32 = 12;

// add a command
const cmd = try command.SetValue(@TypeOf(value)).init(
    allocator,
    &value,
    // new value
    128,
    // property name
    "value",
);
// apply it
try cmd.do();
// value is now 128

// add it to the journal
try journal.update_if_new_or_add(cmd);

// undo it
try journal.undo();

// redo
try journal.redo();
```

## Example Usage

See [https://github.com/ssteinbach/zgui_cimgui_implot_sokol/blob/56185abc902ae56dd3389e502a1e571574c7473d/src/app_wrapper_demo.zig#L74](https://github.com/ssteinbach/zgui_cimgui_implot_sokol/blob/56185abc902ae56dd3389e502a1e571574c7473d/src/app_wrapper_demo.zig#L74)
