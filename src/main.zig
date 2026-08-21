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

    var system: System = undefined;
    if (!hot.api.systemInit(&system, &gpa, &init.io, &window)) return error.SystemInit;
    defer hot.api.systemDeinit(&system);

    while (!window.should_close) {
        try window.poll(.{});

        hot.trySwap(init.io);
        hot.api.systemUpdate(&system, &window);
    }
}
