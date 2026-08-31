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
decode: std.process.Child,
frames_decoded: usize,
display: ?Renderer.TextureHandle,
thumbnails: [Editor.frame_quad_budget]?Renderer.TextureHandle,
thumbnail_indecis: [Editor.frame_quad_budget]Editor.Clip.FrameId,
cache_dir: std.Io.Dir,

fn init(self: *System, desc: InitDescription) !void {
    const gpa = desc.gpa.*;
    const io = desc.io.*;
    const window = desc.window;
    const cache_dir = desc.cache_dir.*;

    const record_path = "/tmp/test.mp4";
    var recording = try Capture.startRecording(gpa, io, record_path);
    std.debug.print("recording... press enter to stop\n", .{});
    var buf: [8]u8 = undefined;
    _ = try std.Io.File.stdin().readStreaming(io, &.{&buf});

    try recording.stop(io);
    std.debug.print("saved: {s}\n", .{record_path});

    const info = try probe(gpa, io, record_path);

    const clip_file = try cache_dir.createFile(io, "clip.raw", .{ .read = true, .truncate = true });
    cache_dir.deleteFile(io, "clip.raw") catch {};

    const decode = try startDecode(io, clip_file, record_path);

    const clip_map = try clip_file.createMemoryMap(io, .{
        .len = @as(usize, info.frame_count) * info.width * info.height * 4,
        .protection = .{ .read = true, .write = false },
        .populate = false,
    });

    self.* = .{
        .gpa = gpa,
        .io = io,
        .renderer = undefined,
        .editor = undefined,
        .clip = .{
            .info = info,
            .memory = clip_map.memory,
            .orderd = try .initCapacity(gpa, info.frame_count),
        },
        .clip_file = clip_file,
        .clip_map = clip_map,
        .decode = decode,
        .frames_decoded = 0,
        .display = null,
        .cache_dir = cache_dir,
        .thumbnails = @splat(null),
        .thumbnail_indecis = @splat(.invalid),
    };
    try self.renderer.init(gpa, io, window);
    try self.editor.init(gpa, window);
}

fn deinit(self: *System) void {
    self.editor.deinit(self.gpa);
    self.clip.orderd.deinit(self.gpa);
    self.clip_map.destroy(self.io);
    self.clip_file.close(self.io);
    self.renderer.deinit();
}

fn update(self: *System, window: *Window) !void {
    const ready: usize = @intCast(try self.clip_file.length(self.io) / self.clip.frameSize());
    const capped = @min(ready, self.clip.info.frame_count);
    while (self.frames_decoded < capped) : (self.frames_decoded += 1)
        self.clip.orderd.appendAssumeCapacity(@enumFromInt(self.frames_decoded));

    try self.renderer.updateShaders(self.io);
    try self.renderer.begin(window.size, .{ .clear_color = .{ 0.0, 0.0, 0.0, 1.0 } });

    const output = try self.editor.update(
        window,
        .{
            .clip = &self.clip,
            .display = self.display orelse .blank,
            .thumbnails = &self.thumbnails,
        },
    );
    if (output.frame_changed) {
        self.display = try self.renderer.uploadTexture(self.display, self.clip.frameData(output.display_index));
    }
    for (output.request_thumbnail_indecis, 0..) |requested, i| {
        if (self.thumbnail_indecis[i] == requested) continue;
        self.thumbnails[i] = try self.renderer.uploadTexture(self.thumbnails[i], self.clip.frameData(requested));
        self.thumbnail_indecis[i] = requested;
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
    // window.should_close = true;
}

fn startDecode(io: std.Io, file: std.Io.File, src_path: []const u8) !std.process.Child {
    return std.process.spawn(io, .{
        .argv = &.{
            "ffmpeg",   "-v",       "error",
            "-i",       src_path,   "-f",
            "rawvideo", "-pix_fmt", "rgba",
            "pipe:1",
        },
        .stdout = .{ .file = file },
    });
}

fn probe(gpa: std.mem.Allocator, io: std.Io, path: []const u8) !Info {
    const result = try std.process.run(gpa, io, .{
        .argv = &.{
            "ffprobe",                                    "-v",  "error",
            "-select_streams",                            "v:0", "-show_entries",
            "stream=width,height,r_frame_rate,nb_frames", "-of", "csv=p=0",
            path,
        },
    });
    defer gpa.free(result.stdout);
    defer gpa.free(result.stderr);
    var it = std.mem.tokenizeAny(u8, std.mem.trim(u8, result.stdout, "\n"), ",/");
    return .{
        .width = try std.fmt.parseInt(u32, it.next() orelse return error.BadProbeWidth, 10),
        .height = try std.fmt.parseInt(u32, it.next() orelse return error.BadProbeHeight, 10),
        .fps_num = try std.fmt.parseInt(u32, it.next() orelse return error.BadProbeFpsNum, 10),
        .fps_den = try std.fmt.parseInt(u32, it.next() orelse return error.BadProbeFpsDen, 10),
        .frame_count = try std.fmt.parseInt(u32, it.next() orelse return error.BadProbeFrameCount, 10),
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
    for (clip.orderd.items) |frame_id| {
        try writer.interface.writeAll(clip.frameData(frame_id).bytes);
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
