const std = @import("std");
const warn = std.debug.warn;
const panic = std.debug.panic;

const wm = @import("window_manager.zig");

pub fn main() anyerror!void {
    // Create the window manager
    try wm.init();
    defer wm.deinit();

    // Run the main event loop
    return wm.run();
}
