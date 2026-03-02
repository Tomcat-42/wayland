const std = @import("std");
const manifest = @import("build.zig.zon");

const version: std.SemanticVersion = .{ .major = 1, .minor = 24, .patch = 0 };

pub fn build(b: *std.Build) void {
    const target = b.standardTargetOptions(.{});
    const optimize = b.standardOptimizeOption(.{});

    const upstream = b.dependency("upstream", .{});
    const libffi_dep = b.dependency("libffi", .{ .target = target, .optimize = optimize });

    const os = target.result.os.tag;
    const is_linux = os == .linux;
    const is_bsd = os.isBSD();
    const is_freebsd = os == .freebsd;

    const options = .{
        .linkage = b.option(std.builtin.LinkMode, "linkage", "Library linkage type") orelse .static,
        .scanner = b.option(bool, "scanner", "Compile wayland-scanner") orelse true,
        .@"dtd-validation" = b.option(bool, "dtd-validation", "Validate the protocol DTD") orelse false,
        .icon_directory = b.option([]const u8, "icon-directory", "Location for cursors") orelse null,
    };

    const cc_flags = getCCFlags(b, target);
    const host_cc_flags = getCCFlags(b, b.graph.host);

    // ── Config ───────────────────────────────────────────────────────

    const config_h = b.addConfigHeader(.{ .include_path = "config.h" }, .{
        .PACKAGE = "wayland",
        .PACKAGE_VERSION = manifest.version,
        .HAVE_SYS_PRCTL_H = is_linux,
        .HAVE_SYS_PROCCTL_H = if (is_freebsd) target.result.os.isAtLeast(.freebsd, .{ .major = 10, .minor = 0, .patch = 0 }) orelse false else false,
        .HAVE_SYS_UCRED_H = is_bsd,
        .HAVE_ACCEPT4 = true,
        .HAVE_MKOSTEMP = true,
        .HAVE_POSIX_FALLOCATE = true,
        .HAVE_MEMFD_CREATE = switch (os) {
            .linux => true,
            .freebsd => target.result.os.isAtLeast(.freebsd, .{ .major = 13, .minor = 0, .patch = 0 }) orelse false,
            else => false,
        },
        .HAVE_MREMAP = is_linux or is_freebsd,
        .HAVE_STRNDUP = true,
        .HAVE_PRCTL = is_linux,
        .HAVE_XUCRED_CR_PID = false,
        .HAVE_BROKEN_MSG_CMSG_CLOEXEC = false,
    });

    // Convert false values to undef (required for #ifdef guards in the C code)
    for (config_h.values.values()) |*entry| {
        if (entry.* == .boolean and !entry.boolean) entry.* = .undef;
    }

    // connection.c and wayland-os.c use #include "../config.h" — place config.h
    // so the relative include resolves via -I path.
    const config_wf = b.addWriteFiles();
    _ = config_wf.addCopyFile(config_h.getOutputFile(), "config.h");
    const config_subdir = config_wf.addCopyFile(config_h.getOutputFile(), "config/config.h");

    const version_h = b.addConfigHeader(.{
        .style = .{ .autoconf_at = upstream.path("src/wayland-version.h.in") },
        .include_path = "wayland-version.h",
    }, .{
        .WAYLAND_VERSION_MAJOR = @as(i64, @intCast(version.major)),
        .WAYLAND_VERSION_MINOR = @as(i64, @intCast(version.minor)),
        .WAYLAND_VERSION_MICRO = @as(i64, @intCast(version.patch)),
        .WAYLAND_VERSION = manifest.version,
    });

    // ── wayland-util (shared between scanner + all libs) ─────────────

    const wayland_util = createWaylandUtil(b, target, optimize, upstream, cc_flags);
    const wayland_util_host = createWaylandUtil(b, b.graph.host, optimize, upstream, host_cc_flags);

    // ── wayland-private (connection.c + wayland-os.c) ────────────────

    const wayland_private = b.addLibrary(.{
        .linkage = .static,
        .name = "wayland-private",
        .root_module = b.createModule(.{ .target = target, .optimize = optimize, .link_libc = true }),
    });
    wayland_private.root_module.addIncludePath(config_subdir.dirname());
    wayland_private.root_module.addIncludePath(upstream.path(""));
    wayland_private.root_module.addCSourceFiles(.{
        .root = upstream.path("src"),
        .files = &.{ "connection.c", "wayland-os.c" },
        .flags = cc_flags,
    });
    wayland_private.root_module.linkLibrary(libffi_dep.artifact("ffi"));
    if (is_bsd) linkEpollShim(b, wayland_private.root_module, target, optimize);

    // ── Scanner ──────────────────────────────────────────────────────

    var scanner_host: ?*std.Build.Step.Compile = null;

    if (options.scanner) {
        const scanner = b.addExecutable(.{
            .name = "wayland-scanner",
            .root_module = b.createModule(.{ .target = b.graph.host, .optimize = optimize, .link_libc = true }),
        });
        scanner.root_module.addConfigHeader(version_h);
        scanner.root_module.addIncludePath(upstream.path(""));
        scanner.root_module.addIncludePath(upstream.path("protocol"));
        scanner.root_module.addCSourceFile(.{ .file = upstream.path("src/scanner.c"), .flags = host_cc_flags });
        scanner.root_module.linkLibrary(wayland_util_host);

        if (b.lazyDependency("libexpat", .{ .target = b.graph.host, .optimize = optimize })) |expat|
            scanner.root_module.linkLibrary(expat.artifact("expat"))
        else
            scanner.root_module.linkSystemLibrary("expat", .{});

        if (options.@"dtd-validation") {
            const embed_tool = b.addExecutable(.{
                .name = "embed",
                .root_module = b.createModule(.{ .root_source_file = b.path("tools/embed.zig"), .target = b.graph.host }),
            });
            const embed_run = b.addRunArtifact(embed_tool);
            embed_run.addArg("wayland_dtd");
            embed_run.addFileArg(upstream.path("protocol/wayland.dtd"));
            const dtd_wf = b.addWriteFiles();
            _ = dtd_wf.addCopyFile(embed_run.captureStdOut(.{}), "wayland.dtd.h");
            scanner.root_module.addIncludePath(dtd_wf.getDirectory());

            if (b.lazyDependency("libxml2", .{ .target = b.graph.host, .optimize = optimize, .minimum = true, .valid = true })) |libxml2|
                scanner.root_module.linkLibrary(libxml2.artifact("xml"))
            else
                scanner.root_module.linkSystemLibrary("libxml-2.0", .{});
            scanner.root_module.addCMacro("HAVE_LIBXML", "1");
        }

        b.installArtifact(scanner);
        scanner_host = scanner;
    }

    // ── Protocol generation ──────────────────────────────────────────

    var server_proto_h: std.Build.LazyPath = undefined;
    var server_proto_core_h: std.Build.LazyPath = undefined;
    var client_proto_h: std.Build.LazyPath = undefined;
    var client_proto_core_h: std.Build.LazyPath = undefined;
    var proto_c: std.Build.LazyPath = undefined;

    for (
        [_][]const []const u8{ &.{"server-header"}, &.{ "server-header", "-c" }, &.{"client-header"}, &.{ "client-header", "-c" }, &.{"public-code"} },
        [_][]const u8{ "wayland-server-protocol.h", "wayland-server-protocol-core.h", "wayland-client-protocol.h", "wayland-client-protocol-core.h", "wayland-protocol.c" },
        [_]*std.Build.LazyPath{ &server_proto_h, &server_proto_core_h, &client_proto_h, &client_proto_core_h, &proto_c },
    ) |scanner_args, basename, out| {
        const run = if (scanner_host) |s| b.addRunArtifact(s) else b.addSystemCommand(&.{"wayland-scanner"});
        run.addArg("-s");
        run.addArgs(scanner_args);
        run.addFileArg(upstream.path("protocol/wayland.xml"));
        out.* = run.addOutputFileArg(basename);
    }

    // ── Libraries ────────────────────────────────────────────────────

    // server
    const wayland_server = b.addLibrary(.{
        .linkage = options.linkage,
        .name = "wayland-server",
        .version = .{ .major = 0, .minor = version.minor, .patch = version.patch },
        .root_module = b.createModule(.{ .target = target, .optimize = optimize, .link_libc = true }),
    });
    wayland_server.root_module.linkLibrary(wayland_private);
    wayland_server.root_module.linkLibrary(wayland_util);
    wayland_server.root_module.addConfigHeader(version_h);
    wayland_server.root_module.addConfigHeader(config_h);
    wayland_server.root_module.addIncludePath(upstream.path("src"));
    wayland_server.root_module.addIncludePath(server_proto_core_h.dirname());
    wayland_server.root_module.addIncludePath(server_proto_h.dirname());
    wayland_server.root_module.addCSourceFile(.{ .file = proto_c, .flags = cc_flags });
    wayland_server.root_module.addCSourceFiles(.{ .root = upstream.path("src"), .files = &.{ "wayland-shm.c", "event-loop.c" }, .flags = cc_flags });
    if (is_bsd) linkEpollShim(b, wayland_server.root_module, target, optimize);
    wayland_server.root_module.linkLibrary(libffi_dep.artifact("ffi"));
    wayland_server.installHeader(server_proto_core_h, "wayland-server-protocol-core.h");
    wayland_server.installHeader(server_proto_h, "wayland-server-protocol.h");
    wayland_server.installHeader(upstream.path("src/wayland-server.h"), "wayland-server.h");
    wayland_server.installHeader(upstream.path("src/wayland-server-core.h"), "wayland-server-core.h");
    wayland_server.installLibraryHeaders(wayland_util);
    wayland_server.installConfigHeader(version_h);
    b.installArtifact(wayland_server);

    // client
    const wayland_client = b.addLibrary(.{
        .linkage = options.linkage,
        .name = "wayland-client",
        .version = .{ .major = 0, .minor = version.minor, .patch = version.patch },
        .root_module = b.createModule(.{ .target = target, .optimize = optimize, .link_libc = true }),
    });
    wayland_client.root_module.linkLibrary(wayland_private);
    wayland_client.root_module.linkLibrary(wayland_util);
    wayland_client.root_module.addConfigHeader(version_h);
    wayland_client.root_module.addConfigHeader(config_h);
    wayland_client.root_module.addIncludePath(upstream.path("src"));
    wayland_client.root_module.addIncludePath(client_proto_core_h.dirname());
    wayland_client.root_module.addIncludePath(client_proto_h.dirname());
    wayland_client.root_module.addCSourceFile(.{ .file = proto_c, .flags = cc_flags });
    wayland_client.root_module.addCSourceFile(.{ .file = upstream.path("src/wayland-client.c"), .flags = cc_flags });
    if (is_bsd) linkEpollShim(b, wayland_client.root_module, target, optimize);
    wayland_client.root_module.linkLibrary(libffi_dep.artifact("ffi"));
    wayland_client.installHeader(client_proto_core_h, "wayland-client-protocol-core.h");
    wayland_client.installHeader(client_proto_h, "wayland-client-protocol.h");
    wayland_client.installHeader(upstream.path("src/wayland-client.h"), "wayland-client.h");
    wayland_client.installHeader(upstream.path("src/wayland-client-core.h"), "wayland-client-core.h");
    wayland_client.installLibraryHeaders(wayland_util);
    wayland_client.installConfigHeader(version_h);
    b.installArtifact(wayland_client);

    // egl
    const wayland_egl = b.addLibrary(.{
        .linkage = options.linkage,
        .name = "wayland-egl",
        .version = version,
        .root_module = b.createModule(.{ .target = target, .optimize = optimize, .link_libc = true }),
    });
    wayland_egl.root_module.linkLibrary(wayland_client);
    wayland_egl.root_module.addConfigHeader(version_h);
    wayland_egl.root_module.addConfigHeader(config_h);
    wayland_egl.root_module.addIncludePath(client_proto_core_h.dirname());
    wayland_egl.root_module.addIncludePath(client_proto_h.dirname());
    wayland_egl.root_module.addCSourceFile(.{ .file = upstream.path("egl/wayland-egl.c"), .flags = cc_flags });
    inline for (.{ "egl/wayland-egl.h", "egl/wayland-egl-core.h", "egl/wayland-egl-backend.h" }) |h|
        wayland_egl.installHeader(upstream.path(h), std.fs.path.basename(h));
    b.installArtifact(wayland_egl);

    // cursor
    const wayland_cursor = b.addLibrary(.{
        .linkage = options.linkage,
        .name = "wayland-cursor",
        .version = .{ .major = 0, .minor = version.minor, .patch = version.patch },
        .root_module = b.createModule(.{ .target = target, .optimize = optimize, .link_libc = true }),
    });
    wayland_cursor.root_module.linkLibrary(wayland_client);
    wayland_cursor.root_module.addConfigHeader(version_h);
    wayland_cursor.root_module.addConfigHeader(config_h);
    wayland_cursor.root_module.addIncludePath(client_proto_core_h.dirname());
    wayland_cursor.root_module.addIncludePath(client_proto_h.dirname());
    if (options.icon_directory) |dir| wayland_cursor.root_module.addCMacro("ICONDIR", dir);
    wayland_cursor.root_module.addCSourceFiles(.{
        .root = upstream.path("cursor"),
        .files = &.{ "wayland-cursor.c", "os-compatibility.c", "xcursor.c" },
        .flags = cc_flags,
    });
    wayland_cursor.installHeader(upstream.path("cursor/wayland-cursor.h"), "wayland-cursor.h");
    b.installArtifact(wayland_cursor);

    b.addNamedLazyPath("wayland-xml", upstream.path("protocol/wayland.xml"));
    b.addNamedLazyPath("wayland.dtd", upstream.path("protocol/wayland.dtd"));
}

fn createWaylandUtil(
    b: *std.Build,
    t: std.Build.ResolvedTarget,
    optimize: std.builtin.OptimizeMode,
    upstream: *std.Build.Dependency,
    cc_flags: []const []const u8,
) *std.Build.Step.Compile {
    const lib = b.addLibrary(.{
        .linkage = .static,
        .name = "wayland-util",
        .root_module = b.createModule(.{ .target = t, .optimize = optimize, .link_libc = true }),
    });
    lib.installHeader(upstream.path("src/wayland-util.h"), "wayland-util.h");
    lib.root_module.addCSourceFile(.{ .file = upstream.path("src/wayland-util.c"), .flags = cc_flags });
    return lib;
}

fn linkEpollShim(b: *std.Build, mod: *std.Build.Module, t: std.Build.ResolvedTarget, optimize: std.builtin.OptimizeMode) void {
    if (b.lazyDependency("epoll_shim", .{ .target = t, .optimize = optimize })) |dep|
        mod.linkLibrary(dep.artifact("epoll-shim"))
    else
        mod.linkSystemLibrary("epoll-shim", .{});
}

fn getCCFlags(b: *std.Build, t: std.Build.ResolvedTarget) []const []const u8 {
    var list: std.ArrayListUnmanaged([]const u8) = .{};
    list.appendSlice(b.allocator, &.{
        "-std=c99",            "-Wno-unused-parameter",
        "-Wstrict-prototypes", "-Wmissing-prototypes",
        "-fvisibility=hidden",
    }) catch @panic("OOM");
    switch (t.result.os.tag) {
        .freebsd, .openbsd => {},
        else => list.append(b.allocator, "-D_POSIX_C_SOURCE=200809L") catch @panic("OOM"),
    }
    return list.items;
}

comptime {
    if (version.major != 1)
        @compileError("SONAME bump needed for libwayland-server, -client, -cursor");
}
