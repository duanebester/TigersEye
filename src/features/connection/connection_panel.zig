//! Connection Panel for TigersEye
//!
//! This module contains the connection status and controls UI.

const gooey = @import("gooey");
const Cx = gooey.Cx;
const ui = gooey.ui;
const TextInput = gooey.TextInput;

const theme = @import("../../core/theme.zig");
const state_mod = @import("../../core/state.zig");
const tb_client = @import("../../tigerbeetle/client.zig");
const buttons = @import("../../components/buttons.zig");
const status = @import("../../components/status.zig");

const AppState = state_mod.AppState;
const CyberButton = buttons.CyberButton;
const StatusDot = status.StatusDot;

// =============================================================================
// Connection Panel
// =============================================================================

pub const ConnectionPanel = struct {
    pub fn render(_: @This(), cx: *Cx) void {
        const s = cx.state(AppState);

        cx.render(ui.box(.{
            .fill_width = true,
            .padding = .{ .symmetric = .{ .x = 20, .y = 16 } },
            // .background = theme.bg,
            .direction = .column,
            .gap = 16,
        }, .{
            // Server endpoint section - cleaner style
            ui.box(.{
                .fill_width = true,
                .direction = .column,
                .gap = 6,
            }, .{
                ui.text("Server", .{
                    .size = 11,
                    .color = theme.text_muted,
                }),
                TextInput{
                    .id = "server-address",
                    .placeholder = tb_client.DEFAULT_ADDRESS,
                    .bind = @constCast(&s.server_address),
                    .disabled = s.connection != .disconnected,
                    .fill_width = true,
                    .background = theme.surface,
                    .border_color = theme.border,
                    .corner_radius = 6,
                    .text_color = theme.text_body,
                    .placeholder_color = theme.text_muted,
                },
            }),
            // Status and action row
            ui.box(.{
                .fill_width = true,
                .direction = .row,
                .gap = 16,
                .alignment = .{ .cross = .center },
            }, .{
                StatusDot{ .color = s.connection.statusColor() },
                ui.text(s.connection.statusText(), .{
                    .size = 12,
                    .weight = .bold,
                    .color = s.connection.statusColor(),
                }),
                ui.spacer(),
                ui.when(s.connection == .disconnected, .{
                    CyberButton{
                        .label = "CONNECT",
                        .style = .primary,
                        .handler = cx.command(AppState, AppState.connect),
                    },
                }),
                ui.when(s.connection == .connecting or s.connection == .registering, .{
                    ui.text("Please wait...", .{
                        .size = 12,
                        .color = theme.text_muted,
                    }),
                }),
                ui.when(s.connection == .ready, .{
                    CyberButton{
                        .label = "DISCONNECT",
                        .style = .danger,
                        .handler = cx.command(AppState, AppState.disconnect),
                    },
                }),
            }),
            // Error display
            ui.when(s.last_error != null, .{
                ui.box(.{
                    .padding = .{ .all = 8 },
                    .background = theme.danger_dim,
                    .corner_radius = 4,
                }, .{
                    ui.text(s.last_error orelse "", .{ .size = 11, .color = theme.danger }),
                }),
            }),
            // Bottom divider
            ui.box(.{
                .fill_width = true,
                .height = 1,
                .background = theme.border,
            }, .{}),
        }));
    }
};
