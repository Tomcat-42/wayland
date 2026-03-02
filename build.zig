const std = @import("std");
const path = std.fs.path;
const LinkMode = std.builtin.LinkMode;
const Module = std.Build.Module;
const Compile = std.Build.Step.Compile;
const LazyPath = std.Build.LazyPath;

const manifest = @import("build.zig.zon");

pub fn build(b: *std.Build) !void {
    const target = b.standardTargetOptions(.{});
    const optimize = b.standardOptimizeOption(.{});
    const os = target.result.os.tag;

    const options = .{
        .linkage = b.option(LinkMode, "linkage", "Library linkage type") orelse
            .static,
        .scanner = b.option(bool, "scanner", "Compile wayland-scanner") orelse
            true,
        .@"dtd-validation" = b.option(bool, "dtd-validation", "Validate the protocol DTD") orelse
            false,
        .icon_directory = b.option([]const u8, "icon-directory", "Location for cursors") orelse
            null,
    };

    const pkgs = .{
        .libffi = if (!b.systemIntegrationOption("libffi", .{}))
            b.lazyDependency("libffi", .{ .target = target, .optimize = optimize })
        else
            null,
        .libexpat = if (options.scanner and !b.systemIntegrationOption("libexpat", .{}))
            b.lazyDependency("libexpat", .{ .target = b.graph.host, .optimize = optimize })
        else
            null,
        .libxml2 = if (options.scanner and options.@"dtd-validation" and !b.systemIntegrationOption("libxml2", .{}))
            b.lazyDependency("libxml2", .{ .target = b.graph.host, .optimize = optimize, .minimum = true, .valid = true })
        else
            null,
        .epoll_shim = if (os.isBSD() and !b.systemIntegrationOption("epoll_shim", .{}))
            b.lazyDependency("epoll_shim", .{ .target = target, .optimize = optimize })
        else
            null,
    };

    const upstream = b.dependency("wayland_c", .{});
    const version: std.SemanticVersion = try .parse(manifest.version);
    const soversion: std.SemanticVersion = .{ .major = version.major -| 1, .minor = version.minor, .patch = 0 };

    const flags, const host_flags = flags: {
        const base: []const []const u8 = &.{
            "-std=c99",
            "-Wno-unused-parameter",
            "-Wstrict-prototypes",
            "-Wmissing-prototypes",
            "-fvisibility=hidden",
        };

        const posix: []const []const u8 = &.{"-D_POSIX_C_SOURCE=200809L"};

        break :flags .{
            if (os.isBSD()) base else base ++ posix,
            if (b.graph.host.result.os.tag.isBSD()) base else base ++ posix,
        };
    };

    const config_h = b.addConfigHeader(.{ .include_path = "config.h" }, .{
        .PACKAGE = "wayland",
        .PACKAGE_VERSION = manifest.version,
        .HAVE_SYS_PRCTL_H = opt(os == .linux),
        .HAVE_SYS_PROCCTL_H = opt(
            if (os == .freebsd)
                target.result.os.isAtLeast(.freebsd, .{
                    .major = 10,
                    .minor = 0,
                    .patch = 0,
                }) orelse false
            else
                false,
        ),
        .HAVE_SYS_UCRED_H = opt(os.isBSD()),
        .HAVE_ACCEPT4 = true,
        .HAVE_MKOSTEMP = opt(
            if (target.result.isMuslLibC())
                true
            else if (target.result.isGnuLibC())
                target.result.os.version_range.linux.glibc.order(.{
                    .major = 2,
                    .minor = 7,
                    .patch = 0,
                }) != .lt
            else
                true,
        ),
        .HAVE_POSIX_FALLOCATE = opt(os != .openbsd),
        .HAVE_MEMFD_CREATE = opt(switch (os) {
            .linux => if (target.result.isMuslLibC())
                true
            else if (target.result.isGnuLibC())
                target.result.os.version_range.linux.glibc.order(.{
                    .major = 2,
                    .minor = 27,
                    .patch = 0,
                }) != .lt
            else
                true,
            .freebsd => target.result.os.isAtLeast(.freebsd, .{
                .major = 13,
                .minor = 0,
                .patch = 0,
            }) orelse false,
            else => false,
        }),
        .HAVE_MREMAP = opt(os == .linux or os == .freebsd),
        .HAVE_STRNDUP = true,
        .HAVE_PRCTL = opt(os == .linux),
    });

    const version_h = b.addConfigHeader(.{
        .style = .{ .autoconf_at = upstream.path("src/wayland-version.h.in") },
        .include_path = "wayland-version.h",
    }, .{
        .WAYLAND_VERSION_MAJOR = @as(i64, @intCast(version.major)),
        .WAYLAND_VERSION_MINOR = @as(i64, @intCast(version.minor)),
        .WAYLAND_VERSION_MICRO = @as(i64, @intCast(version.patch)),
        .WAYLAND_VERSION = manifest.version,
    });

    // wayland-util (target + host)
    const wayland_util = b.addLibrary(.{
        .linkage = .static,
        .name = "wayland-util",
        .root_module = b.createModule(.{
            .target = target,
            .optimize = optimize,
            .link_libc = true,
        }),
    });
    const wayland_util_host = b.addLibrary(.{
        .linkage = .static,
        .name = "wayland-util",
        .root_module = b.createModule(.{
            .target = b.graph.host,
            .optimize = optimize,
            .link_libc = true,
        }),
    });
    for ([_]struct { *Compile, []const []const u8 }{
        .{ wayland_util, flags },
        .{ wayland_util_host, host_flags },
    }) |lib_flags| {
        const lib, const f = lib_flags;
        lib.installHeader(upstream.path("src/wayland-util.h"), "wayland-util.h");
        lib.root_module.addCSourceFile(.{ .file = upstream.path("src/wayland-util.c"), .flags = f });
    }

    // Upstream sources use `#include "../config.h"`, so config.h must be in a parent
    // directory relative to the include path. Place it at both `config.h` and `config/config.h`
    // so that `config/` can be added as an include path making `../config.h` resolve.
    const config_wf = b.addWriteFiles();
    _ = config_wf.addCopyFile(config_h.getOutputFile(), "config.h");
    const config_subdir = config_wf.addCopyFile(config_h.getOutputFile(), "config/config.h");

    // wayland-private
    const wayland_private = b.addLibrary(.{
        .linkage = .static,
        .name = "wayland-private",
        .root_module = b.createModule(.{
            .target = target,
            .optimize = optimize,
            .link_libc = true,
        }),
    });
    wayland_private.root_module.addIncludePath(config_subdir.dirname());
    wayland_private.root_module.addIncludePath(upstream.path(""));
    wayland_private.root_module.addCSourceFiles(.{
        .root = upstream.path("src"),
        .files = &.{ "connection.c", "wayland-os.c" },
        .flags = flags,
    });

    // wayland-scanner
    const scanner_host: ?*Compile = if (options.scanner) scanner: {
        const s = b.addExecutable(.{
            .name = "wayland-scanner",
            .root_module = b.createModule(.{
                .target = b.graph.host,
                .optimize = optimize,
                .link_libc = true,
            }),
        });
        s.root_module.addConfigHeader(version_h);
        s.root_module.addIncludePath(upstream.path(""));
        s.root_module.addIncludePath(upstream.path("protocol"));
        s.root_module.addCSourceFile(.{ .file = upstream.path("src/scanner.c"), .flags = host_flags });
        s.root_module.linkLibrary(wayland_util_host);
        if (pkgs.libexpat) |expat|
            s.root_module.linkLibrary(expat.artifact("expat"))
        else
            s.root_module.linkSystemLibrary("expat", .{});
        if (options.@"dtd-validation") {
            const embed = b.addRunArtifact(b.addExecutable(.{
                .name = "embed",
                .root_module = b.createModule(.{
                    .root_source_file = b.path("tools/embed.zig"),
                    .target = b.graph.host,
                }),
            }));
            embed.addArg("wayland_dtd");
            embed.addFileArg(upstream.path("protocol/wayland.dtd"));
            const dtd_wf = b.addWriteFiles();
            _ = dtd_wf.addCopyFile(embed.captureStdOut(.{}), "wayland.dtd.h");
            s.root_module.addIncludePath(dtd_wf.getDirectory());
            if (pkgs.libxml2) |xml2|
                s.root_module.linkLibrary(xml2.artifact("xml"))
            else
                s.root_module.linkSystemLibrary("libxml-2.0", .{});
            s.root_module.addCMacro("HAVE_LIBXML", "1");
        }
        b.installArtifact(s);
        break :scanner s;
    } else null;

    // Protocol generation
    const xml = upstream.path("protocol/wayland.xml");
    const server_h = scan(b, scanner_host, xml, &.{"server-header"}, "wayland-server-protocol.h");
    const server_core_h = scan(b, scanner_host, xml, &.{ "server-header", "-c" }, "wayland-server-protocol-core.h");
    const client_h = scan(b, scanner_host, xml, &.{"client-header"}, "wayland-client-protocol.h");
    const client_core_h = scan(b, scanner_host, xml, &.{ "client-header", "-c" }, "wayland-client-protocol-core.h");
    const proto_c = scan(b, scanner_host, xml, &.{"public-code"}, "wayland-protocol.c");

    // Public libraries
    const server = b.addLibrary(.{
        .linkage = options.linkage,
        .name = "wayland-server",
        .version = soversion,
        .root_module = b.createModule(.{
            .target = target,
            .optimize = optimize,
            .link_libc = true,
        }),
    });
    const client = b.addLibrary(.{
        .linkage = options.linkage,
        .name = "wayland-client",
        .version = soversion,
        .root_module = b.createModule(.{
            .target = target,
            .optimize = optimize,
            .link_libc = true,
        }),
    });
    const egl = b.addLibrary(.{
        .linkage = options.linkage,
        .name = "wayland-egl",
        .version = version,
        .root_module = b.createModule(.{
            .target = target,
            .optimize = optimize,
            .link_libc = true,
        }),
    });
    const cursor = b.addLibrary(.{
        .linkage = options.linkage,
        .name = "wayland-cursor",
        .version = soversion,
        .root_module = b.createModule(.{
            .target = target,
            .optimize = optimize,
            .link_libc = true,
        }),
    });

    // Common includes for all public libraries
    for ([_]*Compile{ server, client, egl, cursor }) |lib| {
        lib.root_module.addConfigHeader(version_h);
        lib.root_module.addConfigHeader(config_h);
        lib.root_module.addIncludePath(upstream.path("src"));
    }

    // Server/client use server-side proto headers; egl/cursor use client-side
    for ([_]*Compile{server}) |lib| {
        lib.root_module.addIncludePath(server_core_h.dirname());
        lib.root_module.addIncludePath(server_h.dirname());
    }
    for ([_]*Compile{ client, egl, cursor }) |lib| {
        lib.root_module.addIncludePath(client_core_h.dirname());
        lib.root_module.addIncludePath(client_h.dirname());
    }

    // Common deps (libffi, rt, epoll-shim)
    for ([_]*Module{ wayland_private.root_module, server.root_module, client.root_module }) |mod| {
        if (pkgs.libffi) |dep|
            mod.linkLibrary(dep.artifact("ffi"))
        else
            mod.linkSystemLibrary("libffi", .{});

        if (os == .linux or os == .freebsd) mod.linkSystemLibrary("rt", .{});

        if (os.isBSD()) {
            if (pkgs.epoll_shim) |dep|
                mod.linkLibrary(dep.artifact("epoll-shim"))
            else
                mod.linkSystemLibrary("epoll-shim", .{});
        }
    }

    // wayland-server
    server.root_module.linkLibrary(wayland_private);
    server.root_module.linkLibrary(wayland_util);
    server.root_module.addCSourceFile(.{ .file = proto_c, .flags = flags });
    server.root_module.addCSourceFiles(.{
        .root = upstream.path("src"),
        .files = &.{ "wayland-shm.c", "event-loop.c" },
        .flags = flags,
    });
    server.installHeader(server_core_h, "wayland-server-protocol-core.h");
    server.installHeader(server_h, "wayland-server-protocol.h");
    inline for (.{ "src/wayland-server.h", "src/wayland-server-core.h" }) |h|
        server.installHeader(upstream.path(h), path.basename(h));
    server.installLibraryHeaders(wayland_util);
    server.installConfigHeader(version_h);
    b.installArtifact(server);

    // wayland-client
    client.root_module.linkLibrary(wayland_private);
    client.root_module.linkLibrary(wayland_util);
    client.root_module.addCSourceFile(.{ .file = proto_c, .flags = flags });
    client.root_module.addCSourceFile(.{
        .file = upstream.path("src/wayland-client.c"),
        .flags = flags,
    });
    client.installHeader(client_core_h, "wayland-client-protocol-core.h");
    client.installHeader(client_h, "wayland-client-protocol.h");
    inline for (.{ "src/wayland-client.h", "src/wayland-client-core.h" }) |h|
        client.installHeader(upstream.path(h), path.basename(h));
    client.installLibraryHeaders(wayland_util);
    client.installConfigHeader(version_h);
    b.installArtifact(client);

    // wayland-egl
    egl.root_module.linkLibrary(client);
    egl.root_module.addCSourceFile(.{
        .file = upstream.path("egl/wayland-egl.c"),
        .flags = flags,
    });
    inline for (.{ "egl/wayland-egl.h", "egl/wayland-egl-core.h", "egl/wayland-egl-backend.h" }) |h|
        egl.installHeader(upstream.path(h), path.basename(h));
    b.installArtifact(egl);

    // wayland-cursor
    cursor.root_module.linkLibrary(client);
    if (options.icon_directory) |dir| cursor.root_module.addCMacro("ICONDIR", dir);
    cursor.root_module.addCSourceFiles(.{
        .root = upstream.path("cursor"),
        .files = &.{ "wayland-cursor.c", "os-compatibility.c", "xcursor.c" },
        .flags = flags,
    });
    cursor.installHeader(upstream.path("cursor/wayland-cursor.h"), "wayland-cursor.h");
    b.installArtifact(cursor);

    b.addNamedLazyPath("wayland-xml", upstream.path("protocol/wayland.xml"));
    b.addNamedLazyPath("wayland.dtd", upstream.path("protocol/wayland.dtd"));
}

inline fn opt(v: bool) ?bool {
    return if (v) true else null;
}

fn scan(b_: *std.Build, sc: ?*Compile, xml: LazyPath, args: []const []const u8, name: []const u8) LazyPath {
    const run = if (sc) |s| b_.addRunArtifact(s) else b_.addSystemCommand(&.{"wayland-scanner"});
    run.addArg("-s");
    run.addArgs(args);
    run.addFileArg(xml);
    return run.addOutputFileArg(name);
}
