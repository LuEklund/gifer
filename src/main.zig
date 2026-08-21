const std = @import("std");
const Capture = @import("Capture.zig");
const Window = @import("Window.zig");
const System = @import("System.zig");
const HotLib = @import("HotLib.zig").HotLib;

pub const Info = struct { width: u32, height: u32, fps_num: u32, fps_den: u32 };

pub const Clip = struct {
    info: Info,
    frames: std.ArrayList([]u8), // each info.width*info.height*4 bytes, RGBA
};

pub fn main(init: std.process.Init) !void {
    const gpa = init.gpa;

    // var recording = Capture.startRecording(gpa, init.io, "/tmp/test.mp4") catch return;
    // std.debug.print("recording... press enter to stop\n", .{});
    // var buf: [8]u8 = undefined;
    // _ = try std.Io.File.stdin().readStreaming(init.io, &.{&buf});
    //
    // const path = try recording.stop(init.io);
    // std.debug.print("saved: {s}\n", .{path});
    //
    // var clip = try load(gpa, init.io, "/tmp/test.mp4");
    // defer {
    //     for (clip.frames.items) |frame| gpa.free(frame);
    //     clip.frames.deinit(gpa);
    // }
    // std.debug.print("{} frames, {}x{}\n", .{ clip.frames.items.len, clip.info.width, clip.info.height });
    //
    var window: Window = undefined;
    try window.open(gpa, init.minimal, .{
        .title = "Gifer",
        .app_id = "gifer",
        .size = .{ .width = 700, .height = 500 },
    });
    defer window.close();

    var hot: HotLib(System.Api) = try .init("system", gpa, init.io);
    defer hot.deinit(init.io);

    var system: System = undefined;
    if (!hot.api.systemInit(&system, &gpa, &init.io, &window)) return error.SystemInit;
    defer hot.api.systemDeinit(&system);

    while (!window.should_close) {
        try window.poll(.{});

        hot.trySwap(init.io);
        hot.api.systemUpdate(&system, &window);
    }
}

pub fn load(gpa: std.mem.Allocator, io: std.Io, path: []const u8) !Clip {
    const info = try probe(gpa, io, path);

    var child = try std.process.spawn(io, .{
        .argv = &.{
            "ffmpeg",   "-v",       "error",
            "-i",       path,       "-f",
            "rawvideo", "-pix_fmt", "rgba",
            "pipe:1",
        },
        .stdout = .pipe,
    });

    const frame_len = info.width * info.height * 4;
    var read_buf: [64 * 1024]u8 = undefined;
    var reader = child.stdout.?.reader(io, &read_buf);

    var frames: std.ArrayList([]u8) = .empty;
    while (true) {
        const frame = try gpa.alloc(u8, frame_len);
        const n = try reader.interface.readSliceShort(frame);
        if (n == frame_len) {
            try frames.append(gpa, frame);
            continue;
        }
        gpa.free(frame);
        if (n != 0) return error.TruncatedStream;
        break;
    }
    _ = try child.wait(io);

    return .{ .info = info, .frames = frames };
}

fn probe(gpa: std.mem.Allocator, io: std.Io, path: []const u8) !Info {
    const result = try std.process.run(gpa, io, .{
        .argv = &.{
            "ffprobe",                          "-v",  "error",
            "-select_streams",                  "v:0", "-show_entries",
            "stream=width,height,r_frame_rate", "-of", "csv=p=0",
            path,
        },
    });
    defer gpa.free(result.stdout);
    defer gpa.free(result.stderr);
    var it = std.mem.tokenizeAny(u8, std.mem.trim(u8, result.stdout, "\n"), ",/");
    return .{
        .width = try std.fmt.parseInt(u32, it.next() orelse return error.BadProbe, 10),
        .height = try std.fmt.parseInt(u32, it.next() orelse return error.BadProbe, 10),
        .fps_num = try std.fmt.parseInt(u32, it.next() orelse return error.BadProbe, 10),
        .fps_den = try std.fmt.parseInt(u32, it.next() orelse return error.BadProbe, 10),
    };
}
