//! Sidebar Layout for TigersEye
//!
//! This module contains the main sidebar container which includes:
//! - App header with branding
//! - Connection panel
//! - Account list panel

const gooey = @import("gooey");
const Cx = gooey.Cx;
const ui = gooey.ui;

const theme = @import("../core/theme.zig");
const connection_panel = @import("../features/connection/connection_panel.zig");
const account_list = @import("../features/accounts/account_list.zig");

const ConnectionPanel = connection_panel.ConnectionPanel;
const AccountListPanel = account_list.AccountListPanel;

// =============================================================================
// Sidebar Component
// =============================================================================

pub const Sidebar = struct {
    pub fn render(_: @This(), cx: *Cx) void {
        cx.render(ui.box(.{
            .width = theme.SIDEBAR_WIDTH,
            .fill_height = true,
            .background = theme.surface,
            .border_color = theme.border,
            .border_width = 1,
            .direction = .column,
            .gap = 0,
        }, .{
            // Header section - clean, minimal
            ui.box(.{
                .fill_width = true,
                .padding = .{ .symmetric = .{ .x = 20, .y = 24 } },
                .direction = .row,
                .gap = 12,
                .alignment = .{ .cross = .center },
            }, .{
                // Logo accent mark
                ui.box(.{
                    .width = 4,
                    .height = 32,
                    .corner_radius = 2,
                    .background = theme.lime,
                }, .{}),
                ui.vstack(.{ .gap = 2 }, .{
                    ui.text("TigerBeetle", .{
                        .size = 20,
                        .weight = .bold,
                        .color = theme.text,
                    }),
                    ui.text("Financial Database", .{
                        .size = 12,
                        .color = theme.text_muted,
                    }),
                }),
            }),
            ConnectionPanel{},
            AccountListPanel{},
        }));
    }
};
