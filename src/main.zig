const std = @import("std");
const warn = std.debug.warn;
const panic = std.debug.panic;

const wm = @import("window_manager.zig");

pub fn main() anyerror!void {
    // Create the window manager
    var window_manager = wm.WindowManager.init();
    defer window_manager.deinit();

    // Run the main event loop
    return window_manager.run();
}
