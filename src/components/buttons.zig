//! Button Components for TigersEye
//!
//! This module contains reusable button components:
//! - ButtonStyle: Enum for button styling variants
//! - CyberButton: Styled button with primary/secondary/danger variants
//! - IconButton: Small icon-only button

const gooey = @import("gooey");
const Cx = gooey.Cx;
const Color = gooey.Color;
const Svg = gooey.Svg;
const ui = gooey.ui;

const theme = @import("../core/theme.zig");

// =============================================================================
// Button Style Enum
// =============================================================================

pub const ButtonStyle = enum {
    primary,
    secondary,
    danger,
};

// =============================================================================
// CyberButton - Styled action button
// =============================================================================

pub const CyberButton = struct {
    label: []const u8,
    style: ButtonStyle = .primary,
    color: ?Color = null,
    enabled: bool = true,
    handler: ?gooey.context.handler.HandlerRef = null,
    small: bool = false,

    pub fn render(self: @This(), cx: *Cx) void {
        const padding_x: f32 = if (self.small) 12 else 16;
        const padding_y: f32 = if (self.small) 6 else 8;
        const font_size: u16 = if (self.small) 11 else 12;

        // Determine colors based on style
        const bg_color: Color = switch (self.style) {
            .primary => if (self.enabled) theme.lime else theme.lime.withAlpha(0.3),
            .secondary => if (self.enabled) theme.hover_bg else Color.transparent,
            .danger => if (self.enabled) theme.danger.withAlpha(0.15) else theme.danger.withAlpha(0.05),
        };

        const hover_bg: ?Color = if (!self.enabled) null else switch (self.style) {
            .primary => theme.lime.withAlpha(0.85),
            .secondary => theme.hover_bg.withAlpha(0.1),
            .danger => theme.danger.withAlpha(0.25),
        };

        const border_color: Color = switch (self.style) {
            .primary => Color.transparent,
            .secondary => if (self.enabled) theme.border_light else theme.border,
            .danger => if (self.enabled) theme.danger.withAlpha(0.6) else theme.danger.withAlpha(0.2),
        };

        const text_color: Color = if (self.color) |c| (if (self.enabled) c else c.withAlpha(0.4)) else switch (self.style) {
            .primary => if (self.enabled) theme.button_primary_text else theme.button_primary_text.withAlpha(0.5),
            .secondary => if (self.enabled) theme.text else theme.text_muted,
            .danger => if (self.enabled) theme.danger else theme.danger.withAlpha(0.4),
        };

        cx.render(ui.box(.{
            .padding = .{ .symmetric = .{ .x = padding_x, .y = padding_y } },
            .background = bg_color,
            .corner_radius = 6,
            .border_color = border_color,
            .border_width = 1,
            .alignment = .{ .main = .center, .cross = .center },
            .hover_background = hover_bg,
            .on_click_handler = if (self.enabled) self.handler else null,
        }, .{
            ui.text(self.label, .{
                .size = font_size,
                .weight = .bold,
                .color = text_color,
            }),
        }));
    }
};

// =============================================================================
// IconButton - Small icon-only button
// =============================================================================

pub const IconButton = struct {
    path: []const u8,
    color: Color = theme.text_muted,
    enabled: bool = true,
    handler: ?gooey.context.handler.HandlerRef = null,

    pub fn render(self: @This(), cx: *Cx) void {
        const final_color = if (self.enabled) self.color else self.color.withAlpha(0.4);

        cx.render(ui.box(.{
            .padding = .{ .all = 6 },
            .corner_radius = 4,
            .on_click_handler = if (self.enabled) self.handler else null,
            .hover_background = if (self.enabled) theme.hover_bg else null,
        }, .{
            Svg{
                .path = self.path,
                .size = 16,
                .color = final_color,
            },
        }));
    }
};
