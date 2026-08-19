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
    defer registry.destroy();

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
    //NOTE: replace later with overlay window?
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

pub const ShmBuffer = struct {
    proxy: *wl.Buffer,
    pixels: []align(std.heap.page_size_min) u8,
    params: FrameData.Params,

    pub fn create(shm: *wl.Shm, params: FrameData.Params) !ShmBuffer {
        const len = params.bytes_per_row * params.height;

        var name_buffer: [100]u8 = undefined;
        const name = try std.fmt.bufPrintSentinel(
            &name_buffer,
            "/gifer-capture-{d}x{d}",
            .{ params.width, params.height },
            0,
        );
        const fd = std.posix.system.shm_open(name.ptr, @bitCast(std.posix.O{
            .ACCMODE = .RDWR,
            .CREAT = true,
            .EXCL = true,
        }), std.posix.S.IWUSR | std.posix.S.IRUSR);
        if (fd < 0) return error.OpenShm;
        defer _ = std.posix.system.close(@intCast(fd));
        if (std.posix.system.ftruncate(@intCast(fd), @intCast(len)) != 0) return error.Truncate;

        const mapped = try std.posix.mmap(
            null,
            len,
            .{ .READ = true, .WRITE = true },
            .{ .TYPE = .SHARED },
            fd,
            0,
        );

        const pool = try shm.createPool(@intCast(fd), @intCast(len));
        defer pool.destroy();

        const buffer = try pool.createBuffer(
            0,
            @intCast(params.width),
            @intCast(params.height),
            @intCast(params.stride),
            params.format,
        );

        return .{ .proxy = buffer, .pixels = mapped, .params = params };
    }

    pub fn destroy(self: *ShmBuffer) void {
        self.proxy.destroy();
        std.posix.munmap(self.pixels);
    }
};

const FrameData = struct {
    params: ?Params,
    state: enum { waiting, ready, failed } = .waiting,
    timestamp_ns: u64 = 0,

    const Params = struct {
        format: wl.Shm.Format,
        width: u32,
        height: u32,
        bytes_per_row: u32,
    };

    fn listener(_: *zwlr.ScreencopyFrameV1, event: zwlr.ScreencopyFrameV1.Event, self: *FrameData) void {
        switch (event) {
            .buffer => |b| self.params = .{
                .format = b.format,
                .width = b.width,
                .height = b.height,
                .bytes_per_row = b.stride,
            },
            .ready => |r| {
                self.timestamp_ns = (@as(u64, r.tv_sec_hi) << 32) | r.tv_sec_lo * std.time.ns_per_s + r.tv_nsec;
                self.state = .ready;
            },
            .failed => self.state = .failed,
            else => {},
        }
    }
};
