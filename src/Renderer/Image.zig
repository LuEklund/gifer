const Image = @This();

const vk = @import("vulkan");

const Buffer = @import("Buffer.zig").Buffer;
const Device = @import("Device.zig");
const PhysicalDevice = @import("PhysicalDevice.zig");

handle: vk.Image,
memory: vk.DeviceMemory,
view: vk.ImageView,

format: vk.Format,
size: vk.Extent2D,

pub fn init(
    device: Device,
    physical_device: PhysicalDevice,
    format: vk.Format,
    size: vk.Extent2D,
    usage: vk.ImageUsageFlags,
    aspect: vk.ImageAspectFlags,
) !Image {
    const extent = vk.Extent3D{
        .width = size.width,
        .height = size.height,
        .depth = 1,
    };

    const image_info = vk.ImageCreateInfo{
        .image_type = .@"2d",
        .format = format,
        .extent = extent,
        .mip_levels = 1,
        .array_layers = 1,
        .samples = .{ .@"1_bit" = true },
        .tiling = .optimal,
        .usage = usage,
        .sharing_mode = .exclusive,
        .initial_layout = .undefined,
    };

    const image = try device.proxy.createImage(
        &image_info,
        null,
    );
    errdefer device.proxy.destroyImage(
        image,
        null,
    );

    const requirements = device.proxy.getImageMemoryRequirements(image);

    const memory_type = PhysicalDevice.findMemoryType(
        requirements.memory_type_bits,
        .{ .device_local_bit = true },
        physical_device.memory_properties,
    );

    const memory_info = vk.MemoryAllocateInfo{
        .allocation_size = requirements.size,
        .memory_type_index = memory_type,
    };

    const memory = try device.proxy.allocateMemory(
        &memory_info,
        null,
    );
    errdefer device.proxy.freeMemory(
        memory,
        null,
    );

    try device.proxy.bindImageMemory(image, memory, 0);

    const view_info = vk.ImageViewCreateInfo{
        .image = image,
        .view_type = .@"2d",
        .format = format,
        .subresource_range = .{
            .aspect_mask = aspect,
            .base_mip_level = 0,
            .level_count = 1,
            .base_array_layer = 0,
            .layer_count = 1,
        },
        .components = .{
            .r = .identity,
            .g = .identity,
            .b = .identity,
            .a = .identity,
        },
    };

    const view = try device.proxy.createImageView(
        &view_info,
        null,
    );
    errdefer device.proxy.destroyImageView(
        view,
        null,
    );

    return .{
        .handle = image,
        .memory = memory,
        .view = view,
        .format = format,
        .size = size,
    };
}

pub fn deinit(self: Image, device: Device) void {
    device.proxy.destroyImageView(self.view, null);
    device.proxy.destroyImage(self.handle, null);
    device.proxy.freeMemory(self.memory, null);
}

pub fn uploadData(self: *Image, device: Device, physical_device: PhysicalDevice, data: []const u8) !void {
    var staging: Buffer(u8) = try .init(
        data.len,
        physical_device,
        device,
        .{ .transfer_src_bit = true },
        .{ .host_visible_bit = true, .host_coherent_bit = true },
    );
    try staging.upload(data);
    defer staging.deinit(device);

    const cmd = try device.beginImmediate();

    const to_transfer: vk.ImageMemoryBarrier = .{
        .old_layout = .undefined,
        .new_layout = .transfer_dst_optimal,
        .src_access_mask = .{},
        .dst_access_mask = .{ .transfer_write_bit = true },
        .src_queue_family_index = vk.QUEUE_FAMILY_IGNORED,
        .dst_queue_family_index = vk.QUEUE_FAMILY_IGNORED,
        .image = self.handle,
        .subresource_range = .{
            .aspect_mask = .{
                .color_bit = true,
            },
            .base_mip_level = 0,
            .layer_count = 1,
            .base_array_layer = 0,
            .level_count = 1,
        },
    };

    device.proxy.cmdPipelineBarrier(
        cmd,
        .{ .top_of_pipe_bit = true },
        .{ .transfer_bit = true },
        .{},
        null,
        null,
        &.{to_transfer},
    );

    device.proxy.cmdCopyBufferToImage(
        cmd,
        staging.handle,
        self.handle,
        .transfer_dst_optimal,
        &.{.{
            .buffer_offset = 0,
            .buffer_row_length = 0,
            .buffer_image_height = 0,
            .image_subresource = .{
                .mip_level = 0,
                .base_array_layer = 0,
                .layer_count = 1,
                .aspect_mask = .{ .color_bit = true },
            },
            .image_offset = .{ .x = 0, .y = 0, .z = 0 },
            .image_extent = .{ .height = self.size.height, .width = self.size.width, .depth = 1 },
        }},
    );

    const to_sampled: vk.ImageMemoryBarrier = .{
        .old_layout = .transfer_dst_optimal,
        .new_layout = .shader_read_only_optimal,
        .src_access_mask = .{ .transfer_write_bit = true },
        .dst_access_mask = .{ .shader_read_bit = true },
        .src_queue_family_index = vk.QUEUE_FAMILY_IGNORED,
        .dst_queue_family_index = vk.QUEUE_FAMILY_IGNORED,
        .image = self.handle,
        .subresource_range = to_transfer.subresource_range,
    };

    device.proxy.cmdPipelineBarrier(
        cmd,
        .{ .transfer_bit = true },
        .{ .fragment_shader_bit = true },
        .{},
        null,
        null,
        &.{to_sampled},
    );

    try device.endImmediate(cmd);
}
