//! TigersEye - TigerbeetleDB GUI Client
//!
//! A beautiful GUI for managing TigerbeetleDB accounts and transfers.
//! Built with Gooey.
//!
//! Prerequisites:
//!   1. TigerBeetle server running: ./tigerbeetle start --addresses=3000 ./0_0.tigerbeetle
//!   2. libtb_client.dylib in vendor/tigerbeetle/lib/
//!
//! Run with: zig build run

const gooey = @import("gooey");
const platform = gooey.platform;

// Internal modules (new structure)
const state_mod = @import("core/state.zig");
const theme = @import("core/theme.zig");
const layout = @import("layout/root.zig");

// Re-export types for convenience
pub const AppState = state_mod.AppState;

// =============================================================================
// Global State
// =============================================================================

var state = AppState{};

// =============================================================================
// App Definition
// =============================================================================

const App = gooey.App(AppState, &state, layout.render, .{
    .title = "TigersEye",
    .width = 1200,
    .height = 800,
});

// =============================================================================
// Entry Point
// =============================================================================

pub fn main() !void {
    if (platform.is_wasm) unreachable;
    return App.main();
}
