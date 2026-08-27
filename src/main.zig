const std = @import("std");

const Window = @import("Window.zig");
const System = @import("System.zig");
const HotLib = @import("HotLib.zig").HotLib;

pub fn main(init: std.process.Init) !void {
    const gpa = init.gpa;

    var window: Window = undefined;
    try window.open(gpa, init.minimal, .{
        .title = "Gifer",
        .app_id = "gifer",
        .size = .{ .width = 700, .height = 500 },
    });
    defer window.close();

    var hot: HotLib(System.Api) = try .init("system", gpa, init.io);
    defer hot.deinit(init.io);

    var buf_cache: [std.fs.max_path_bytes]u8 = undefined;
    const cache_path = if (init.environ_map.get("XDG_CACHE_HOME")) |xdg_cache|
        try std.fmt.bufPrint(&buf_cache, "{s}/gifer", .{xdg_cache})
    else if (init.environ_map.get("HOME")) |home|
        try std.fmt.bufPrint(&buf_cache, "{s}/.cache/gifer", .{home})
    else
        return error.NoHome;
    const cache_dir = try std.Io.Dir.cwd().createDirPathOpen(init.io, cache_path, .{});

    var system: System = undefined;
    const desc: System.InitDescription = .{
        .gpa = &gpa,
        .io = &init.io,
        .window = &window,
        .cache_dir = &cache_dir,
    };
    if (!hot.api.systemInit(&system, &desc)) return error.SystemInit;
    defer hot.api.systemDeinit(&system);

    while (!window.should_close) {
        try window.poll(.{});

        hot.trySwap(init.io);
        hot.api.systemUpdate(&system, &window);
    }
}
