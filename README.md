# wayland zig

[wayland](https://wayland.freedesktop.org/), packaged for the Zig build system.

## Using

First, update your `build.zig.zon`:

```
zig fetch --save git+https://github.com/allyourcodebase/wayland.git
```

Then in your `build.zig`:

```zig
const dep = b.dependency("wayland", .{ .target = target, .optimize = optimize });
exe.linkLibrary(dep.artifact("wayland-server"));
exe.linkLibrary(dep.artifact("wayland-client"));
```
