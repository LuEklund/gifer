const Editor = @This();

const std = @import("std");
const Window = @import("Window.zig");
const Renderer = @import("Renderer.zig");
const Ui = @import("Ui.zig");

ui: Ui,
vertices: std.ArrayList(Renderer.UiVertex),

pub fn init(gpa: std.mem.Allocator, window: *Window) !Editor {
    return .{
        .ui = try Ui.init(gpa, window.size.width, window.size.height, Renderer.max_ui_quads),
        .vertices = try std.ArrayList(Renderer.UiVertex).initCapacity(gpa, Renderer.max_ui_quads * 4),
    };
}

pub fn deinit(self: *Editor, gpa: std.mem.Allocator) void {
    self.vertices.deinit(gpa);
    self.ui.deinit(gpa);
}

const Input = struct {
    display: Renderer.TextureHandle,
    playhead: f32,
};
pub const Output = struct {
    ui_vertices: []const Renderer.UiVertex,
    play: State,
    pub const State = union(enum) { none, toggle, playhead: f32 };
};
pub fn update(self: *Editor, window: *Window, input: Input) Output {
    const playehead = constructUi(window, &self.ui, input);
    self.vertices.clearRetainingCapacity();
    make(self.ui.quads, &self.vertices);

    var action: Output.State = if (window.keyboard.get(.space) == .press) .toggle else .none;
    if (playehead) |new_playhead| action = .{ .playhead = new_playhead };

    return .{ .ui_vertices = self.vertices.items, .play = action };
}

fn constructUi(window: *Window, ui: *Ui, inputs: Input) ?f32 {
    const window_ptr = window.pointer;
    const mouse_pos = window_ptr.movement.position;
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
        .color = .new(0.5, 0.5, 0.5, 1),
        .texture = @intFromEnum(inputs.display),
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

    ui.add("timeline", .{ .size = .{
        .percent = .{ .width = inputs.playhead, .height = 0 },
    } });
    ui.add("timeline", .{
        .name = "playhead",
        .size = .{ .percent = .{ .height = 1, .width = 0.01 } },
        .color = if (ui.isHovered("playhead")) .new(1, 1, 1, 1) else .new(1, 1, 1, 0.5),
    });

    ui.end();
    return if (ui.isDragging("timeline")) ui.mouse_state.position.left / ui.screen_height else null;
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
