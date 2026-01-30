//! Account Details View for TigersEye
//!
//! This module contains the AccountDetails component for displaying
//! detailed information about a selected account.

const gooey = @import("gooey");
const Cx = gooey.Cx;
const ui = gooey.ui;

const theme = @import("../../core/theme.zig");
const state_mod = @import("../../core/state.zig");
const format = @import("../../tigerbeetle/format.zig");
const cards = @import("../../components/cards.zig");
const transfer_section = @import("../transfers/transfer_section.zig");
const transfer_history = @import("../transfers/transfer_history.zig");

const AppState = state_mod.AppState;
const Account = state_mod.Account;
const BalanceCard = cards.BalanceCard;
const TransferSection = transfer_section.TransferSection;
const TransferHistory = transfer_history.TransferHistory;

// =============================================================================
// Account Details
// =============================================================================

pub const AccountDetails = struct {
    account: ?*const Account,

    pub fn render(self: @This(), cx: *Cx) void {
        const s = cx.state(AppState);
        const account = self.account orelse return;
        const balance = account.balance();
        const balance_color = if (balance >= 0) theme.success else theme.danger;

        cx.render(ui.vstack(.{ .gap = 16 }, .{
            // Account Details Card - cleaner style
            ui.box(.{
                .fill_width = true,
                .padding = .{ .all = 20 },
                .background = theme.surface,
                .corner_radius = 6,
                .border_color = theme.border,
                .border_width = 1,
            }, .{
                ui.hstack(.{ .gap = 16, .alignment = .center }, .{
                    // Lime accent bar
                    ui.box(.{
                        .width = 3,
                        .height = 40,
                        .corner_radius = 2,
                        .background = theme.lime,
                    }, .{}),
                    ui.vstack(.{ .gap = 4 }, .{
                        ui.textFmt("Account {}", .{account.id}, .{
                            .size = 22,
                            .weight = .bold,
                            .color = theme.text,
                        }),
                        ui.textFmt("Ledger {} · Code {}", .{ account.ledger, account.code }, .{
                            .size = 12,
                            .color = theme.text_muted,
                        }),
                    }),
                }),
            }),

            // Current Balance Card - cleaner
            ui.box(.{
                .fill_width = true,
                .padding = .{ .all = 20 },
                .background = theme.surface,
                .corner_radius = 6,
                .border_color = theme.border,
                .border_width = 1,
            }, .{
                ui.vstack(.{ .gap = 6 }, .{
                    ui.text("Current Balance", .{
                        .size = 12,
                        .color = theme.text_muted,
                    }),
                    ui.text(format.formatBalance(balance), .{
                        .size = 42,
                        .weight = .bold,
                        .color = balance_color,
                    }),
                }),
            }),

            // Credits and Debits Cards Row
            ui.hstack(.{ .gap = 12 }, .{
                BalanceCard{
                    .title = "Credits",
                    .posted = account.credits_posted,
                    .pending = account.credits_pending,
                    .color = theme.mint,
                },
                BalanceCard{
                    .title = "Debits",
                    .posted = account.debits_posted,
                    .pending = account.debits_pending,
                    .color = theme.danger,
                },
            }),

            // Transfer section (if we have 2+ accounts)
            ui.when(s.account_count >= 2, .{
                TransferSection{},
            }),

            // Transfer History
            TransferHistory{ .account_id = account.id },
        }));
    }
};
