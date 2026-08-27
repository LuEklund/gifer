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
clip: Clip,
clip_file: std.Io.File,
clip_map: std.Io.File.MemoryMap,
cache_dir: std.Io.Dir,

fn init(self: *System, desc: InitDescription) !void {
    const gpa = desc.gpa.*;
    const io = desc.io.*;
    const window = desc.window;
    self.gpa = gpa;
    self.io = io;
    self.cache_dir = desc.cache_dir.*;
    try self.renderer.init(gpa, io, window);
    try Editor.init(&self.editor, gpa, window);

    const record_path = "/tmp/test.mp4";
    var recording = Capture.startRecording(gpa, io, record_path) catch return;
    std.debug.print("recording... press enter to stop\n", .{});
    var buf: [8]u8 = undefined;
    _ = try std.Io.File.stdin().readStreaming(io, &.{&buf});

    const path = try recording.stop(io);
    std.debug.print("saved: {s}\n", .{path});

    const loaded = try load(gpa, io, self.cache_dir, record_path);
    self.clip = loaded.clip;
    self.clip_file = loaded.file;
    self.clip_map = loaded.map;
    self.editor.display_handle = try self.renderer.uploadTexture(null, self.editor.getFrameData(&self.clip));
}

fn deinit(self: *System) void {
    self.editor.deinit(self.gpa);
    self.clip.orderd.deinit(self.gpa);
    self.clip_map.destroy(self.io);
    self.clip_file.close(self.io);
    self.renderer.deinit();
}

fn update(self: *System, window: *Window) !void {
    try self.renderer.updateShaders(self.io);
    try self.renderer.begin(window.size, .{ .clear_color = .{ 0.0, 0.0, 0.0, 1.0 } });

    const output = try self.editor.update(window, &self.clip);
    if (output.frame_changed) {
        self.editor.display_handle = try self.renderer.uploadTexture(self.editor.display_handle, self.editor.getFrameData(&self.clip));
    }

    try self.renderer.draw(.{
        .screen_size = .{
            .height = @floatFromInt(window.size.height),
            .width = @floatFromInt(window.size.width),
        },
        .ui_vertices = output.ui_vertices,
    });
    try self.renderer.submit();

    if (output.request_export) try exportClip(self.io, &self.clip);
}

pub const Loaded = struct { clip: Clip, file: std.Io.File, map: std.Io.File.MemoryMap };
pub fn load(gpa: std.mem.Allocator, io: std.Io, cache_dir: std.Io.Dir, src_path: []const u8) !Loaded {
    const info = try probe(gpa, io, src_path);

    const file = try cache_dir.createFile(io, "clip.raw", .{ .read = true, .truncate = true });
    cache_dir.deleteFile(io, "clip.raw") catch {};

    var child = try std.process.spawn(io, .{
        .argv = &.{
            "ffmpeg",   "-v",       "error",
            "-i",       src_path,   "-f",
            "rawvideo", "-pix_fmt", "rgba",
            "pipe:1",
        },
        .stdout = .{ .file = file },
    });

    _ = try child.wait(io);
    const frame_len: usize = info.width * info.height * 4;
    const total = try file.length(io);
    if (total % frame_len != 0) return error.TruncatedStream;
    const count: usize = @intCast(total / frame_len);

    const map = try file.createMemoryMap(io, .{
        .len = @intCast(total),
        .protection = .{ .read = true, .write = false },
        .populate = false,
    });

    var ordered: std.ArrayList(u32) = try .initCapacity(gpa, count);
    for (0..count) |i| ordered.appendAssumeCapacity(@intCast(i));

    return .{
        .clip = .{
            .info = info,
            .memory = map.memory,
            .orderd = ordered,
        },
        .file = file,
        .map = map,
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

fn exportClip(io: std.Io, clip: *const Clip) !void {
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
    const frame_size = clip.frameSize();
    for (clip.orderd.items) |frame_index| {
        try writer.interface.writeAll(clip.memory[frame_index * frame_size ..][0..frame_size]);
    }
    try writer.flush();
    child.stdin.?.close(io);
    child.stdin = null;
    _ = try child.wait(io);
    std.log.debug("export end", .{});
}

//Hot reload stuff
pub const InitDescription = struct {
    gpa: *const std.mem.Allocator,
    io: *const std.Io,
    window: *Window,
    cache_dir: *const std.Io.Dir,
};

pub const Api = struct {
    systemInit: *const fn (*System, *const InitDescription) callconv(.c) bool,
    systemUpdate: *const fn (*System, *Window) callconv(.c) void,
    systemDeinit: *const fn (*System) callconv(.c) void,
};

comptime {
    _ = ffi;
}

pub const ffi = struct {
    pub export fn systemInit(system: *System, desc: *const InitDescription) bool {
        std.log.info("system init", .{});
        system.init(desc.*) catch |err| {
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
