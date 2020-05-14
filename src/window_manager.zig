const std = @import("std");
const c = @import("c.zig");

/// Set by onWMDetected. Ideally this would be in WindowManager but I can't figure out how to
/// access it from inside the C callback onWMDetected.
var wm_detected = false;

/// The X display
var display: *c.Display = undefined;

/// X root window
var root_window: c.Window = undefined;

pub const WindowManagerError = error{
    OtherWindowManagerDetected,
    XDisplayNotFound,
};

var clients = std.AutoHashMap(c.Window, c.Window).init(std.heap.c_allocator);

pub fn init() !void {
    // Get X Display
    display = c.XOpenDisplay(null) orelse return WindowManagerError.XDisplayNotFound;

    // Get the root window
    // NOTE: DefaultRootWindow should work here. Zig bug? This is a workaround.
    // const root_window = c.DefaultRootWindow(display);
    root_window = c.ScreenOfDisplay(
        display,
        @intCast(usize, c.DefaultScreen(display)),
    ).*.root;
}

pub fn run() !void {
    // Detect other running window manager by attempting to set SubstructureRedirectMask
    _ = c.XSetErrorHandler(onWMDetected);
    _ = c.XSelectInput(
        display,
        root_window,
        c.SubstructureRedirectMask | c.SubstructureNotifyMask,
    );
    // Force X to sync so we can detect other wm.
    _ = c.XSync(display, 0);
    if (wm_detected) {
        return WindowManagerError.OtherWindowManagerDetected;
    }

    // Now set the real error handler
    _ = c.XSetErrorHandler(onXError);

    // Start the main event loop
    while (true) {
        var e: c.XEvent = undefined;
        _ = c.XNextEvent(display, &e);

        try switch (e.type) {
            c.CreateNotify => onCreateNotify(e.xcreatewindow),
            c.ConfigureRequest => onConfigureRequest(e.xconfigurerequest),
            c.MapRequest => onMapRequest(e.xmaprequest),
            c.ReparentNotify => onReparentNotify(e.xreparent),
            c.MapNotify => onMapNotify(e.xmap),
            c.UnmapNotify => onUnmapNotify(e.xunmap),
            c.KeyPress => onKeyPress(e.xkey),
            c.KeyRelease => onKeyRelease(e.xkey),
            else => {},
        };
    }
}

pub fn deinit() void {
    clients.deinit();
    _ = c.XCloseDisplay(display);
}

/// Triggered by client application calling XCreateWindow. Newly created windows are always
/// invisible so there is nothing to do here.
fn onCreateNotify(e: c.XCreateWindowEvent) void {}

/// Triggered by client application calling XConfigureWindow. The client window is still
/// invisible at this point, so the request can just be forwarded without modification
fn onConfigureRequest(e: c.XConfigureRequestEvent) void {
    var changes = c.XWindowChanges{
        .x = e.x,
        .y = e.y,
        .width = e.width,
        .height = e.height,
        .border_width = e.border_width,
        .sibling = e.above,
        .stack_mode = e.detail,
    };
    // Also need to configure the frame window
    if (clients.getValue(e.window)) |frame| {
        _ = c.XConfigureWindow(
            display,
            frame,
            @truncate(c_uint, e.value_mask),
            &changes,
        );
    }
    // Pass on the configure request for the client window
    _ = c.XConfigureWindow(
        display,
        e.window,
        @truncate(c_uint, e.value_mask),
        &changes,
    );
}

/// Triggered by XMapWindow
fn onMapRequest(e: c.XMapRequestEvent) !void {
    // Frame the window
    try frameWindow(e.window);
    // Actually map the window
    _ = c.XMapWindow(display, e.window);
}

/// Triggered by us reparenting client windows with XReparentWindow. Nothing to do here.
fn onReparentNotify(e: c.XReparentEvent) void {}

/// Triggered by us mapping frame windows with XMapWindow. Nothing to do here.
fn onMapNotify(e: c.XMapEvent) void {}

/// Triggered by a client calling XUnmapWindow. We need to unframe the client's window.
fn onUnmapNotify(e: c.XUnmapEvent) void {
    if (clients.get(e.window)) |frame| {
        unFrameWindow(e.window);
    }
}

/// Triggered by keypress if the key + modifiers were grabbed with XGrabKey on the window
fn onKeyPress(e: c.XKeyEvent) void {
    // TODO: should also exclude other modifiers, not just check for Mod1Mask.
    // alt+F4: close window
    if (e.state & (c.Mod1Mask) != 0 and e.keycode == c.XKeysymToKeycode(display, c.XK_F4)) {
        // Check if the window allows us to kill it nicely
        var supported_protocols: [*c]c.Atom = undefined;
        var num_supported_protocols: c_int = 0;
        _ = c.XGetWMProtocols(
            display,
            e.window,
            &supported_protocols,
            &num_supported_protocols,
        );
        var graceful = false;
        const wm_delete_window = c.XInternAtom(display, "WM_DELETE_WINDOW", 0);
        const wm_protocols = c.XInternAtom(display, "WM_PROTOCOLS", 0);
        var i: usize = 0;
        while (i < num_supported_protocols) : (i += 1) {
            if (supported_protocols[i] == wm_delete_window) {
                graceful = true;
                break;
            }
        }
        if (false) { // TODO: should be if (graceful)
            // std.debug.warn("Gracefully killing window {}\n", .{e.window});

            // TODO: can't zero XEvent. For now, falling back to killing forcefully.
            // /usr/lib/zig/std/mem.zig:359:13: error: Can't set a union__XEvent to zero.
            //             @compileError("Can't set a " ++ @typeName(T) ++ " to zero.");
            //             ^
            // ./src/window_manager.zig:161:41: note: called from here
            //                var msg = std.mem.zeroes(c.XEvent);

            // var msg = std.mem.zeroes(c.XEvent);
            // msg.xclient.type = c.ClientMessage;
            // msg.xclient.message_type = @intCast(c_ulong, wm_protocols);
            // msg.xclient.window = e.window;
            // msg.xclient.format = 32;
            // msg.xclient.data.l[0] = @intCast(c_long, wm_delete_window);
        } else {
            // std.debug.warn("Killing window {}\n", e.window);
            _ = c.XKillClient(display, e.window);
        }
    }
}

fn onKeyRelease(e: c.XKeyEvent) void {}

/// Reparent window to a frame (another window) so we can draw a border and decorations.
fn frameWindow(w: c.Window) !void {
    const border_width = 3;
    const border_color = 0xff0000;
    const bg_color = 0x0000ff;

    // Retrieve attributes of window to frame
    var attrs = std.mem.zeroes(c.XWindowAttributes);
    _ = c.XGetWindowAttributes(display, w, &attrs);

    // check if frame already exists
    if (!clients.contains(w)) {
        // Create frame
        const frame = c.XCreateSimpleWindow(
            display,
            root_window,
            attrs.x,
            attrs.y,
            @intCast(c_uint, attrs.width),
            @intCast(c_uint, attrs.height),
            border_width,
            border_color,
            bg_color,
        );
        // Select events on frame.
        _ = c.XSelectInput(
            display,
            frame,
            c.SubstructureRedirectMask | c.SubstructureNotifyMask,
        );
        // Add client w to save set so it will be restored and kept alive if we crash
        _ = c.XAddToSaveSet(display, w);
        // Reparent client w to frame
        _ = c.XReparentWindow(
            display,
            w,
            frame,
            0, // x offset in frame
            0, // y offset in frame
        );
        // Map the frame
        _ = c.XMapWindow(display, frame);
        // Save frame handle
        _ = try clients.put(w, frame);
        // Grab keys and buttons for w
        const ret = c.XGrabKey(
            display,
            c.XKeysymToKeycode(display, c.XK_F4),
            c.Mod1Mask,
            w,
            0,
            c.GrabModeAsync,
            c.GrabModeAsync,
        );
    }
}

/// Reverse the steps taken in frameWindow.
fn unFrameWindow(w: c.Window) void {
    if (clients.getValue(w)) |frame| {
        _ = c.XUnmapWindow(display, frame);
        _ = c.XReparentWindow(
            display,
            w,
            root_window,
            0,
            0,
        );
        _ = c.XRemoveFromSaveSet(display, w);
        _ = c.XDestroyWindow(display, frame);
        _ = clients.remove(w);
    }
}

/// Xlib error handler used to determine whether another window manager is running. It is set
/// as the error handler right before selecting substructure redirection mask on the root
/// window, so it is invoked if and only if another window manager is running.
fn onWMDetected(d: ?*c.Display, e: [*c]c.XErrorEvent) callconv(.C) c_int {
    wm_detected = e.*.error_code == c.BadAccess;
    return 0;
}

/// X error handler
fn onXError(d: ?*c.Display, e: [*c]c.XErrorEvent) callconv(.C) c_int {
    return 0;
}
