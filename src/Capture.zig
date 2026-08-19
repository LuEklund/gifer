const std = @import("std");

pub const Inner = @import("Capture/Wayland.zig");

inner: Inner,

pub const Region = struct {
    x: i32,
    y: i32,
    width: u32,
    height: u32,
};

pub fn init() !@This() {
    return .{ .inner = try .init() };
}

pub const selectRegion = Inner.selectRegion;
