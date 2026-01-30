//! Account List for TigersEye
//!
//! This module contains the account list UI components:
//! - AccountListPanel: Header with refresh/add buttons and account count
//! - AccountList: Scrollable list of accounts

const gooey = @import("gooey");
const Cx = gooey.Cx;
const Svg = gooey.Svg;
const ui = gooey.ui;

const theme = @import("../../core/theme.zig");
const state_mod = @import("../../core/state.zig");
const Icons = @import("../../components/icons.zig");
const buttons = @import("../../components/buttons.zig");
const account_row = @import("account_row.zig");

const AppState = state_mod.AppState;
const Account = state_mod.Account;
const IconButton = buttons.IconButton;
const AccountRow = account_row.AccountRow;

// =============================================================================
// Account List Panel
// =============================================================================

pub const AccountListPanel = struct {
    pub fn render(_: @This(), cx: *Cx) void {
        const s = cx.state(AppState);

        cx.render(ui.box(.{
            .grow = true,
            .fill_width = true,
            .padding = .{ .symmetric = .{ .x = 20, .y = 16 } },
            .direction = .column,
            .gap = 12,
        }, .{
            // Header with buttons - cleaner style
            ui.box(.{
                .fill_width = true,
                .direction = .row,
                .alignment = .{ .cross = .center },
                .gap = 8,
            }, .{
                ui.text("Accounts", .{
                    .size = 13,
                    .weight = .bold,
                    .color = theme.text,
                }),
                ui.spacer(),
                IconButton{
                    .path = Icons.refresh,
                    .color = theme.text_muted,
                    .enabled = s.canSubmit(),
                    .handler = cx.command(AppState, AppState.refreshAccounts),
                },
                IconButton{
                    .path = Icons.add,
                    .color = theme.text_muted,
                    .enabled = s.canSubmit(),
                    .handler = cx.command(AppState, AppState.createAccount),
                },
            }),
            // Registered count - simpler
            ui.textFmt("{} registered", .{s.account_count}, .{
                .size = 11,
                .color = theme.text_muted,
            }),
            // Account list
            AccountList{},
        }));
    }
};

// =============================================================================
// Account List
// =============================================================================

pub const AccountList = struct {
    pub fn render(_: @This(), cx: *Cx) void {
        const s = cx.state(AppState);

        if (s.account_count == 0) {
            cx.render(ui.box(.{
                .grow = true,
                .fill_width = true,
                .alignment = .{ .main = .center, .cross = .center },
            }, .{
                ui.vstack(.{ .gap = 12, .alignment = .center }, .{
                    Svg{ .path = Icons.wallet, .size = 28, .color = theme.border_light },
                    ui.text("No accounts yet", .{
                        .size = 13,
                        .color = theme.text_muted,
                    }),
                }),
            }));
            return;
        }

        cx.uniformList(
            "account-list",
            &s.list_state,
            .{
                .fill_width = true,
                .grow_height = true,
                .background = theme.bg,
                .corner_radius = 6,
                .padding = .{ .all = 4 },
                .gap = 2,
            },
            renderAccountItem,
        );
    }
};

fn renderAccountItem(index: u32, cx: *Cx) void {
    const s = cx.stateConst(AppState);
    const g = cx.gooey();

    if (index >= s.account_count) return;

    const entity = s.accounts[index];
    const account = g.readEntity(Account, entity) orelse return;
    const selected = if (s.selected_index) |sel| sel == index else false;

    cx.render(AccountRow{
        .account = account,
        .index = index,
        .selected = selected,
    });
}
