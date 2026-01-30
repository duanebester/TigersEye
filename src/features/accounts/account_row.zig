//! Account Row Component for TigersEye
//!
//! This module contains the AccountRow component for displaying
//! individual accounts in the account list.

const gooey = @import("gooey");
const Cx = gooey.Cx;
const Color = gooey.Color;
const ui = gooey.ui;

const theme = @import("../../core/theme.zig");
const state_mod = @import("../../core/state.zig");
const format = @import("../../tigerbeetle/format.zig");

const AppState = state_mod.AppState;
const Account = state_mod.Account;

// =============================================================================
// Account Row
// =============================================================================

pub const AccountRow = struct {
    account: *const Account,
    index: u32,
    selected: bool,

    pub fn render(self: @This(), cx: *Cx) void {
        const bg = if (self.selected) theme.selected_bg else Color.transparent;
        const balance = self.account.balance();
        const balance_color = if (balance >= 0) theme.mint else theme.danger;

        cx.render(ui.box(.{
            .fill_width = true,
            .height = theme.ACCOUNT_ROW_HEIGHT - 4,
            .direction = .row,
            .hover_background = if (self.selected) null else theme.hover_bg,
            .on_click_handler = cx.updateWith(AppState, self.index, AppState.selectAccount),
        }, .{
            // Left accent bar (lime when selected, subtle)
            ui.box(.{
                .width = 2,
                .fill_height = true,
                .background = if (self.selected) theme.lime else Color.transparent,
            }, .{}),
            // Content
            ui.box(.{
                .grow = true,
                .fill_height = true,
                .padding = .{ .symmetric = .{ .x = 14, .y = 10 } },
                .background = bg,
                .direction = .row,
                .alignment = .{ .cross = .center },
            }, .{
                ui.vstack(.{ .gap = 2 }, .{
                    ui.textFmt("Account {}", .{self.account.shortId()}, .{
                        .size = 13,
                        .weight = .bold,
                        .color = if (self.selected) theme.text else theme.text_body,
                    }),
                    ui.textFmt("Ledger {} · Code {}", .{ self.account.ledger, self.account.code }, .{
                        .size = 11,
                        .color = theme.text_muted,
                    }),
                }),
                ui.spacer(),
                ui.text(format.formatBalance(balance), .{
                    .size = 14,
                    .weight = .bold,
                    .color = balance_color,
                }),
            }),
        }));
    }
};
