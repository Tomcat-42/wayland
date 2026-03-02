const std = @import("std");

pub fn main(init: std.process.Init) !void {
    var args = init.minimal.args.iterate();
    _ = args.skip();

    const var_name = args.next() orelse return error.MissingArgument;
    const input_path = args.next() orelse return error.MissingArgument;

    const data = try std.Io.Dir.cwd().readFileAlloc(init.io, input_path, std.heap.page_allocator, .limited(1 << 20));

    var wbuf: [8192]u8 = undefined;
    var file_writer = std.Io.File.stdout().writer(init.io, &wbuf);
    const w = &file_writer.interface;

    try w.print("static const char {s}[] = {{\n", .{var_name});
    for (data) |byte| try w.print("\t0x{x:0>2},\n", .{byte});
    try w.writeAll("\t0x00,\n};\n");
    try file_writer.end();
}
