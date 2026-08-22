const System = @This();

const std = @import("std");
const Window = @import("Window.zig");
const Renderer = @import("Renderer.zig");
const Capture = @import("Capture.zig");
const Editor = @import("Editor.zig");

gpa: std.mem.Allocator,
io: std.Io,
renderer: Renderer,
editor: Editor,
clip: Clip,
display_handle: u32,
counter: usize,

pub const Info = struct { width: u32, height: u32, fps_num: u32, fps_den: u32 };
pub const Clip = struct {
    info: Info,
    frames: std.ArrayList([]u8), // each info.width*info.height*4 bytes, RGBA
};

fn init(self: *System, gpa: std.mem.Allocator, io: std.Io, window: *Window) !void {
    self.gpa = gpa;
    self.io = io;
    try self.renderer.init(gpa, io, window);
    self.editor = try Editor.init(gpa, window);

    var recording = Capture.startRecording(gpa, io, "/tmp/test.mp4") catch return;
    std.debug.print("recording... press enter to stop\n", .{});
    var buf: [8]u8 = undefined;
    _ = try std.Io.File.stdin().readStreaming(io, &.{&buf});

    const path = try recording.stop(io);
    std.debug.print("saved: {s}\n", .{path});

    self.clip = try load(gpa, io, "/tmp/test.mp4");

    std.debug.print("{} frames, {}x{}\n", .{ self.clip.frames.items.len, self.clip.info.width, self.clip.info.height });
    self.display_handle = @intFromEnum(try self.renderer.createTexture(.{
        .height = self.clip.info.height,
        .width = self.clip.info.width,
        .data = self.clip.frames.items[0],
    }));
    self.counter = 0;
}

fn deinit(self: *System) void {
    self.editor.deinit(self.gpa);
    self.renderer.deinit();
    for (self.clip.frames.items) |frame| self.gpa.free(frame);
    self.clip.frames.deinit(self.gpa);
}

fn update(self: *System, window: *Window) !void {
    self.counter += 1;
    self.display_handle = if (self.counter % 100 == 0) @intFromEnum(try self.renderer.updateTexture(@enumFromInt(self.display_handle), .{
        .height = self.clip.info.height,
        .width = self.clip.info.width,
        .data = self.clip.frames.items[self.counter % self.clip.frames.items.len],
    })) else self.display_handle;
    try self.renderer.updateShaders(self.io);
    try self.renderer.resize(window.size);
    try self.renderer.begin(window.size, .{ .clear_color = .{ 0.0, 0.0, 0.0, 1.0 } });

    const ui_vertices = self.editor.update(window, self.display_handle);
    try self.renderer.draw(.{
        .screen_size = .{
            .height = @floatFromInt(window.size.height),
            .width = @floatFromInt(window.size.width),
        },
        .ui_vertices = ui_vertices,
    });
    try self.renderer.submit();
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

//Hot reload stuff
pub const Api = struct {
    systemInit: *const fn (*System, *const std.mem.Allocator, *const std.Io, *Window) callconv(.c) bool,
    systemUpdate: *const fn (*System, *Window) callconv(.c) void,
    systemDeinit: *const fn (*System) callconv(.c) void,
};

comptime {
    _ = ffi;
}

pub const ffi = struct {
    pub export fn systemInit(system: *System, gpa: *const std.mem.Allocator, io: *const std.Io, window: *Window) bool {
        std.log.info("system init", .{});
        system.init(gpa.*, io.*, window) catch |err| {
            logError("init", err, @errorReturnTrace());
            return false;
        };
        return true;
    }

    pub export fn systemDeinit(system: *System) void {
        std.log.info("system deinit", .{});
        system.deinit();
    }

    pub export fn systemUpdate(system: *System, window: *Window) void {
        system.update(window) catch |err| logError("update", err, @errorReturnTrace());
    }
};

fn logError(what: []const u8, err: anyerror, trace: ?*std.builtin.StackTrace) void {
    if (trace) |t| std.debug.dumpErrorReturnTrace(t);
    std.log.err("system {s}: {t}", .{ what, err });
}
