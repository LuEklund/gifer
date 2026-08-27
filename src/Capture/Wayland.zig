const std = @import("std");
// const Region = @import("../Capture.zig").Region;

pub const Recording = struct {
    child: std.process.Child,

    pub fn stop(self: *Recording, io: std.Io) !void {
        try std.posix.kill(self.child.id.?, std.posix.SIG.INT);
        _ = try self.child.wait(io);
    }
};

pub fn startRecording(gpa: std.mem.Allocator, io: std.Io, path: []const u8) !Recording {
    const geometry = try selectRegion(gpa, io);
    defer gpa.free(geometry);

    const child = try std.process.spawn(io, .{
        .argv = &.{ "wf-recorder", "-g", std.mem.trim(u8, geometry, "\n"), "-y", "-f", path },
    });
    return .{ .child = child };
}

pub fn stop(io: std.Io, recording: *Recording) void {
    recording.child.kill(io);
}

fn selectRegion(gpa: std.mem.Allocator, io: std.Io) ![]const u8 {
    //NOTE: replace later with overlay window?
    const result = try std.process.run(gpa, io, .{
        .argv = &.{ "slurp", "-w", "2", "-c", "#7aa2f7ff", "-b", "#00000066" },
    });
    // defer gpa.free(result.stdout);
    defer gpa.free(result.stderr);

    switch (result.term) {
        .exited => |code| if (code != 0) return error.SelectionCancelled,
        else => return error.SelectionCancelled,
    }
    return result.stdout;
    // const line = std.mem.trim(u8, result.stdout, " \n");
    // var it = std.mem.tokenizeAny(u8, line, ", x");
    // return .{
    //     .x = try std.fmt.parseInt(i32, it.next() orelse return error.BadSlurpOutputX, 10),
    //     .y = try std.fmt.parseInt(i32, it.next() orelse return error.BadSlurpOutputY, 10),
    //     .width = try std.fmt.parseInt(u32, it.next() orelse return error.BadSlurpOutputWidth, 10),
    //     .height = try std.fmt.parseInt(u32, it.next() orelse return error.BadSlurpOutputHeight, 10),
    // };
}
