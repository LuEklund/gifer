const std = @import("std");
const Capture = @import("Capture.zig");
const Window = @import("Window.zig");
const Renderer = @import("Renderer.zig");

pub fn main(init: std.process.Init) !void {
    const gpa = init.gpa;

    var window: Window = undefined;
    try window.open(gpa, init.minimal, .{
        .title = "Gifer",
        .app_id = "gifer",
        .size = .{ .width = 700, .height = 500 },
    });
    defer window.close();

    //NOTE: Prototype capture depends on windows to load in libwayland .so
    const capture: Capture = try .init();
    _ = capture;

    const region = Capture.selectRegion(gpa, init.io) catch return;
    std.debug.print("region: {},{} {}x{}\n", .{ region.x, region.y, region.width, region.height });

    var renderer: Renderer = try .init(gpa, &window);
    defer renderer.deinit();

    while (!window.should_close) {
        try window.poll(.{});

        try renderer.resize(window.size);

        const frame: Renderer.Frame = try .begin(&renderer, window.size, .{ .clear_color = .{ 1.0, 0.0, 0.0, 1.0 } });

        try frame.end();
        try renderer.submit(frame);
    }
}
