const std = @import("std");
const c = @import("c.zig");

/// Set by onWMDetected. Ideally this would be in WindowManager but I can't figure out how to
/// access it from inside the C callback onWMDetected.
var wm_detected = false;

pub const WindowManagerError = error{OtherWindowManagerDetected};

pub const WindowManager = struct {
    const Self = @This();
    const WindowHashMap = std.AutoHashMap(c.Window, c.Window);

    display: *c.Display,
    root_window: c.Window,
    /// Map client window to our frame window around said client.
    clients: WindowHashMap,

    /// Open the X Display and get root window
    pub fn init() Self {
        // Open X Display
        const display = c.XOpenDisplay(null).?;

        // Get the root window
        // NOTE: DefaultRootWindow should work here. Zig bug? This is a workaround.
        // const root_window = c.DefaultRootWindow(display);
        const root_window = c.ScreenOfDisplay(
            display,
            @intCast(usize, c.DefaultScreen(display)),
        ).*.root;

        return Self{
            .display = display,
            .root_window = root_window,
            .clients = WindowHashMap.init(std.heap.c_allocator),
        };
    }

    pub fn run(self: *Self) !void {
        // Detect other running window manager by attempting to set SubstructureRedirectMask
        _ = c.XSetErrorHandler(onWMDetected);
        _ = c.XSelectInput(
            self.display,
            self.root_window,
            c.SubstructureRedirectMask | c.SubstructureNotifyMask,
        );
        // Force X to sync so we can detect other wm.
        _ = c.XSync(self.display, 0);
        if (wm_detected) {
            return WindowManagerError.OtherWindowManagerDetected;
        }

        // Now set the real error handler
        _ = c.XSetErrorHandler(onXError);

        // Start the main event loop
        while (true) {
            var e: c.XEvent = undefined;
            _ = c.XNextEvent(self.display, &e);

            try switch (e.type) {
                c.CreateNotify => self.onCreateNotify(e.xcreatewindow),
                c.ConfigureRequest => self.onConfigureRequest(e.xconfigurerequest),
                c.MapRequest => self.onMapRequest(e.xmaprequest),
                c.ReparentNotify => self.onReparentNotify(e.xreparent),
                c.MapNotify => self.onMapNotify(e.xmap),
                c.UnmapNotify => self.onUnmapNotify(e.xunmap),
                else => {},
            };
        }
    }

    pub fn deinit(self: *Self) void {
        self.clients.deinit();
        _ = c.XCloseDisplay(self.display);
    }

    /// Triggered by client application calling XCreateWindow. Newly created windows are always
    /// invisible so there is nothing to do here.
    fn onCreateNotify(self: *Self, e: c.XCreateWindowEvent) void {}

    /// Triggered by client application calling XConfigureWindow. The client window is still
    /// invisible at this point, so the request can just be forwarded without modification
    fn onConfigureRequest(self: *Self, e: c.XConfigureRequestEvent) void {
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
        if (self.clients.getValue(e.window)) |frame| {
            _ = c.XConfigureWindow(
                self.display,
                frame,
                @truncate(c_uint, e.value_mask),
                &changes,
            );
        }
        // Pass on the configure request for the client window
        _ = c.XConfigureWindow(
            self.display,
            e.window,
            @truncate(c_uint, e.value_mask),
            &changes,
        );
    }

    /// Triggered by XMapWindow
    fn onMapRequest(self: *Self, e: c.XMapRequestEvent) !void {
        // Frame the window
        try self.frameWindow(e.window);
        // Actually map the window
        _ = c.XMapWindow(self.display, e.window);
    }

    /// Triggered by us reparenting client windows with XReparentWindow. Nothing to do here.
    fn onReparentNotify(self: *Self, e: c.XReparentEvent) void {}

    /// Triggered by us mapping frame windows with XMapWindow. Nothing to do here.
    fn onMapNotify(self: *Self, e: c.XMapEvent) void {}

    /// Triggered by a client calling XUnmapWindow. We need to unframe the client's window.
    fn onUnmapNotify(self: *Self, e: c.XUnmapEvent) void {
        if (self.clients.get(e.window)) |frame| {
            self.unFrameWindow(e.window);
        }
    }

    /// Reparent window to a frame (another window) so we can draw a border and decorations.
    fn frameWindow(self: *Self, w: c.Window) !void {
        const border_width = 3;
        const border_color = 0xff0000;
        const bg_color = 0x0000ff;

        // Retrieve attributes of window to frame
        var attrs = std.mem.zeroes(c.XWindowAttributes);
        _ = c.XGetWindowAttributes(self.display, w, &attrs);

        // check if frame already exists
        if (!self.clients.contains(w)) {
            // Create frame
            const frame = c.XCreateSimpleWindow(
                self.display,
                self.root_window,
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
                self.display,
                frame,
                c.SubstructureRedirectMask | c.SubstructureNotifyMask,
            );
            // Add client w to save set so it will be restored and kept alive if we crash
            _ = c.XAddToSaveSet(self.display, w);
            // Reparent client w to frame
            _ = c.XReparentWindow(
                self.display,
                w,
                frame,
                0, // x offset in frame
                0, // y offset in frame
            );
            // Map the frame
            _ = c.XMapWindow(self.display, frame);
            // Save frame handle
            _ = try self.clients.put(w, frame);
            // TODO: grab keys and buttons for w here
        }
    }

    /// Reverse the steps taken in frameWindow.
    fn unFrameWindow(self: *Self, w: c.Window) void {
        if (self.clients.getValue(w)) |frame| {
            _ = c.XUnmapWindow(self.display, frame);
            _ = c.XReparentWindow(
                self.display,
                w,
                self.root_window,
                0,
                0,
            );
            _ = c.XRemoveFromSaveSet(self.display, w);
            _ = c.XDestroyWindow(self.display, frame);
            _ = self.clients.remove(w);
        }
    }

    /// Xlib error handler used to determine whether another window manager is running. It is set
    /// as the error handler right before selecting substructure redirection mask on the root
    /// window, so it is invoked if and only if another window manager is running.
    fn onWMDetected(display: ?*c.Display, e: [*c]c.XErrorEvent) callconv(.C) c_int {
        wm_detected = e.*.error_code == c.BadAccess;
        return 0;
    }

    /// X error handler
    fn onXError(display: ?*c.Display, e: [*c]c.XErrorEvent) callconv(.C) c_int {
        return 0;
    }
};
