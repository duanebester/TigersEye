//! Card Components for TigersEye
//!
//! This module contains card-style UI components:
//! - BalanceCard: Card displaying posted/pending amounts

const gooey = @import("gooey");
const Cx = gooey.Cx;
const Color = gooey.Color;
const ui = gooey.ui;

const theme = @import("../core/theme.zig");
const format = @import("../tigerbeetle/format.zig");

// =============================================================================
// BalanceCard - Card displaying posted/pending amounts
// =============================================================================

pub const BalanceCard = struct {
    title: []const u8,
    posted: u128,
    pending: u128,
    color: Color,

    pub fn render(self: @This(), cx: *Cx) void {
        cx.render(ui.box(.{
            .grow = true,
            .padding = .{ .all = 16 },
            .background = theme.surface,
            .corner_radius = 6,
            .border_color = theme.border,
            .border_width = 1,
        }, .{
            ui.vstack(.{ .gap = 8 }, .{
                // Title with color dot
                ui.hstack(.{ .gap = 8, .alignment = .center }, .{
                    ui.box(.{
                        .width = 8,
                        .height = 8,
                        .corner_radius = 4,
                        .background = self.color,
                    }, .{}),
                    ui.text(self.title, .{
                        .size = 12,
                        .weight = .bold,
                        .color = theme.text,
                    }),
                }),
                // Posted amount
                ui.vstack(.{ .gap = 2 }, .{
                    ui.text("Posted", .{
                        .size = 10,
                        .color = theme.text_muted,
                    }),
                    ui.text(format.formatMoney(self.posted), .{
                        .size = 22,
                        .weight = .bold,
                        .color = theme.text,
                    }),
                }),
                // Pending amount
                ui.vstack(.{ .gap = 2 }, .{
                    ui.text("Pending", .{
                        .size = 10,
                        .color = theme.text_muted,
                    }),
                    ui.text(format.formatMoney(self.pending), .{
                        .size = 16,
                        .color = self.color,
                    }),
                }),
            }),
        }));
    }
};
