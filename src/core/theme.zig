//! TigersEye Theme - Color definitions and UI constants
//!
//! A cohesive dark theme inspired by TigerBeetle's branding.

const gooey = @import("gooey");
const Color = gooey.Color;

// =============================================================================
// Layout Constants
// =============================================================================

pub const SIDEBAR_WIDTH: f32 = 400.0;
pub const ACCOUNT_ROW_HEIGHT: f32 = 64.0;

// =============================================================================
// Color Theme
// =============================================================================

// Background colors
pub const bg = Color.rgb(0.0, 0.0, 0.0);
pub const surface = Color.rgb(0.02, 0.02, 0.02);
pub const surface_alt = Color.rgb(0.075, 0.078, 0.082);
pub const card = Color.rgba(0.075, 0.078, 0.082, 0.95);

// Border colors
pub const border = Color.rgb(0.192, 0.192, 0.192);
pub const border_light = Color.rgb(0.44, 0.44, 0.44);
pub const border_glow = Color.rgba(0.54, 0.91, 1.0, 0.2);

// Text colors
pub const text = Color.rgb(1.0, 1.0, 1.0);
pub const text_body = Color.rgba(1.0, 1.0, 1.0, 0.85);
pub const text_muted = Color.rgb(0.44, 0.44, 0.44);
pub const text_dim = Color.rgb(0.192, 0.192, 0.192);

// Accent colors - Cyan
pub const cyan = Color.rgb(0.54, 0.91, 1.0);
pub const cyan_dim = Color.rgba(0.54, 0.91, 1.0, 0.5);
pub const cyan_glow = Color.rgba(0.54, 0.91, 1.0, 0.15);

// Accent colors - Yellow
pub const yellow = Color.rgb(1.0, 0.937, 0.36);
pub const yellow_dim = Color.rgba(1.0, 0.937, 0.36, 0.5);

// Accent colors - Lime (TigerBeetle brand)
pub const lime = Color.rgb(0.769, 0.941, 0.259);
pub const lime_dim = Color.rgba(0.769, 0.941, 0.259, 0.5);

// Accent colors - Mint
pub const mint = Color.rgb(0.576, 0.992, 0.71);
pub const mint_dim = Color.rgba(0.576, 0.992, 0.71, 0.5);

// Accent colors - Purple
pub const purple = Color.rgb(0.62, 0.55, 0.988);
pub const purple_dim = Color.rgba(0.62, 0.55, 0.988, 0.5);

// Status colors - Danger
pub const danger = Color.rgb(0.945, 0.38, 0.325);
pub const danger_dim = Color.rgba(0.945, 0.38, 0.325, 0.3);

// Semantic aliases
pub const success = mint;
pub const success_dim = mint_dim;
pub const warning = yellow;
pub const warning_dim = yellow_dim;
pub const accent = cyan;
pub const primary = cyan;
pub const secondary = purple;
pub const magenta = purple;
pub const magenta_dim = purple_dim;

// Button colors
pub const button_primary_bg = lime;
pub const button_primary_text = Color.rgb(0.0, 0.0, 0.0);
pub const button_secondary_bg = Color.rgba(0.0, 0.0, 0.0, 0.0);
pub const button_secondary_border = border_light;

// Input colors
pub const input_bg = surface;
pub const input_border = border;
pub const input_focus_border = cyan;

// Interactive states
pub const selected_bg = Color.rgba(0.54, 0.91, 1.0, 0.1);
pub const hover_bg = Color.rgba(1.0, 1.0, 1.0, 0.05);
