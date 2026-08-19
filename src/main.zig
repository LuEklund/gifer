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
    var capture: Capture = try .init();

    const region = Capture.selectRegion(gpa, init.io) catch return;
    std.debug.print("region: {},{} {}x{}\n", .{ region.x, region.y, region.width, region.height });

    const params = try capture.inner.negotiate(region);
    var buffer: Capture.Inner.ShmBuffer = try .create(capture.inner.shm, params);
    defer buffer.destroy();

    _ = try capture.inner.outputRegion(region, &buffer);
    try dumpPpm(init.io, buffer);

    // var renderer: Renderer = try .init(gpa, &window);
    // defer renderer.deinit();
    //
    // while (!window.should_close) {
    //     try window.poll(.{});
    //
    //     try renderer.resize(window.size);
    //
    //     const frame: Renderer.Frame = try .begin(&renderer, window.size, .{ .clear_color = .{ 1.0, 0.0, 0.0, 1.0 } });
    //
    //     try frame.end();
    //     try renderer.submit(frame);
    // }
}

fn dumpPpm(io: std.Io, buffer: Capture.Inner.ShmBuffer) !void {
    const file = try std.Io.Dir.cwd().createFile(io, "frame.ppm", .{});
    defer file.close(io);
    var write_buf: [4096]u8 = undefined;
    var file_writer = file.writer(io, &write_buf);
    const out = &file_writer.interface;

    try out.print("P6\n{d} {d}\n255\n", .{ buffer.params.width, buffer.params.height });
    for (0..buffer.params.height) |y| {
        const row = buffer.pixels[y * buffer.params.bytes_per_row ..][0 .. buffer.params.width * 4];
        for (0..buffer.params.width) |x| {
            const px = row[x * 4 ..][0..4]; // B,G,R,X
            try out.writeAll(&.{ px[2], px[1], px[0] });
        }
    }
    try out.flush();
}
