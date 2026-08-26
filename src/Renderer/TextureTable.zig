const TexturePool = @This();

const vk = @import("vulkan");
const Buffer = @import("Buffer.zig").Buffer;
const Image = @import("Image.zig");
const Device = @import("Device.zig");
const PhysicalDevice = @import("PhysicalDevice.zig");
const DescriptorLayout = @import("DescriptorLayout.zig");

const frames_in_flight = @import("../Renderer.zig").frames_in_flight;

table: [256]struct { state: State, image: Image } = undefined,

descriptor_buffer: Buffer(u8),
descriptor_layout_size: u64,
default_sampler: vk.Sampler,

pub const Handle = enum(u32) {
    blank = 0,
    _,
};

const State = union(enum) {
    unused,
    used,
    retired: usize,
};

pub const Data = struct {
    width: u32,
    height: u32,
    bytes: []const u8,
};
pub fn init(self: *TexturePool, device: Device, physical_device: PhysicalDevice, texture_layout: DescriptorLayout) !void {
    for (0..self.table.len) |i| self.table[i].state = .unused;

    self.descriptor_layout_size = device.proxy.getDescriptorSetLayoutSizeEXT(texture_layout.handle);
    self.descriptor_buffer = try Buffer(u8).init(
        self.descriptor_layout_size,
        physical_device,
        device,
        .{
            .shader_device_address_bit = true,
            .resource_descriptor_buffer_bit_ext = true,
            .sampler_descriptor_buffer_bit_ext = true,
        },
        .{ .host_visible_bit = true },
    );
    var sampler_info: vk.SamplerCreateInfo = .{
        .address_mode_u = .clamp_to_border,
        .address_mode_v = .clamp_to_border,
        .address_mode_w = .clamp_to_border,
        .mag_filter = .linear,
        .min_filter = .linear,
        .mipmap_mode = .linear,
        .unnormalized_coordinates = .false,
        .anisotropy_enable = .false,
        .max_anisotropy = 0,
        .border_color = .float_opaque_black,
        .compare_enable = .false,
        .compare_op = .always,
        .min_lod = 0,
        .max_lod = 0,
        .mip_lod_bias = 0,
    };
    self.default_sampler = try device.proxy.createSampler(&sampler_info, null);
    _ = try self.alloc(device, physical_device, .{
        .width = 1,
        .height = 1,
        .bytes = &.{ 255, 255, 255, 255 },
    });
}

pub fn deinit(self: *TexturePool, device: Device) void {
    for (0..self.table.len) |handle| if (self.table[handle].state != .unused)
        self.table[handle].image.deinit(device);
    self.descriptor_buffer.deinit(device);
    device.proxy.destroySampler(self.default_sampler, null);
}

pub fn reclaim(self: *TexturePool, device: Device, current_frame: usize) void {
    for (&self.table) |*table| switch (table.state) {
        .retired => |retired_frame| if (retired_frame + frames_in_flight < current_frame) {
            table.image.deinit(device);
            table.state = .unused;
        },
        else => {},
    };
}

pub fn alloc(self: *TexturePool, device: Device, physical_device: PhysicalDevice, data: Data) !Handle {
    const handle: Handle = for (0..self.table.len) |i| {
        if (self.table[i].state == .unused) break @enumFromInt(i);
    } else return error.Full;
    var new_image: Image = try .init(
        device,
        physical_device,
        vk.Format.r8g8b8a8_unorm,
        .{ .width = data.width, .height = data.height },
        .{ .transfer_dst_bit = true, .color_attachment_bit = true, .sampled_bit = true },
        .{ .color_bit = true },
    );
    try new_image.uploadData(
        device,
        physical_device,
        data.bytes,
    );
    var image_info: vk.DescriptorImageInfo = .{
        .sampler = self.default_sampler,
        .image_view = new_image.view,
        .image_layout = .shader_read_only_optimal,
    };
    var descrtiptor_info: vk.DescriptorGetInfoEXT = .{
        .type = .combined_image_sampler,
        .data = .{ .p_combined_image_sampler = &image_info },
    };

    const destinaiton = @as([*]u8, @ptrCast(self.descriptor_buffer.mapped)) + @intFromEnum(handle) * physical_device.sampler_descriptor_size;
    device.proxy.getDescriptorEXT(
        &descrtiptor_info,
        physical_device.sampler_descriptor_size,
        destinaiton,
    );
    self.table[@intFromEnum(handle)] = .{ .state = .used, .image = new_image };
    return handle;
}

pub fn retire(self: *TexturePool, handle: Handle, frame: usize) void {
    self.table[@intFromEnum(handle)].state = .{ .retired = frame };
}
