const FrameData = @This();

const std = @import("std");
const vk = @import("vulkan");
const Device = @import("Device.zig");

command_buffer: vk.CommandBuffer,
image_available: vk.Semaphore,
in_flight_fence: vk.Fence,

pub fn init(self: *FrameData, device: Device) !void {
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
}
