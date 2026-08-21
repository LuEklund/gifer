const ShaderObject = @This();

const std = @import("std");
const vk = @import("vulkan");

const Device = @import("Device.zig");

handle: vk.ShaderEXT,
stage: vk.ShaderStageFlags,

pub const Description = struct {
    stage: vk.ShaderStageFlags,
    next_stage: vk.ShaderStageFlags = .{},
    source: []const u8,
    entry_name: [*:0]const u8 = "main",
    push_constant_ranges: []const vk.PushConstantRange = &.{},
    descriptor_layputs: []const vk.DescriptorSetLayout = &.{},
};

pub const InitError = vk.DeviceProxy.CreateShadersEXTError;

pub fn init(device: Device, description: Description) InitError!ShaderObject {
    const magic = std.mem.readInt(u32, @ptrCast(std.mem.bytesAsSlice(u32, description.source[0..4])), .little);
    std.debug.assert(magic == 0x7230203);

    const create_info: vk.ShaderCreateInfoEXT = .{
        .stage = description.stage,
        .next_stage = description.next_stage,
        .code_type = .spirv_ext,
        .code_size = description.source.len,
        .p_code = @ptrCast(description.source.ptr),
        .p_name = description.entry_name,
        .push_constant_range_count = @truncate(description.push_constant_ranges.len),
        .p_push_constant_ranges = description.push_constant_ranges.ptr,
        .set_layout_count = @intCast(description.descriptor_layputs.len),
        .p_set_layouts = description.descriptor_layputs.ptr,
    };

    var handle: vk.ShaderEXT = undefined;
    _ = try device.proxy.createShadersEXT(&.{create_info}, null, @ptrCast(&handle));
    return .{
        .handle = handle,
        .stage = description.stage,
    };
}

pub fn initMany(comptime count: usize, device: Device, descriptions: [count]Description) InitError![count]ShaderObject {
    var create_infos: [count]vk.ShaderCreateInfoEXT = undefined;
    for (&create_infos, &descriptions) |*create_info, description| create_info.* = vk.ShaderCreateInfoEXT{
        .code_type = .spirv_ext,
        .stage = description.stage,
        .next_stage = description.next_stage,
        .code_size = description.source.len,
        .p_code = @ptrCast(description.source.ptr),
        .p_name = description.entry_name,
    };

    var handles: [count]vk.ShaderEXT = undefined;
    _ = try device.proxy.createShadersEXT(&create_infos, null, &handles);

    var shader_objects: [count]ShaderObject = undefined;
    for (&shader_objects, &handles, &descriptions) |*shader_object, handle, description| shader_object.* = .{
        .handle = handle,
        .stage = description.stage,
    };

    return shader_objects;
}

pub fn deinit(self: ShaderObject, device: Device) void {
    device.proxy.destroyShaderEXT(self.handle, null);
}
