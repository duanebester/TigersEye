//! Transfer Section for TigersEye
//!
//! This module contains the TransferSection component for transferring
//! funds between accounts.

const gooey = @import("gooey");
const Cx = gooey.Cx;
const Svg = gooey.Svg;
const TextInput = gooey.TextInput;
const ui = gooey.ui;

const theme = @import("../../core/theme.zig");
const state_mod = @import("../../core/state.zig");
const Icons = @import("../../components/icons.zig");
const buttons = @import("../../components/buttons.zig");

const AppState = state_mod.AppState;
const CyberButton = buttons.CyberButton;

// =============================================================================
// Transfer Section
// =============================================================================

pub const TransferSection = struct {
    pub fn render(_: @This(), cx: *Cx) void {
        const s = cx.state(AppState);

        cx.render(ui.box(.{
            .fill_width = true,
            .padding = .{ .all = 20 },
            .background = theme.surface,
            .corner_radius = 6,
            .border_color = theme.border,
            .border_width = 1,
        }, .{
            ui.vstack(.{ .gap = 16 }, .{
                // Header - cleaner style
                ui.hstack(.{ .gap = 12, .alignment = .center }, .{
                    ui.box(.{
                        .width = 3,
                        .height = 20,
                        .corner_radius = 2,
                        .background = theme.purple,
                    }, .{}),
                    ui.text("Transfer Funds", .{
                        .size = 14,
                        .weight = .bold,
                        .color = theme.text,
                    }),
                }),
                ui.text("Route funds from Account 1 (reserve) to this account", .{
                    .size = 11,
                    .color = theme.text_muted,
                }),
                // Input row
                ui.hstack(.{ .gap = 12, .alignment = .center }, .{
                    ui.box(.{
                        .padding = .{ .symmetric = .{ .x = 12, .y = 10 } },
                        .background = theme.bg,
                        .corner_radius = 6,
                        .border_color = theme.border,
                        .border_width = 1,
                    }, .{
                        ui.hstack(.{ .gap = 8, .alignment = .center }, .{
                            ui.text("$", .{
                                .size = 14,
                                .color = theme.text_muted,
                            }),
                            TextInput{
                                .id = "transfer-amount",
                                .placeholder = "0.00",
                                .width = 100,
                                .background = theme.bg,
                                .border_width = 0,
                                .padding = 0,
                                .bind = @constCast(&s.transfer_amount),
                            },
                        }),
                    }),
                    CyberButton{
                        .label = "Transfer",
                        .style = .primary,
                        .enabled = s.canSubmit() and s.transfer_amount.len > 0,
                        .handler = cx.command(AppState, AppState.createTransfer),
                    },
                }),
                // Note - cleaner
                ui.text("Account 1 is the reserve. Select another account to receive funds.", .{
                    .size = 10,
                    .color = theme.text_muted,
                }),
                // Transfer status
                ui.when(s.transfer_success, .{
                    ui.hstack(.{ .gap = 8, .alignment = .center }, .{
                        Svg{ .path = Icons.check, .size = 14, .color = theme.success },
                        ui.text("Transfer successful!", .{
                            .size = 11,
                            .color = theme.success,
                        }),
                    }),
                }),
                ui.when(s.transfer_error_msg != null, .{
                    ui.text(s.transfer_error_msg orelse "", .{
                        .size = 11,
                        .color = theme.danger,
                    }),
                }),
            }),
        }));
    }
};
