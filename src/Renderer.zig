const Renderer = @This();

const builtin = @import("builtin");

const std = @import("std");
const vk = @import("vulkan");

const DynLib = @import("DynLib.zig");
const Window = @import("Window.zig");

const Instance = @import("Renderer/Instance.zig");
const DebugMessenger = @import("Renderer/DebugMessenger.zig");
const Surface = @import("Renderer/Surface.zig");
const PhysicalDevice = @import("Renderer/PhysicalDevice.zig");
const Device = @import("Renderer/Device.zig");
const Swapchain = @import("Renderer/Swapchain.zig");
const FrameData = @import("Renderer/FrameData.zig");
const ShaderObject = @import("Renderer/ShaderObject.zig");
const Buffer = @import("Renderer/Buffer.zig");
const Image = @import("Renderer/Image.zig");
const TextureTable = @import("Renderer/TextureTable.zig");

gpa: std.mem.Allocator,

dynlib: DynLib,

vkb: vk.BaseWrapper,
instance: Instance,
debug_messenger: DebugMessenger,
surface: Surface,
physical_device: PhysicalDevice,
device: Device,
swapchain: Swapchain,

texture_table: TextureTable,
shader_obj_vert: ShaderObject,
shader_obj_frag: ShaderObject,

frames: [frames_in_flight]FrameData,
frame_index: usize,

pub const frames_in_flight = 3;

const libvulkan = switch (builtin.os.tag) {
    .windows => "vulkan-1.dll",
    .linux, .freebsd, .openbsd, .netbsd, .dragonfly, .illumos => "libvulkan.so.1",
    .macos => "libvulkan.1.dylib",
    else => @compileError("unsupported platform"),
};

const debug_instance_extensions: []const [*:0]const u8 = if (builtin.mode == .Debug)
    &.{"VK_EXT_debug_utils"}
else
    &.{};

const layers: []const [*:0]const u8 = if (builtin.mode == .Debug)
    &.{"VK_LAYER_KHRONOS_validation"}
else
    &.{};

pub fn init(allocator: std.mem.Allocator, window: *Window) !Renderer {
    const platform_extensions: []const [*:0]const u8 = switch (builtin.os.tag) {
        .linux, .freebsd, .openbsd, .netbsd, .dragonfly, .illumos => switch (window.inner) {
            .wayland => &.{
                vk.extensions.khr_surface.name,
                vk.extensions.khr_wayland_surface.name,
            },
            .x11 => &.{
                vk.extensions.khr_surface.name,
                vk.extensions.khr_xlib_surface.name,
            },
        },
        .windows => &.{
            vk.extensions.khr_surface.name,
            vk.extensions.khr_win_32_surface.name,
        },
        .macos => &.{
            vk.extensions.khr_surface.name,
            vk.extensions.ext_external_memory_metal.name,
        },
        else => &.{},
    };

    const device_extensions: []const [*:0]const u8 = &.{
        vk.extensions.khr_swapchain.name,
        vk.extensions.ext_shader_object.name,
    };

    const gpa = allocator;

    var extensions: std.ArrayList([*:0]const u8) = try .initCapacity(gpa, debug_instance_extensions.len + 4);
    defer extensions.deinit(gpa);
    extensions.appendSliceAssumeCapacity(debug_instance_extensions);
    extensions.appendSliceAssumeCapacity(platform_extensions);

    var dynlib: DynLib = try .open(libvulkan);
    const getInstanceProcAddr = dynlib.lookup(vk.PfnGetInstanceProcAddr, "vkGetInstanceProcAddr") orelse return error.DynlibLookup;

    const vkb: vk.BaseWrapper = .load(getInstanceProcAddr);

    const instance: Instance = try .init(gpa, vkb, layers, extensions.items);
    errdefer instance.deinit(gpa);

    const debug_messenger: DebugMessenger = try .init(instance);
    errdefer debug_messenger.deinit(instance);

    const surface: Surface = try .init(instance, window);
    errdefer surface.deinit(instance);

    const physical_device: PhysicalDevice = try .pick(gpa, instance, surface);
    const device: Device = try .init(gpa, instance, physical_device, device_extensions);
    errdefer device.deinit(gpa);

    var swapchain: Swapchain = undefined;
    try swapchain.create(gpa, instance, surface, physical_device, device, window.size);
    errdefer swapchain.deinit(gpa, device);

    var frame_datas: [frames_in_flight]FrameData = undefined;
    for (&frame_datas) |*frame_data| {
        try frame_data.init(device);
    }

    var texture_table: TextureTable = .{};
    _ = try texture_table.createTexture(device, physical_device, .{
        .width = 1,
        .height = 1,
        .data = &.{ 255, 255, 255, 255 },
    });

    const data = @embedFile("assets/shaders/vert.spv");
    const shader_obj_vert = try ShaderObject.init(device, .{
        .entry_name = "vertex",
        .source = data,
        .stage = .{ .vertex_bit = true },
        .next_stage = .{ .fragment_bit = true },
        .push_constant_ranges = &.{},
    });
    const shader_obj_frag = try ShaderObject.init(device, .{
        .entry_name = "fragment",
        .source = data,
        .stage = .{ .fragment_bit = true },
        .next_stage = .{},
        .push_constant_ranges = &.{},
    });

    return .{
        .gpa = gpa,

        .texture_table = texture_table,
        .shader_obj_vert = shader_obj_vert,
        .shader_obj_frag = shader_obj_frag,

        .dynlib = dynlib,

        .vkb = vkb,
        .instance = instance,
        .debug_messenger = debug_messenger,
        .surface = surface,
        .physical_device = physical_device,
        .device = device,
        .swapchain = swapchain,
        .frames = frame_datas,
        .frame_index = 0,
    };
}

pub fn deinit(self: *Renderer) void {
    const gpa = self.gpa;
    const instance = self.instance;
    const device = self.device;

    device.proxy.deviceWaitIdle() catch unreachable;

    self.texture_table.deinit(device);
    for (&self.frames) |*frame| {
        device.proxy.destroySemaphore(frame.image_available, null);
        device.proxy.destroyFence(frame.in_flight_fence, null);
    }
    self.swapchain.deinit(gpa, device);
    device.deinit(gpa);
    self.surface.deinit(instance);
    self.debug_messenger.deinit(instance);
    instance.deinit(gpa);

    self.dynlib.close();
    self.* = undefined;
}

pub fn resize(self: *Renderer, size: Window.Size) !void {
    if (size.width == 0 or size.height == 0) return;
    if (size.width == self.swapchain.extent.width and size.height == self.swapchain.extent.height) return;

    try self.swapchain.recreate(
        self.gpa,
        self.instance,
        self.surface,
        self.physical_device,
        self.device,
        size,
        self.frame_index,
    );
}

pub const BeginOptions = struct {
    clear_color: [4]f32 = .{ 0.0, 0.0, 0.0, 1.0 },
};

pub fn begin(self: *Renderer, size: Window.Size, options: BeginOptions) !void {
    const device = self.device;
    const swapchain = &self.swapchain;

    try self.resize(size);

    const frame_data = self.frames[self.frame_index % frames_in_flight];

    _ = try device.proxy.waitForFences(
        &.{frame_data.in_flight_fence},
        .true,
        std.math.maxInt(u64),
    );

    try device.proxy.resetFences(&.{frame_data.in_flight_fence});

    swapchain.drain(
        self.gpa,
        device,
        self.frame_index,
        frames_in_flight,
    );

    const acquired = device.proxy.acquireNextImageKHR(
        swapchain.handle,
        std.math.maxInt(u64),
        frame_data.image_available,
        .null_handle,
    ) catch |err| switch (err) {
        error.OutOfDateKHR => {
            try self.resize(size);
            return error.SwapchainOutOfDate;
        },
        else => return err,
    };

    if (acquired.result == .suboptimal_khr) {
        try self.resize(size);
        return error.SwapchainOutOfDate;
    }

    swapchain.image_index = acquired.image_index;

    const image = swapchain.images[swapchain.image_index];

    try device.proxy.resetCommandBuffer(
        frame_data.command_buffer,
        .{},
    );

    try device.proxy.beginCommandBuffer(
        frame_data.command_buffer,
        &.{},
    );

    const color_barrier = vk.ImageMemoryBarrier{
        .src_access_mask = .{},
        .dst_access_mask = .{
            .color_attachment_write_bit = true,
        },
        .old_layout = .undefined,
        .new_layout = .color_attachment_optimal,
        .src_queue_family_index = vk.QUEUE_FAMILY_IGNORED,
        .dst_queue_family_index = vk.QUEUE_FAMILY_IGNORED,
        .image = image,
        .subresource_range = .{
            .aspect_mask = .{
                .color_bit = true,
            },
            .base_mip_level = 0,
            .level_count = 1,
            .base_array_layer = 0,
            .layer_count = 1,
        },
    };

    device.proxy.cmdPipelineBarrier(
        frame_data.command_buffer,
        .{ .top_of_pipe_bit = true },
        .{ .color_attachment_output_bit = true },
        .{},
        null,
        null,
        &.{color_barrier},
    );

    device.proxy.cmdSetViewportWithCount(
        frame_data.command_buffer,
        &.{.{
            .x = 0,
            .y = 0,
            .width = @floatFromInt(swapchain.extent.width),
            .height = @floatFromInt(swapchain.extent.height),
            .min_depth = 0,
            .max_depth = 1,
        }},
    );

    device.proxy.cmdSetScissorWithCount(
        frame_data.command_buffer,
        &.{.{
            .offset = .{ .x = 0, .y = 0 },
            .extent = swapchain.extent,
        }},
    );

    const clear_color: vk.ClearValue = .{
        .color = .{
            .float_32 = options.clear_color,
        },
    };

    const clear_depth: vk.ClearValue = .{
        .depth_stencil = .{
            .depth = 1.0,
            .stencil = 0,
        },
    };

    const color_attachment: *const vk.RenderingAttachmentInfo = &.{
        .image_view = swapchain.image_views[swapchain.image_index],
        .image_layout = .color_attachment_optimal,
        .load_op = .clear,
        .store_op = .store,
        .clear_value = clear_color,
        .resolve_mode = .{},
        .resolve_image_layout = .undefined,
    };

    const depth_attachment: *const vk.RenderingAttachmentInfo = &.{
        .image_view = swapchain.depth.view,
        .image_layout = .depth_attachment_optimal,
        .load_op = .clear,
        .store_op = .store,
        .clear_value = clear_depth,
        .resolve_mode = .{},
        .resolve_image_layout = .undefined,
    };

    const rendering_info: *const vk.RenderingInfo = &.{
        .render_area = .{
            .offset = .{ .x = 0, .y = 0 },
            .extent = swapchain.extent,
        },
        .layer_count = 1,
        .color_attachment_count = 1,
        .p_color_attachments = @ptrCast(color_attachment),
        .p_depth_attachment = depth_attachment,
        .view_mask = 0,
    };

    const to_depth: vk.ImageMemoryBarrier = .{
        .image = swapchain.depth.handle,
        .old_layout = .undefined,
        .src_access_mask = .{},
        .new_layout = .depth_attachment_optimal,
        .dst_access_mask = .{},
        .dst_queue_family_index = vk.QUEUE_FAMILY_IGNORED,
        .src_queue_family_index = vk.QUEUE_FAMILY_IGNORED,
        .subresource_range = .{
            .aspect_mask = .{ .depth_bit = true },
            .base_array_layer = 0,
            .base_mip_level = 0,
            .layer_count = 1,
            .level_count = 1,
        },
    };
    device.proxy.cmdPipelineBarrier(
        frame_data.command_buffer,
        .{},
        .{},
        .{},
        null,
        null,
        &.{to_depth},
    );

    device.proxy.cmdBeginRendering(
        frame_data.command_buffer,
        rendering_info,
    );

    device.proxy.cmdBindShadersEXT(frame_data.command_buffer, &.{.{ .vertex_bit = true }}, &.{self.shader_obj_vert.handle});
    device.proxy.cmdBindShadersEXT(frame_data.command_buffer, &.{.{ .tessellation_control_bit = true }}, null);
    device.proxy.cmdBindShadersEXT(frame_data.command_buffer, &.{.{ .tessellation_evaluation_bit = true }}, null);
    device.proxy.cmdBindShadersEXT(frame_data.command_buffer, &.{.{ .geometry_bit = true }}, null);
    device.proxy.cmdBindShadersEXT(frame_data.command_buffer, &.{.{ .fragment_bit = true }}, &.{self.shader_obj_frag.handle});
}

pub fn draw(self: *Renderer) !void {
    const device = self.device;
    const frame_data = self.frames[self.frame_index % frames_in_flight];

    bindDefaultState(frame_data, device);

    device.proxy.cmdSetPolygonModeEXT(frame_data.command_buffer, .fill);
    device.proxy.cmdSetPrimitiveTopology(frame_data.command_buffer, .triangle_list);
    // device.proxy.cmdSetLineWidth(self.command_buffer, 1);

    device.proxy.cmdSetPrimitiveRestartEnable(frame_data.command_buffer, .false);
    device.proxy.cmdSetVertexInputEXT(
        frame_data.command_buffer,
        null,
        null,
    );

    device.proxy.cmdDraw(
        frame_data.command_buffer,
        3,
        1,
        0,
        0,
    );
}

pub fn submit(self: *Renderer) !void {
    const device = self.device;
    const swapchain = self.swapchain;
    const frame_data = self.frames[self.frame_index % frames_in_flight];

    const command_buffer = frame_data.command_buffer;

    device.proxy.cmdEndRendering(command_buffer);

    const color_to_present: vk.ImageMemoryBarrier = .{
        .src_access_mask = .{ .color_attachment_write_bit = true },
        .dst_access_mask = .{},
        .old_layout = .color_attachment_optimal,
        .new_layout = .present_src_khr,
        .src_queue_family_index = vk.QUEUE_FAMILY_IGNORED,
        .dst_queue_family_index = vk.QUEUE_FAMILY_IGNORED,
        .image = swapchain.images[swapchain.image_index],
        .subresource_range = .{
            .aspect_mask = .{ .color_bit = true },
            .base_mip_level = 0,
            .level_count = 1,
            .base_array_layer = 0,
            .layer_count = 1,
        },
    };

    device.proxy.cmdPipelineBarrier(
        command_buffer,
        .{ .color_attachment_output_bit = true },
        .{},
        .{},
        null,
        null,
        &.{color_to_present},
    );

    try device.proxy.endCommandBuffer(command_buffer);

    const wait_semaphores: []const vk.Semaphore = &.{
        frame_data.image_available,
    };

    const signal_semaphores: []const vk.Semaphore = &.{
        swapchain.finished[swapchain.image_index],
    };

    const wait_stages: []const vk.PipelineStageFlags = &.{
        .{ .color_attachment_output_bit = true },
    };

    const submit_info: vk.SubmitInfo = .{
        .command_buffer_count = 1,
        .p_command_buffers = &.{frame_data.command_buffer},
        .wait_semaphore_count = @intCast(wait_semaphores.len),
        .p_wait_semaphores = wait_semaphores.ptr,
        .signal_semaphore_count = @intCast(signal_semaphores.len),
        .p_signal_semaphores = signal_semaphores.ptr,
        .p_wait_dst_stage_mask = wait_stages.ptr,
    };

    try device.proxy.queueSubmit(device.graphics_queue, &.{submit_info}, frame_data.in_flight_fence);

    const present_info: vk.PresentInfoKHR = .{
        .wait_semaphore_count = @intCast(signal_semaphores.len),
        .p_wait_semaphores = signal_semaphores.ptr,
        .swapchain_count = 1,
        .p_swapchains = &.{swapchain.handle},
        .p_image_indices = &.{swapchain.image_index},
    };

    _ = device.proxy.queuePresentKHR(device.graphics_queue, &present_info) catch |err| switch (err) {
        error.OutOfDateKHR => {},
        else => return err,
    };

    self.frame_index += 1;
}

// pub fn uploadShader(self: *Renderer,

pub fn bindDefaultState(self: FrameData, device: Device) void {
    const command_buffer = self.command_buffer;

    // rasterizer
    device.proxy.cmdSetRasterizerDiscardEnable(command_buffer, .false);

    device.proxy.cmdSetPolygonModeEXT(command_buffer, .fill);

    device.proxy.cmdSetCullMode(
        command_buffer,
        .{},
    );
    device.proxy.cmdSetFrontFace(command_buffer, .counter_clockwise);

    device.proxy.cmdSetDepthBiasEnable(command_buffer, .false);

    device.proxy.cmdSetDepthClampEnableEXT(command_buffer, .false);

    // multisampling
    device.proxy.cmdSetRasterizationSamplesEXT(
        command_buffer,
        .{ .@"1_bit" = true },
    );

    device.proxy.cmdSetSampleMaskEXT(
        command_buffer,
        .{ .@"1_bit" = true },
        &.{0xffffffff},
    );

    device.proxy.cmdSetAlphaToCoverageEnableEXT(command_buffer, .false);

    device.proxy.cmdSetAlphaToOneEnableEXT(command_buffer, .false);

    // depth/stencil
    device.proxy.cmdSetDepthTestEnable(command_buffer, .true);
    device.proxy.cmdSetDepthWriteEnable(command_buffer, .true);
    device.proxy.cmdSetDepthCompareOp(command_buffer, .less);
    device.proxy.cmdSetDepthBoundsTestEnable(command_buffer, .false);
    device.proxy.cmdSetStencilTestEnable(command_buffer, .false);

    // blending
    device.proxy.cmdSetColorBlendEnableEXT(
        command_buffer,
        0,
        &.{.true},
    );

    device.proxy.cmdSetColorBlendEquationEXT(
        command_buffer,
        0,
        &.{.{
            .src_color_blend_factor = .src_alpha,
            .dst_color_blend_factor = .one_minus_src_alpha,
            .color_blend_op = .add,
            .src_alpha_blend_factor = .one,
            .dst_alpha_blend_factor = .zero,
            .alpha_blend_op = .add,
        }},
    );

    device.proxy.cmdSetColorWriteMaskEXT(
        command_buffer,
        0,
        &.{.{
            .r_bit = true,
            .g_bit = true,
            .b_bit = true,
            .a_bit = true,
        }},
    );

    device.proxy.cmdSetLogicOpEnableEXT(command_buffer, .false);
}

pub const PolygonMode = union(vk.PolygonMode) {
    fill,
    line: struct {
        width: f32 = 1.0,
    },
    point,
    fill_rectangle_nv,
};

pub fn setPolygonMode(self: FrameData, device: Device, mode: PolygonMode) void {
    const mode_enum = std.meta.activeTag(mode);
    device.proxy.cmdSetPolygonModeEXT(self.command_buffer, mode_enum);

    switch (mode) {
        .line => |line| device.proxy.cmdSetLineWidth(self.command_buffer, line.width),
        else => {},
    }
}

pub fn setCullMode(self: FrameData, device: Device, mode: vk.CullModeFlags) void {
    device.proxy.cmdSetCullMode(self.command_buffer, mode);
}

pub fn Shader(stage: vk.ShaderStageFlags) type {
    const default_next_stage: vk.ShaderStageFlags = if (stage.vertex_bit)
        .{ .fragment_bit = true }
    else if (stage.tessellation_control_bit)
        .{ .tessellation_evaluation_bit = true }
    else if (stage.tessellation_evaluation_bit)
        .{ .geometry_bit = true }
    else if (stage.geometry_bit)
        .{ .fragment_bit = true }
    else
        .{};

    return struct {
        const Self = @This();

        object: ShaderObject,

        pub const InitOptions = struct {
            next_stage: vk.ShaderStageFlags = default_next_stage,
            entry_name: [*:0]const u8 = "main",
        };

        pub const InitError = ShaderObject.InitError;

        pub fn initFromSlice(device: Device, source: []const u8, options: InitOptions) InitError!Self {
            const shader_object: ShaderObject = try .init(device, .{
                .stage = stage,
                .next_stage = options.next_stage,
                .source = source,
                .entry_name = options.entry_name,
            });

            return .{ .object = shader_object };
        }

        pub fn initFromSliceWithPushConstants(device: Device, source: []const u8, options: InitOptions, push_constant_range: PushConstantRange) InitError!Self {
            const shader_object: ShaderObject = try .init(device, .{
                .stage = stage,
                .next_stage = options.next_stage,
                .source = source,
                .entry_name = options.entry_name,
                .push_constant_ranges = &.{push_constant_range},
            });

            return .{ .object = shader_object };
        }

        pub fn deinit(self: Self, device: Device) void {
            self.object.deinit(device);
        }

        pub fn bind(self: Self, device: Device, frame_data: FrameData) void {
            device.proxy.cmdBindShadersEXT(
                frame_data.command_buffer,
                &.{stage},
                &.{self.object.handle},
            );
        }
    };
}

pub const PushConstantRange = vk.PushConstantRange;
pub fn PushConstant(comptime Value: type, shader_stages: vk.ShaderStageFlags) type {
    switch (@typeInfo(Value)) {
        .@"struct" => |s| {
            if (s.layout != .@"extern") @compileError("expected extern struct layout for push constants, found '" ++ @tagName(s.layout) ++ "' in '" ++ @typeName(Value) ++ "'");
        },
        else => |info| {
            @compileError("expected extern struct for push constants, found '" ++ @tagName(info) ++ " in '" ++ @typeName(Value) ++ "'");
        },
    }

    const range: vk.PushConstantRange = .{
        .stage_flags = shader_stages,
        .offset = 0,
        .size = @sizeOf(Value),
    };

    return struct {
        const Self = @This();

        layout: vk.PipelineLayout,

        pub fn init(device: Device) !Self {
            const layout_create_info = vk.PipelineLayoutCreateInfo{
                .push_constant_range_count = 1,
                .p_push_constant_ranges = @ptrCast(&range),
            };

            const layout = try device.proxy.createPipelineLayout(&layout_create_info, null);

            return .{ .layout = layout };
        }

        pub fn deinit(self: Self, device: Device) void {
            device.proxy.destroyPipelineLayout(self.layout, null);
        }

        pub fn push(self: Self, device: Device, frame_data: FrameData, value: Value) void {
            device.proxy.cmdPushConstants(
                frame_data.command_buffer,
                self.layout,
                range.stage_flags,
                range.offset,
                range.size,
                &value,
            );
        }
    };
}
