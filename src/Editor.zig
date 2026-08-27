const Editor = @This();

const std = @import("std");
const Window = @import("Window.zig");
const Renderer = @import("Renderer.zig");
const Ui = @import("Ui.zig");
const TextureData = Renderer.TextureData;

gpa: std.mem.Allocator,
ui: Ui,
vertices: std.ArrayList(Renderer.UiVertex) = .empty,
playing: bool = false,
index: usize = 0,
previous_index: usize = 0,
counter: usize = 0,
display_handle: Renderer.TextureHandle = .blank,
box_select: SelectBox,

pub const SelectBox = struct {
    state: SelectState = .none,
    region: Ui.Rect,
    frames: FrameRange = .{},

    pub const FrameRange = struct {
        first: usize = 0,
        count: usize = 0,
    };

    pub const SelectState = enum {
        none,
        selecting,
    };
};

pub const Clip = struct {
    info: Info,
    memory: []u8,
    orderd: std.ArrayList(u32),

    pub const Info = struct { width: u32, height: u32, fps_num: u32, fps_den: u32 };

    pub fn frameSize(clip: *const Clip) usize {
        return clip.info.width * clip.info.height * 4;
    }
};

fn virtualIndex(self: *const Editor, clip: *const Clip) usize {
    const info = clip.info;
    return self.counter / (info.fps_num / info.fps_den) % clip.orderd.items.len;
}

fn playhead(self: *const Editor, clip: *const Clip) f32 {
    const virtual_index = self.virtualIndex(clip);
    return @as(f32, @floatFromInt(virtual_index)) / @as(f32, @floatFromInt(clip.orderd.items.len));
}

pub fn init(self: *Editor, gpa: std.mem.Allocator, window: *Window) !void {
    self.* = .{
        .ui = try Ui.init(gpa, window.size.width, window.size.height, Renderer.max_ui_quads),
        .vertices = try std.ArrayList(Renderer.UiVertex).initCapacity(gpa, Renderer.max_ui_quads * 4),
        .gpa = gpa,
        .box_select = .{ .region = undefined },
    };
}

pub fn deinit(self: *Editor, gpa: std.mem.Allocator) void {
    self.vertices.deinit(gpa);
    self.ui.deinit(gpa);
}

pub const Output = struct {
    ui_vertices: []const Renderer.UiVertex,
    frame_changed: bool = false,
    request_export: bool = false,
};
pub fn update(self: *Editor, window: *Window, clip: *Clip) !Output {
    const ui = &self.ui;
    if (self.playing) {
        self.counter += 1;
    }
    const virtual_index = self.virtualIndex(clip);
    self.index = clip.orderd.items[virtual_index];
    const frame_changed = self.previous_index != self.index;

    self.constructUi(window, &self.ui, clip);
    self.interactUi(window, ui, clip);

    self.vertices.clearRetainingCapacity();
    make(self.ui.quads, &self.vertices);

    if (window.keyboard.get(.space) == .press) self.playing = !self.playing;
    if (window.keyboard.get(.c) == .press) try clip.orderd.replaceRange(self.gpa, 0, virtual_index, &.{});
    if (window.keyboard.get(.d) == .press) try clip.orderd.replaceRange(self.gpa, virtual_index, clip.orderd.items.len - virtual_index, &.{});
    if (window.keyboard.get(.x) == .press) {
        try clip.orderd.replaceRange(self.gpa, self.box_select.frames.first, self.box_select.frames.count, &.{});
        self.box_select.frames = .{};
    }
    if (window.keyboard.get(.i) == .press) {
        var new_orderd: std.ArrayList(u32) = try .initCapacity(self.gpa, clip.orderd.items.len / 2);
        for (0..clip.orderd.items.len) |i| {
            if (i % 2 == 0) continue;
            new_orderd.appendAssumeCapacity(clip.orderd.items[i]);
        }
        clip.orderd.deinit(self.gpa);
        clip.orderd = new_orderd;
    }
    return .{
        .ui_vertices = self.vertices.items,
        .frame_changed = frame_changed,
        .request_export = window.keyboard.get(.e) == .press,
    };
}

fn constructUi(self: *Editor, window: *Window, ui: *Ui, clip: *const Clip) void {
    const window_ptr = window.pointer;
    const mouse_pos = window_ptr.movement.position;
    const region = &self.box_select.region;

    ui.start(.{
        .position = .{ .left = @floatCast(mouse_pos.x), .top = @floatCast(mouse_pos.y) },
        .left_click = window_ptr.buttons.left,
        .right_click = window_ptr.buttons.right,
    }, .{
        .delta_time = 0,
        .screen_size = .{
            .height = @floatFromInt(window.size.height),
            .width = @floatFromInt(window.size.width),
        },
    });

    ui.add(null, .{
        .name = "display",
        .size = .{
            .percent = .{ .height = 1, .width = 1 },
        },
        .child_anchor = .{ .x = .center, .y = .center },
    });

    ui.add("display", .{
        .size = .{ .percent = .{ .width = 1, .height = 0.5 } },
        .color = .new(1, 1, 1, 1),
        .texture = @intFromEnum(self.display_handle),
    });

    const timeline_h: f32 = 0.15;
    ui.add(null, .{
        .size = .{
            .percent = .{ .height = 1, .width = 1 },
        },
        .child_anchor = .{ .x = .start, .y = .end },
        .axis_align = .vertical,
        .children = &.{

        //     .{
        //     .size = .{ .percent = .{ .width = 1, .height = 0.1 } },
        //     .color = .new(0.5, 0.5, 0.5, 1),
        // },

        .{
            .name = "timeline",
            .size = .{
                .percent = .{ .width = 1, .height = timeline_h },
            },
            .color = .new(0.4, 0.4, 0.4, 1),
        }},
    });
    ui.add("timeline", .{
        .name = "display_frames",
        .size = .{ .percent = .{ .height = 1, .width = 1 } },
        .floating = true,
    });

    const len = clip.orderd.items.len;
    const slice_width = 1 / @as(f32, @floatFromInt(len));
    const selected = self.box_select.frames;
    for (0..len) |i| {
        const is_selected = i >= selected.first and i < selected.first + selected.count;
        ui.add("display_frames", .{
            .size = .{ .percent = .{ .height = 1, .width = slice_width } },
            .color = if (is_selected) .new(0, 0, 1, 0.5) else .new(1, 0.5, 0.5, 0.5),
        });
    }
    if (self.box_select.state == .selecting) {
        ui.add(null, .{
            .offset = .{ .left = region.left, .top = region.top },
            .size = .{ .fixed = .{ .width = region.width, .height = region.height } },
            .color = .new(0.1, 0.3, 1, 0.5),
        });
    }

    ui.add("timeline", .{ .size = .{
        .percent = .{ .width = self.playhead(clip), .height = 0 },
    } });
    ui.add("timeline", .{
        .name = "playhead",
        .size = .{ .percent = .{ .height = 1, .width = 0.01 } },
        .color = if (ui.isHovered("playhead")) .new(1, 1, 1, 1) else .new(1, 1, 1, 0.5),
        // .offset = .{ .left = ui.rect("timeline").left * clip.playhead(), .top = 0 },
    });

    ui.end();
}

fn interactUi(self: *Editor, window: *Window, ui: *Ui, clip: *const Clip) void {
    const pointer = window.pointer;
    const box_select = &self.box_select;

    if (ui.isDragging("timeline") or ui.isDragging("playhead")) {
        const tl = ui.rect("timeline");
        const info = clip.info;
        const new_playhead = std.math.clamp((ui.mouse_state.position.left - tl.left) / tl.width, 0, 1);
        self.counter = @as(usize, @intFromFloat(new_playhead * @as(f32, @floatFromInt(clip.orderd.items.len)))) * (info.fps_num / info.fps_den);
    }
    const timeline_rect = ui.rect("timeline");
    const mouse_position = ui.mouse_state.position;
    if (pointer.buttons.right and timeline_rect.contains(mouse_position)) {
        if (box_select.state == .none) {
            box_select.state = .selecting;
            box_select.region.left = mouse_position.left;
            box_select.region.top = mouse_position.top;
        } else {
            const region = &box_select.region;
            region.width = @as(f32, @floatCast(pointer.movement.position.x)) - region.left;
            region.height = @as(f32, @floatCast(pointer.movement.position.y)) - region.top;

            const frame_count: f32 = @floatFromInt(clip.orderd.items.len);
            const box_left = @min(region.left, region.left + region.width);
            const box_right = @max(region.left, region.left + region.width);
            const first_index: usize = @intFromFloat(std.math.clamp((box_left - timeline_rect.left) /
                timeline_rect.width, 0, 1) * frame_count);
            const last_index: usize = @intFromFloat(std.math.clamp((box_right - timeline_rect.left) /
                timeline_rect.width, 0, 1) * frame_count);
            box_select.frames = .{ .first = first_index, .count = last_index - first_index };
        }
    } else if (box_select.state == .selecting) box_select.state = .none;
}

fn make(quads: std.ArrayList(Ui.Quad), vertices: *std.ArrayList(Renderer.UiVertex)) void {
    for (quads.items) |quad| {
        const rect = quad.rect;
        const color = quad.color;
        vertices.appendSliceAssumeCapacity(&.{
            .{
                .color = color,
                .position = .{ rect.left, rect.top },
                .uv = .{ 0, 0 },
                .texture_id = quad.texture_handle,
            },
            .{
                .position = .{ rect.left + rect.width, rect.top },
                .color = color,
                .uv = .{ 1, 0 },
                .texture_id = quad.texture_handle,
            },
            .{
                .position = .{ rect.left + rect.width, rect.top + rect.height },
                .color = color,
                .uv = .{ 1, 1 },
                .texture_id = quad.texture_handle,
            },
            .{
                .position = .{ rect.left, rect.top + rect.height },
                .color = color,
                .uv = .{ 0, 1 },
                .texture_id = quad.texture_handle,
            },
        });
        // if (node.layout.text) |text| {
        //     const color = text.color.toVec();
        //     const font = self.default_font;
        //     const anchor = node.layout.child_anchor;
        //     const scale = text.size / font.size;
        //     const metrics = measureText(&font.glyphs, text.data, scale);
        //     var pen: struct {
        //         x: f32,
        //         y: f32,
        //     } = .{
        //         .x = node.rect.left + startOffset(anchor.x, node.rect.width, metrics.width, node.layout.padding),
        //         .y = node.rect.top + startOffset(anchor.y, node.rect.height, metrics.bottom - metrics.top, node.layout.padding) - metrics.top,
        //     };
        //     for (text.data) |char| {
        //         const index: usize = @intCast(std.math.clamp(@as(i32, char) - 32, 0, 95));
        //         const glyph = font.glyphs[index];
        //         const x0 = pen.x + glyph.xoff * scale;
        //         const y0 = pen.y + glyph.yoff * scale;
        //         const x1 = x0 + glyph.width * scale;
        //         const y1 = y0 + glyph.height * scale;
        //         self.quads.appendAssumeCapacity(.{ .vertices = .{
        //             .{ .position = .{ x0, y0 }, .color = color, .uv = .{ glyph.u0, glyph.v0 }, .is_sdf = 1, .texture_index = font.atlas_texture_index },
        //             .{ .position = .{ x1, y0 }, .color = color, .uv = .{ glyph.u1, glyph.v0 }, .is_sdf = 1, .texture_index = font.atlas_texture_index },
        //             .{ .position = .{ x1, y1 }, .color = color, .uv = .{ glyph.u1, glyph.v1 }, .is_sdf = 1, .texture_index = font.atlas_texture_index },
        //             .{ .position = .{ x0, y1 }, .color = color, .uv = .{ glyph.u0, glyph.v1 }, .is_sdf = 1, .texture_index = font.atlas_texture_index },
        //         } });
        //         pen.x += glyph.xadvance * scale;
        //     }
        // }
    }
}

pub fn getFrameData(self: *Editor, clip: *const Clip) TextureData {
    self.previous_index = self.index;
    return .{
        .height = clip.info.height,
        .width = clip.info.width,
        .bytes = clip.memory[self.index * clip.frameSize() ..][0..clip.frameSize()],
    };
}
