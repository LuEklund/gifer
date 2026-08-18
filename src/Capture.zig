const std = @import("std");

pub const Region = struct {
    x: i32,
    y: i32,
    width: u32,
    height: u32,
};

pub fn selectRegion(gpa: std.mem.Allocator, io: std.Io) !Region {
    const result = try std.process.run(gpa, io, .{
        .argv = &.{ "slurp", "-w", "2", "-c", "#7aa2f7ff", "-b", "#00000066" },
    });
    defer gpa.free(result.stdout);
    defer gpa.free(result.stderr);

    switch (result.term) {
        .exited => |code| if (code != 0) return error.SelectionCancelled,
        else => return error.SelectionCancelled,
    }
    const line = std.mem.trim(u8, result.stdout, " \n");
    var it = std.mem.tokenizeAny(u8, line, ", x");
    return .{
        .x = try std.fmt.parseInt(i32, it.next() orelse return error.BadSlurpOutputX, 10),
        .y = try std.fmt.parseInt(i32, it.next() orelse return error.BadSlurpOutputY, 10),
        .width = try std.fmt.parseInt(u32, it.next() orelse return error.BadSlurpOutputWidth, 10),
        .height = try std.fmt.parseInt(u32, it.next() orelse return error.BadSlurpOutputHeight, 10),
    };
}
