const Buffer = @This();

const vk = @import("vulkan");

const PhysicalDevice = @import("PhysicalDevice.zig");
const Device = @import("Device.zig");

handle: vk.Buffer,
memory: vk.DeviceMemory,

pub fn init(
    comptime T: type,
    physical_device: PhysicalDevice,
    device: Device,
    usage: vk.BufferUsageFlags,
    memory_properties: vk.MemoryPropertyFlags,
    data: []const T,
) !Buffer {
    const create_info: *const vk.BufferCreateInfo = &.{
        .size = data.len * @sizeOf(T),
        .usage = usage,
        .sharing_mode = .exclusive,
    };

    const handle = try device.proxy.createBuffer(create_info, null);

    const requirements = device.proxy.getBufferMemoryRequirements(handle);

    const memory_type = PhysicalDevice.findMemoryType(
        requirements.memory_type_bits,
        memory_properties,
        physical_device.memory_properties,
    );

    const memory_allocate_info: *const vk.MemoryAllocateInfo = &.{
        .allocation_size = requirements.size,
        .memory_type_index = memory_type,
    };

    const memory = try device.proxy.allocateMemory(memory_allocate_info, null);

    try device.proxy.bindBufferMemory(handle, memory, 0);

    const mapped = try device.proxy.mapMemory(memory, 0, create_info.size, .{});

    const dst: [*]T = @ptrCast(@alignCast(mapped));
    @memcpy(dst[0..data.len], data);

    device.proxy.unmapMemory(memory);

    return .{
        .handle = handle,
        .memory = memory,
    };
}

pub fn deinit(self: Buffer, device: Device) void {
    device.proxy.destroyBuffer(self.handle, null);
    device.proxy.freeMemory(self.memory, null);
}

pub fn getAddress(self: Buffer, device: Device) vk.DeviceAddress {
    return device.proxy.getBufferDeviceAddress(&.{ .buffer = self.handle });
}
