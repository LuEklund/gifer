const TextureTable = @This();

const vk = @import("vulkan");
const Image = @import("Image.zig");
const Device = @import("Device.zig");
const PhysicalDevice = @import("PhysicalDevice.zig");

table: [256]Image = undefined,
next_handle: Handle = .blank,

pub const Handle = enum(u32) {
    blank = 0,
    _,
};

pub const Info = struct {
    data: []const u8,
    width: u32,
    height: u32,
};

pub fn deinit(self: *TextureTable, device: Device) void {
    for (0..@intFromEnum(self.next_handle)) |handle| {
        self.table[handle].deinit(device);
    }
}

pub fn createTexture(self: *TextureTable, device: Device, physical_device: PhysicalDevice, info: Info) !Handle {
    const handle = self.next_handle;
    var new_image: Image = try .init(
        device,
        physical_device,
        vk.Format.r8g8b8a8_snorm,
        .{ .width = info.width, .height = info.height },
        .{},
    );
    try new_image.uploadData(
        device,
        physical_device,
        info.data,
    );
    self.table[@intFromEnum(self.next_handle)] = new_image;
    self.next_handle = @enumFromInt(1 + @intFromEnum(self.next_handle));
    return handle;
}
