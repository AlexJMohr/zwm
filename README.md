# ZWM

An Xlib (for now) window manager written in Zig.

### Dependencies

 * Xlib
 * Zig 0.6.0
 * Xephyr (recommended for testing)

### Build and run

Use Xephyr to run a testing display server on `:1`. Check out `xephyr.sh` for that.
Then run ZWM on `DISPLAY=:1`. and run some X programs.

NOTE: if running under Xephyr, turn numlock off or XGrabKey won't grab.

Example:

```
$ ./xephyr.sh &
$ DISPLAY=:1 zig build run &
$ DISPLAY=:1 xeyes
```

