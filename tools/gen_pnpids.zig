const std = @import("std");

pub fn main(init: std.process.Init) !void {
    var args = init.minimal.args.iterate();
    _ = args.skip();
    const input_path = args.next() orelse return error.MissingArgument;

    const data = try std.Io.Dir.cwd().readFileAlloc(init.io, input_path, std.heap.page_allocator, .limited(1 << 20));

    var wbuf: [8192]u8 = undefined;
    var file_writer = std.Io.File.stdout().writer(init.io, &wbuf);
    const w = &file_writer.interface;

    try w.writeAll("#include \"backend/drm/util.h\"\n\n#define PNP_ID(a, b, c) ((a & 0x1f) << 10) | ((b & 0x1f) << 5) | (c & 0x1f)\nconst char *get_pnp_manufacturer(const char code[static 3]) {\n\tswitch (PNP_ID(code[0], code[1], code[2])) {\n");

    var lines = std.mem.splitScalar(u8, data, '\n');
    while (lines.next()) |line| {
        if (line.len < 4) continue;
        if (line[3] != '\t') continue;
        const id = line[0..3];
        const vendor = std.mem.trim(u8, line[4..], &.{ ' ', '\t', '\r' });
        if (vendor.len == 0) continue;
        try w.print("\tcase PNP_ID('{c}', '{c}', '{c}'): return \"{s}\";\n", .{ id[0], id[1], id[2], vendor });
    }

    try w.writeAll("\t}\n\treturn NULL;\n}\n#undef PNP_ID\n");
    try file_writer.end();
}
