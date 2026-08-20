const Surface = @This();

const builtin = @import("builtin");

const vk = @import("vulkan");

const Window = @import("../Window.zig");
const Wayland = @import("../Window/Wayland.zig");
const Xlib = @import("../Window/Xlib.zig");
const Win32 = @import("../Window/Win32.zig");
const Cocoa = @import("../Window/Cocoa.zig");

const Instance = @import("Instance.zig");

handle: vk.SurfaceKHR,

pub const WaylandError = vk.InstanceWrapper.CreateWaylandSurfaceKHRError;
pub const XlibError = vk.InstanceWrapper.CreateXlibSurfaceKHRError;
pub const Win32Error = vk.InstanceWrapper.CreateWin32SurfaceKHRError;
pub const CocoaError = vk.InstanceWrapper.CreateMacOsSurfaceMVKError;

pub const InitError = switch (builtin.os.tag) {
    .linux, .freebsd, .openbsd, .netbsd, .dragonfly, .illumos => WaylandError || XlibError,
    .windows => Win32Error,
    .macos => CocoaError,
    else => error{},
};

pub fn init(instance: Instance, window: *Window) InitError!Surface {
    return switch (builtin.os.tag) {
        .linux, .freebsd, .openbsd, .netbsd, .dragonfly, .illumos => switch (window.inner) {
            .wayland => .initWayland(instance, &window.inner.wayland),
            .x11 => .initXlib(instance, &window.inner.x11),
        },
        .windows => .initWin32(instance, &window.inner),
        .macos => .initCocoa(instance, &window.inner),
        else => @compileError("unsupported platform"),
    };
}

pub fn deinit(self: Surface, instance: Instance) void {
    instance.proxy.destroySurfaceKHR(self.handle, null);
}

fn initWayland(instance: Instance, wayland: *Wayland) WaylandError!Surface {
    const create_info: *const vk.WaylandSurfaceCreateInfoKHR = &.{
        .display = @ptrCast(wayland.display),
        .surface = @ptrCast(wayland.surface),
    };

    const handle = try instance.proxy.createWaylandSurfaceKHR(create_info, null);
    return .{ .handle = handle };
}

fn initXlib(instance: Instance, xlib: *Xlib) XlibError!Surface {
    const create_info: *const vk.XlibSurfaceCreateInfoKHR = &.{
        .dpy = @ptrCast(xlib.display),
        .window = xlib.xid.id,
    };

    const handle = try instance.proxy.createXlibSurfaceKHR(create_info, null);
    return .{ .handle = handle };
}

fn initWin32(instance: Instance, win32: *Win32) Win32Error!Surface {
    const create_info: *const vk.Win32SurfaceCreateInfoKHR = &.{
        .hinstance = win32.hinstance,
        .hwnd = win32.hwnd,
    };

    const handle = try instance.proxy.createWin32SurfaceKHR(create_info, null);
    return .{ .handle = handle };
}

fn initCocoa(instance: Instance, cocoa: *Cocoa) CocoaError!Surface {
    const create_info: *const vk.MetalSurfaceCreateInfoEXT = &.{
        .p_layer = @ptrCast(cocoa.metal_layer),
    };

    const handle = try instance.proxy.createMetalSurfaceEXT(create_info, null);
    return .{ .handle = handle };
}
