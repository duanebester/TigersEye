//! Main Panel Layout for TigersEye
//!
//! This module contains the main content area container which displays:
//! - Account details when an account is selected
//! - Empty state placeholder when no account is selected

const gooey = @import("gooey");
const Cx = gooey.Cx;
const ui = gooey.ui;
const Easing = gooey.Easing;

const theme = @import("../core/theme.zig");
const state_mod = @import("../core/state.zig");
const status = @import("../components/status.zig");
const account_details = @import("../features/accounts/account_details.zig");

const AppState = state_mod.AppState;
const Account = state_mod.Account;
const EmptyState = status.EmptyState;
const AccountDetails = account_details.AccountDetails;

// =============================================================================
// Main Panel
// =============================================================================

pub const MainPanel = struct {
    pub fn render(_: @This(), cx: *Cx) void {
        const s = cx.state(AppState);
        const g = cx.gooey();

        // Get selected account data from entity system
        const selected_account: ?*const Account = if (s.getSelectedAccountEntity()) |entity|
            g.readEntity(Account, entity)
        else
            null;

        // Animate fade-in when selected account changes
        const selected_id: u128 = if (selected_account) |acc| acc.id else 0;
        const fade = cx.animateOn("panel-fade", selected_id, .{
            .duration_ms = 200,
            .easing = Easing.easeOut,
        });

        cx.render(ui.box(.{
            .grow = true,
            .fill_height = true,
            .background = theme.bg,
        }, .{
            // Scrollable content when account is selected
            ui.when(selected_account != null, .{
                ui.scroll("main-panel-scroll", .{
                    .grow = true,
                    .fill_height = true,
                    .padding = .{ .all = 24 },
                    .gap = 16,
                    .track_color = theme.bg,
                    .thumb_color = theme.border_light,
                }, .{
                    ui.box(.{
                        .fill_width = true,
                        .opacity = fade.progress,
                    }, .{
                        AccountDetails{ .account = selected_account },
                    }),
                }),
            }),
            // Centered empty state when no account selected
            ui.when(selected_account == null, .{
                ui.box(.{
                    .grow = true,
                    .fill_width = true,
                    .fill_height = true,
                    .alignment = .{ .main = .center, .cross = .center },
                    .opacity = fade.progress,
                }, .{
                    EmptyState{
                        .title = "Select an Account",
                        .subtitle = "Choose an account from the sidebar to view details",
                    },
                }),
            }),
        }));
    }
};
