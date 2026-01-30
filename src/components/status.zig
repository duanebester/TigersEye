//! Status Components for TigersEye
//!
//! This module contains status indicator components:
//! - StatusDot: Small colored status indicator
//! - EmptyState: Placeholder for empty content areas

const gooey = @import("gooey");
const Cx = gooey.Cx;
const Color = gooey.Color;
const Svg = gooey.Svg;
const ui = gooey.ui;

const theme = @import("../core/theme.zig");
const Icons = @import("icons.zig");

// =============================================================================
// StatusDot - Small colored status indicator
// =============================================================================

pub const StatusDot = struct {
    color: Color,

    pub fn render(self: @This(), cx: *Cx) void {
        cx.render(ui.box(.{
            .width = 8,
            .height = 8,
            .corner_radius = 4,
            .background = self.color,
        }, .{}));
    }
};

// =============================================================================
// EmptyState - Placeholder for empty content areas
// =============================================================================

pub const EmptyState = struct {
    title: []const u8,
    subtitle: []const u8,
    icon: []const u8 = Icons.database,

    pub fn render(self: @This(), cx: *Cx) void {
        cx.render(ui.box(.{
            .grow = true,
            .fill_width = true,
            .alignment = .{ .main = .center, .cross = .center },
        }, .{
            ui.vstack(.{ .gap = 16, .alignment = .center }, .{
                // Subtle icon
                Svg{ .path = self.icon, .size = 40, .color = theme.border_light },
                ui.vstack(.{ .gap = 6, .alignment = .center }, .{
                    ui.text(self.title, .{
                        .size = 16,
                        .weight = .bold,
                        .color = theme.text,
                    }),
                    ui.text(self.subtitle, .{
                        .size = 13,
                        .color = theme.text_muted,
                    }),
                }),
            }),
        }));
    }
};
