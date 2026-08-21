const PipelineLayout = @This();

const vk = @import("vulkan");
const Device = @import("Device.zig");

handle: vk.PipelineLayout,

pub fn init(device: Device, push_constant_ranges: []const vk.PushConstantRange, descriptor_set_layouts: []const vk.DescriptorSetLayout) !PipelineLayout {
    var layout_create_info: vk.PipelineLayoutCreateInfo = .{
        .p_set_layouts = descriptor_set_layouts.ptr,
        .set_layout_count = @intCast(descriptor_set_layouts.len),
        .p_push_constant_ranges = push_constant_ranges.ptr,
        .push_constant_range_count = @intCast(push_constant_ranges.len),
    };
    return .{
        .handle = try device.proxy.createPipelineLayout(&layout_create_info, null),
    };
}

pub fn deinit(self: PipelineLayout, device: Device) void {
    device.proxy.destroyPipelineLayout(self.handle, null);
}
