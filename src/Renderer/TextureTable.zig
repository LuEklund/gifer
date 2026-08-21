const TextureTable = @This();

const vk = @import("vulkan");
const Buffer = @import("Buffer.zig").Buffer;
const Image = @import("Image.zig");
const Device = @import("Device.zig");
const PhysicalDevice = @import("PhysicalDevice.zig");
const DescriptorLayout = @import("DescriptorLayout.zig");

table: [256]Image = undefined,
next_handle: Handle = .blank,

descriptor_buffer: Buffer(u8),
descriptor_layout_size: u64,
default_sampler: vk.Sampler,

pub const Handle = enum(u32) {
    blank = 0,
    _,
};

pub const Info = struct {
    data: []const u8,
    width: u32,
    height: u32,
};

pub fn init(self: *TextureTable, device: Device, physical_device: PhysicalDevice, texture_layout: DescriptorLayout) !void {
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
    self.next_handle = .blank;
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
    _ = try self.createTexture(device, physical_device, .{
        .width = 1,
        .height = 1,
        .data = &.{ 255, 255, 255, 255 },
    });
}

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
        vk.Format.r8g8b8a8_unorm,
        .{ .width = info.width, .height = info.height },
        .{ .transfer_dst_bit = true, .color_attachment_bit = true, .sampled_bit = true },
        .{ .color_bit = true },
    );
    try new_image.uploadData(
        device,
        physical_device,
        info.data,
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
    self.table[@intFromEnum(self.next_handle)] = new_image;
    self.next_handle = @enumFromInt(1 + @intFromEnum(self.next_handle));
    return handle;
}
