const System = @This();

const std = @import("std");
const Window = @import("Window.zig");
const Renderer = @import("Renderer.zig");
const Capture = @import("Capture.zig");
const Editor = @import("Editor.zig");
const Clip = Editor.Clip;
const Info = Editor.Clip.Info;

gpa: std.mem.Allocator,
io: std.Io,
renderer: Renderer,
editor: Editor,

//TODO: ffmpeg package for zig, queues instead fo arrays? or indecies?

fn init(self: *System, gpa: std.mem.Allocator, io: std.Io, window: *Window) !void {
    self.gpa = gpa;
    self.io = io;
    try self.renderer.init(gpa, io, window);
    try Editor.init(&self.editor, gpa, window);

    var recording = Capture.startRecording(gpa, io, "/tmp/test.mp4") catch return;
    std.debug.print("recording... press enter to stop\n", .{});
    var buf: [8]u8 = undefined;
    _ = try std.Io.File.stdin().readStreaming(io, &.{&buf});

    const path = try recording.stop(io);
    std.debug.print("saved: {s}\n", .{path});

    self.editor.clip = try load(gpa, io, "/tmp/test.mp4");

    // std.debug.print("{} frames, {}x{}\n", .{ self.clip.frames.items.len, self.clip.info.width, self.clip.info.height });
    self.editor.display_handle = try self.renderer.uploadTexture(null, self.editor.getFrameData());
}

fn deinit(self: *System) void {
    self.editor.deinit(self.gpa);
    self.renderer.deinit();
}

fn update(self: *System, window: *Window) !void {
    try self.renderer.updateShaders(self.io);
    try self.renderer.resize(window.size);
    try self.renderer.begin(window.size, .{ .clear_color = .{ 0.0, 0.0, 0.0, 1.0 } });

    const output = try self.editor.update(window);
    // std.log.debug("{d} : {d}", .{ virtual_index, self.clip.orderd.items.len });
    if (output.frame_changed) {
        self.editor.display_handle = try self.renderer.uploadTexture(self.editor.display_handle, self.editor.getFrameData());
    }

    try self.renderer.draw(.{
        .screen_size = .{
            .height = @floatFromInt(window.size.height),
            .width = @floatFromInt(window.size.width),
        },
        .ui_vertices = output.ui_vertices,
    });
    try self.renderer.submit();

    if (output.request_export) try exportClip(self.io, self.editor.clip);
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

    var ordered: std.ArrayList(u32) = try .initCapacity(gpa, frames.items.len);
    for (0..ordered.capacity) |i| ordered.appendAssumeCapacity(@intCast(i));

    return .{
        .info = info,
        .frames = frames,
        .index = 0,
        .previous_index = 0,
        .counter = 0,
        .orderd = ordered,
    };
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

fn exportClip(io: std.Io, clip: Clip) !void {
    std.log.debug("export START", .{});
    var size_buf: [256]u8 = undefined;
    const size = try std.fmt.bufPrint(&size_buf, "{d}x{d}", .{ clip.info.width, clip.info.height });
    var fps_buf: [256]u8 = undefined;
    const fps = try std.fmt.bufPrint(&fps_buf, "{d}/{d}", .{ clip.info.fps_num, clip.info.fps_den });
    var child = try std.process.spawn(io, .{
        .stdin = .pipe,
        .argv = &.{
            "ffmpeg", "-v",       "error",
            "-f",     "rawvideo", "-pix_fmt",
            "rgba",   "-s",       size,
            "-r",     fps,        "-i",
            "pipe:0", "-y",       "/tmp/out.gif",
        },
    });
    var buf: [2048]u8 = undefined;
    var writer = child.stdin.?.writer(io, &buf);
    for (clip.orderd.items) |frame_index| {
        try writer.interface.writeAll(clip.frames.items[frame_index]);
    }
    std.log.debug("export end", .{});
    child.stdin.?.close(io);
    child.stdin = null;
    std.log.debug("export end", .{});
    try writer.flush();
    std.log.debug("export end", .{});
    _ = try child.wait(io);
    std.log.debug("export end", .{});
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
