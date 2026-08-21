const System = @This();

const std = @import("std");
const Window = @import("Window.zig");
const Renderer = @import("Renderer.zig");
const Editor = @import("Editor.zig");

gpa: std.mem.Allocator,
io: std.Io,
renderer: Renderer,
editor: Editor,

fn init(self: *System, gpa: std.mem.Allocator, io: std.Io, window: *Window) !void {
    self.gpa = gpa;
    self.io = io;
    try self.renderer.init(gpa, io, window);
    self.editor = try Editor.init(gpa, window);
}

fn deinit(self: *System) void {
    self.editor.deinit(self.gpa);
    self.renderer.deinit();
}

fn update(self: *System, window: *Window) !void {
    try self.renderer.updateShaders(self.io);
    try self.renderer.resize(window.size);
    try self.renderer.begin(window.size, .{ .clear_color = .{ 0.0, 0.0, 0.0, 1.0 } });

    const vertices = self.editor.update(window);

    try self.renderer.draw(vertices);
    try self.renderer.submit();
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
