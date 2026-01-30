//! Transfer History for TigersEye
//!
//! This module contains the TransferHistory component for displaying
//! the transfer history of a selected account.

const std = @import("std");
const gooey = @import("gooey");
const Cx = gooey.Cx;
const Svg = gooey.Svg;
const ui = gooey.ui;

const theme = @import("../../core/theme.zig");
const state_mod = @import("../../core/state.zig");
const format = @import("../../tigerbeetle/format.zig");
const Icons = @import("../../components/icons.zig");
const buttons = @import("../../components/buttons.zig");

const AppState = state_mod.AppState;
const Transfer = state_mod.Transfer;
const IconButton = buttons.IconButton;

// =============================================================================
// Constants (per CLAUDE.md: "Put a limit on everything")
// =============================================================================

const MAX_VISIBLE_TRANSFERS: usize = 50;
const TRANSFER_ROW_HEIGHT: u32 = 48;

// =============================================================================
// Transfer History Section
// =============================================================================

pub const TransferHistory = struct {
    account_id: u128,

    pub fn render(self: @This(), cx: *Cx) void {
        const s = cx.state(AppState);

        // Check if we need to fetch history for this account
        const needs_fetch = s.transfer_history_account_id == null or
            s.transfer_history_account_id.? != self.account_id;

        cx.render(ui.box(.{
            .fill_width = true,
            .padding = .{ .all = 20 },
            .background = theme.surface,
            .corner_radius = 6,
            .border_color = theme.border,
            .border_width = 1,
        }, .{
            ui.vstack(.{ .gap = 16 }, .{
                // Header with refresh button
                ui.hstack(.{ .gap = 12, .alignment = .center }, .{
                    ui.box(.{
                        .width = 3,
                        .height = 20,
                        .corner_radius = 2,
                        .background = theme.cyan,
                    }, .{}),
                    ui.text("Transfer History", .{
                        .size = 14,
                        .weight = .bold,
                        .color = theme.text,
                    }),
                    IconButton{
                        .path = Icons.refresh,
                        .color = theme.text_muted,
                        .enabled = s.canSubmit(),
                        .handler = cx.command(AppState, AppState.refreshTransferHistory),
                    },
                    ui.spacer(),
                    ui.textFmt("{} transfers", .{s.transfer_history_count}, .{
                        .size = 11,
                        .color = theme.text_muted,
                    }),
                }),
                // Content based on state
                ui.when(needs_fetch, .{
                    // Prompt to load history
                    ui.box(.{
                        .fill_width = true,
                        .padding = .{ .all = 24 },
                        .alignment = .{ .main = .center, .cross = .center },
                    }, .{
                        ui.vstack(.{ .gap = 12, .alignment = .center }, .{
                            Svg{ .path = Icons.transfer, .size = 24, .color = theme.border_light },
                            ui.text("Click refresh to load transfer history", .{
                                .size = 12,
                                .color = theme.text_muted,
                            }),
                        }),
                    }),
                }),
                ui.when(!needs_fetch and s.transfer_history_count == 0, .{
                    // Empty state
                    ui.box(.{
                        .fill_width = true,
                        .padding = .{ .all = 24 },
                        .alignment = .{ .main = .center, .cross = .center },
                    }, .{
                        ui.vstack(.{ .gap = 12, .alignment = .center }, .{
                            Svg{ .path = Icons.transfer, .size = 24, .color = theme.border_light },
                            ui.text("No transfers yet", .{
                                .size = 12,
                                .color = theme.text_muted,
                            }),
                        }),
                    }),
                }),
                ui.when(!needs_fetch and s.transfer_history_count > 0, .{
                    // Transfer list
                    TransferList{ .account_id = self.account_id },
                }),
            }),
        }));
    }
};

// =============================================================================
// Transfer List
// =============================================================================

pub const TransferList = struct {
    account_id: u128,

    pub fn render(self: @This(), cx: *Cx) void {
        const s = cx.stateConst(AppState);

        const count = @min(s.transfer_history_count, MAX_VISIBLE_TRANSFERS);

        cx.render(ui.box(.{
            .fill_width = true,
            .background = theme.bg,
            .corner_radius = 4,
            .padding = .{ .all = 4 },
        }, .{
            ui.vstack(.{ .gap = 2 }, .{
                // Render up to MAX_VISIBLE_TRANSFERS rows inline
                // Each row checks if it should render based on count
                TransferRowRenderer{ .index = 0, .account_id = self.account_id, .count = count },
                TransferRowRenderer{ .index = 1, .account_id = self.account_id, .count = count },
                TransferRowRenderer{ .index = 2, .account_id = self.account_id, .count = count },
                TransferRowRenderer{ .index = 3, .account_id = self.account_id, .count = count },
                TransferRowRenderer{ .index = 4, .account_id = self.account_id, .count = count },
                TransferRowRenderer{ .index = 5, .account_id = self.account_id, .count = count },
                TransferRowRenderer{ .index = 6, .account_id = self.account_id, .count = count },
                TransferRowRenderer{ .index = 7, .account_id = self.account_id, .count = count },
                TransferRowRenderer{ .index = 8, .account_id = self.account_id, .count = count },
                TransferRowRenderer{ .index = 9, .account_id = self.account_id, .count = count },
                TransferRowRenderer{ .index = 10, .account_id = self.account_id, .count = count },
                TransferRowRenderer{ .index = 11, .account_id = self.account_id, .count = count },
                TransferRowRenderer{ .index = 12, .account_id = self.account_id, .count = count },
                TransferRowRenderer{ .index = 13, .account_id = self.account_id, .count = count },
                TransferRowRenderer{ .index = 14, .account_id = self.account_id, .count = count },
                TransferRowRenderer{ .index = 15, .account_id = self.account_id, .count = count },
                TransferRowRenderer{ .index = 16, .account_id = self.account_id, .count = count },
                TransferRowRenderer{ .index = 17, .account_id = self.account_id, .count = count },
                TransferRowRenderer{ .index = 18, .account_id = self.account_id, .count = count },
                TransferRowRenderer{ .index = 19, .account_id = self.account_id, .count = count },
            }),
        }));
    }
};

// =============================================================================
// Transfer Row Renderer (conditionally renders based on index < count)
// =============================================================================

const TransferRowRenderer = struct {
    index: usize,
    account_id: u128,
    count: usize,

    pub fn render(self: @This(), cx: *Cx) void {
        if (self.index >= self.count) return;

        const s = cx.stateConst(AppState);
        if (self.index >= s.transfer_history_count) return;

        const transfer = &s.transfer_history[self.index];
        const is_credit = transfer.isCreditTo(self.account_id);
        const direction_color = if (is_credit) theme.mint else theme.danger;
        const direction_symbol = if (is_credit) "+" else "-";
        const counterparty_id = if (is_credit) transfer.debit_account_id else transfer.credit_account_id;

        cx.render(TransferRow{
            .transfer = transfer,
            .is_credit = is_credit,
            .direction_color = direction_color,
            .direction_symbol = direction_symbol,
            .counterparty_id = counterparty_id,
        });
    }
};

// =============================================================================
// Transfer Row
// =============================================================================

pub const TransferRow = struct {
    transfer: *const Transfer,
    is_credit: bool,
    direction_color: gooey.Color,
    direction_symbol: []const u8,
    counterparty_id: u128,

    pub fn render(self: @This(), cx: *Cx) void {
        const transfer = self.transfer;

        cx.render(ui.box(.{
            .fill_width = true,
            .height = TRANSFER_ROW_HEIGHT,
            .padding = .{ .symmetric = .{ .x = 12, .y = 8 } },
            .background = theme.surface,
            .corner_radius = 4,
        }, .{
            ui.hstack(.{ .alignment = .center, .gap = 12 }, .{
                // Direction indicator
                ui.box(.{
                    .width = 32,
                    .height = 32,
                    .corner_radius = 16,
                    .background = self.direction_color.withAlpha(0.15),
                    .alignment = .{ .main = .center, .cross = .center },
                }, .{
                    Svg{
                        .path = if (self.is_credit) Icons.arrow_down else Icons.arrow_up,
                        .size = 16,
                        .color = self.direction_color,
                    },
                }),
                // Transfer details
                ui.vstack(.{ .gap = 2 }, .{
                    ui.hstack(.{ .gap = 6, .alignment = .center }, .{
                        ui.text(if (self.is_credit) "Received from" else "Sent to", .{
                            .size = 11,
                            .color = theme.text_muted,
                        }),
                        ui.textFmt("#{x:0>4}", .{@as(u16, @truncate(self.counterparty_id))}, .{
                            .size = 11,
                            .weight = .medium,
                            .color = theme.cyan,
                        }),
                    }),
                    ui.textFmt("Transfer #{x:0>4}", .{transfer.shortId()}, .{
                        .size = 10,
                        .color = theme.text_muted,
                    }),
                }),
                ui.spacer(),
                // Amount
                ui.vstack(.{ .gap = 2, .alignment = .end }, .{
                    ui.hstack(.{ .gap = 2, .alignment = .center }, .{
                        ui.text(self.direction_symbol, .{
                            .size = 14,
                            .weight = .bold,
                            .color = self.direction_color,
                        }),
                        ui.text(format.formatMoney(transfer.amount), .{
                            .size = 14,
                            .weight = .bold,
                            .color = self.direction_color,
                        }),
                    }),
                    // Pending indicator if applicable
                    ui.when(transfer.isPending(), .{
                        ui.text("PENDING", .{
                            .size = 9,
                            .weight = .bold,
                            .color = theme.yellow,
                        }),
                    }),
                }),
            }),
        }));
    }
};
