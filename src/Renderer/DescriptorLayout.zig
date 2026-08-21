const DescriptorLayout = @This();

const vk = @import("vulkan");
const Device = @import("Device.zig");

handle: vk.DescriptorSetLayout,
// count: u32,

pub fn init(device: Device, bindings: []const vk.DescriptorSetLayoutBinding, descriptor_flags: vk.DescriptorSetLayoutCreateFlags) !DescriptorLayout {
    var info: vk.DescriptorSetLayoutCreateInfo = .{
        .p_bindings = bindings.ptr,
        .binding_count = @intCast(bindings.len),
        .flags = descriptor_flags,
    };

    return .{
        .handle = try device.proxy.createDescriptorSetLayout(&info, null),
        // .count = @intCast(bindings.len),
    };
}

pub fn deinit(self: DescriptorLayout, device: Device) void {
    device.proxy.destroyDescriptorSetLayout(self.handle, null);
}
