//! Root Layout for TigersEye
//!
//! This module contains the root layout orchestration that combines
//! the sidebar and main panel into the application's top-level layout.

const gooey = @import("gooey");
const Cx = gooey.Cx;
const ui = gooey.ui;

const theme = @import("../core/theme.zig");
const sidebar = @import("sidebar.zig");
const main_panel = @import("main_panel.zig");

const Sidebar = sidebar.Sidebar;
const MainPanel = main_panel.MainPanel;

// =============================================================================
// Root Layout
// =============================================================================

pub fn render(cx: *Cx) void {
    const size = cx.windowSize();

    cx.render(ui.box(.{
        .width = size.width,
        .height = size.height,
        .background = theme.bg,
        .direction = .row,
    }, .{
        Sidebar{},
        MainPanel{},
    }));
}
