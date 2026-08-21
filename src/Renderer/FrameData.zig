const FrameData = @This();

const std = @import("std");
const vk = @import("vulkan");
const Device = @import("Device.zig");
const PhysicalDevice = @import("PhysicalDevice.zig");
const Buffer = @import("Buffer.zig").Buffer;

command_buffer: vk.CommandBuffer,
image_available: vk.Semaphore,
in_flight_fence: vk.Fence,
ui_verecies: Buffer(UiVertex),

pub const max_ui_quads = 1024;
pub const max_ui_indices = max_ui_quads * 6;
pub const max_ui_vertices = max_ui_quads * 4;

pub const UiVertex = extern struct {
    position: [3]f32,
    _: f32 = 0,
    color: [4]f32,
};

pub const PushConstant = extern struct {
    vertex_buffer: vk.DeviceAddress,
};

pub fn init(self: *FrameData, physical_device: PhysicalDevice, device: Device) !void {
    const create_info: *const vk.CommandBufferAllocateInfo = &.{
        .command_pool = device.command_pool,
        .level = .primary,
        .command_buffer_count = 1,
    };
    try device.proxy.allocateCommandBuffers(create_info, @ptrCast(&self.command_buffer));

    self.image_available = try device.proxy.createSemaphore(&.{}, null);

    const fence_create_info: *const vk.FenceCreateInfo = &.{
        .flags = .{ .signaled_bit = true },
    };
    self.in_flight_fence = try device.proxy.createFence(fence_create_info, null);
    self.ui_verecies = try Buffer(UiVertex).init(
        max_ui_vertices,
        physical_device,
        device,
        .{ .transfer_dst_bit = true, .vertex_buffer_bit = true, .shader_device_address_bit = true },
        .{ .host_visible_bit = true },
    );
}
