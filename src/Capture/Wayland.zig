const Wayland = @This();

const std = @import("std");
const Region = @import("../Capture.zig").Region;
const wayland = @import("wayland");
const wl = wayland.client.wl;
const zwlr = wayland.client.zwlr;

display: *wl.Display,
manager: *zwlr.ScreencopyManagerV1,
shm: *wl.Shm,
output: *wl.Output,

pub fn init() !Wayland {
    const display = try wl.Display.connect(null);
    errdefer display.disconnect();

    const registry = try display.getRegistry();
    defer registry.destroy;

    var data: RegistryData = .{};
    registry.setListener(*RegistryData, RegistryData.listener, &data);
    if (display.roundtrip() != .SUCCESS) return error.Roundtrip;

    return .{
        .display = display,
        .manager = data.zwlr_screencopy_manager orelse return error.NoScreencopy,
        .shm = data.shm orelse return error.NoShm,
        .output = data.output orelse return error.NoOutput,
    };
}

pub fn selectRegion(gpa: std.mem.Allocator, io: std.Io) !Region {
    const result = try std.process.run(gpa, io, .{
        .argv = &.{ "slurp", "-w", "2", "-c", "#7aa2f7ff", "-b", "#00000066" },
    });
    defer gpa.free(result.stdout);
    defer gpa.free(result.stderr);

    switch (result.term) {
        .exited => |code| if (code != 0) return error.SelectionCancelled,
        else => return error.SelectionCancelled,
    }
    const line = std.mem.trim(u8, result.stdout, " \n");
    var it = std.mem.tokenizeAny(u8, line, ", x");
    return .{
        .x = try std.fmt.parseInt(i32, it.next() orelse return error.BadSlurpOutputX, 10),
        .y = try std.fmt.parseInt(i32, it.next() orelse return error.BadSlurpOutputY, 10),
        .width = try std.fmt.parseInt(u32, it.next() orelse return error.BadSlurpOutputWidth, 10),
        .height = try std.fmt.parseInt(u32, it.next() orelse return error.BadSlurpOutputHeight, 10),
    };
}

const RegistryData = struct {
    compositor: ?*wl.Compositor = null,
    seat: ?*wl.Seat = null,
    zwlr_screencopy_manager: ?*zwlr.ScreencopyManagerV1 = null,
    shm: ?*wl.Shm = null,
    output: ?*wl.Output = null,

    pub fn listener(registry: *wl.Registry, event: wl.Registry.Event, self: *RegistryData) void {
        switch (event) {
            .global => |global| inline for (std.meta.fields(RegistryData)) |field| {
                const GlobalType = std.meta.Child(std.meta.Child(field.type));
                if (std.mem.orderZ(u8, global.interface, GlobalType.interface.name) == .eq) {
                    @field(self.*, field.name) = registry.bind(global.name, GlobalType, GlobalType.interface.version) catch return;
                    return;
                }
            },
            .global_remove => {},
        }
    }
};
