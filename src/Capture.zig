const std = @import("std");

pub const Region = struct {
    x: i32,
    y: i32,
    width: u32,
    height: u32,
};

pub const Inner = @import("Capture/Wayland.zig");

pub const selectRegion = Inner.selectRegion;
