const vk = @import("vulkan");

const PhysicalDevice = @import("PhysicalDevice.zig");
const Device = @import("Device.zig");

pub fn Buffer(comptime T: type) type {
    return struct {
        const Self = @This();
        handle: vk.Buffer,
        memory: vk.DeviceMemory,
        mapped: *anyopaque,
        size: usize,

        pub fn init(
            amount: usize,
            physical_device: PhysicalDevice,
            device: Device,
            usage: vk.BufferUsageFlags,
            memory_properties: vk.MemoryPropertyFlags,
        ) !Self {
            const create_info: *const vk.BufferCreateInfo = &.{
                .size = amount * @sizeOf(T),
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
                .p_next = if (usage.shader_device_address_bit) &vk.MemoryAllocateFlagsInfo{
                    .flags = .{ .device_address_bit = true },
                    .device_mask = 0,
                } else null,
                .allocation_size = requirements.size,
                .memory_type_index = memory_type,
            };
            const memory = try device.proxy.allocateMemory(memory_allocate_info, null);

            try device.proxy.bindBufferMemory(handle, memory, 0);

            const mapped = try device.proxy.mapMemory(memory, 0, create_info.size, .{}) orelse return error.Mapped;

            return .{
                .handle = handle,
                .memory = memory,
                .size = create_info.size,
                .mapped = mapped,
            };
        }

        pub fn deinit(self: Self, device: Device) void {
            device.proxy.unmapMemory(self.memory);
            device.proxy.destroyBuffer(self.handle, null);
            device.proxy.freeMemory(self.memory, null);
        }

        pub fn upload(self: Self, data: []const T) !void {
            const dst: [*]T = @ptrCast(@alignCast(self.mapped));
            @memcpy(dst[0..data.len], data);
        }

        pub fn getAddress(self: Self, device: Device) vk.DeviceAddress {
            return device.proxy.getBufferDeviceAddress(&.{ .buffer = self.handle });
        }
    };
}
