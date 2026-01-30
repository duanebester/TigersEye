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

const std = @import("std");
const log = std.log.scoped(.tigerseye);
const gooey = @import("gooey");
const platform = gooey.platform;
const tb = @import("tigerbeetle");

const Cx = gooey.Cx;
const Color = gooey.Color;
const UniformListState = gooey.UniformListState;

const TextInput = gooey.TextInput;
const Svg = gooey.Svg;
const ui = gooey.ui;

// Platform-specific dispatcher for thread-safe UI updates
const Dispatcher = platform.mac.dispatcher.Dispatcher;

// =============================================================================
// Constants (per CLAUDE.md: "Put a limit on everything")
// =============================================================================

const MAX_ACCOUNTS = 1024;
const PACKET_POOL_SIZE = 8;
const ACCOUNT_ROW_HEIGHT = 64.0;
const SIDEBAR_WIDTH = 400.0;
const DEFAULT_ADDRESS = "127.0.0.1:3000";

// Rate limiting for TigerBeetle IO thread synchronization
const MIN_CALLBACK_GAP_NS: i128 = 100_000_000; // 100ms
const SETTLE_DELAY_NS: u64 = 50_000_000; // 50ms

// Request routing tags (stored in packet.user_tag)
const REQUEST_TAG_QUERY_ACCOUNTS: u16 = 1;
const REQUEST_TAG_CREATE_ACCOUNTS: u16 = 2;
const REQUEST_TAG_CREATE_TRANSFERS: u16 = 3;

// Set to true to use echo client (for testing callbacks without a real TB server)
const USE_ECHO_CLIENT = false;

// =============================================================================
// Money Formatting (cents to dollars)
// =============================================================================

/// Multiple buffers for concurrent money formatting in same render pass.
/// We need at least 6 buffers: 2 for BalanceCard posted, 2 for pending, 1 for net balance, 1 for list items
const NUM_MONEY_BUFS = 8;
var money_bufs: [NUM_MONEY_BUFS][32]u8 = undefined;
var money_buf_idx: usize = 0;

fn formatMoney(cents: u128) []const u8 {
    const buf = &money_bufs[money_buf_idx];
    money_buf_idx = (money_buf_idx + 1) % NUM_MONEY_BUFS;

    const dollars = cents / 100;
    const remainder = cents % 100;
    const result = std.fmt.bufPrint(buf, "${}.{:0>2}", .{ dollars, remainder }) catch return "$0.00";
    return result;
}

fn formatBalance(cents: i128) []const u8 {
    const buf = &money_bufs[money_buf_idx];
    money_buf_idx = (money_buf_idx + 1) % NUM_MONEY_BUFS;

    const is_negative = cents < 0;
    const abs_cents: u128 = if (is_negative) @intCast(-cents) else @intCast(cents);
    const dollars = abs_cents / 100;
    const remainder = abs_cents % 100;
    const result = if (is_negative)
        std.fmt.bufPrint(buf, "-${}.{:0>2}", .{ dollars, remainder }) catch return "$0.00"
    else
        std.fmt.bufPrint(buf, "${}.{:0>2}", .{ dollars, remainder }) catch return "$0.00";
    return result;
}

/// Parse a dollar amount string (e.g., "20", "20.00", "20.5") to cents
fn parseDollarsToCents(input: []const u8) ?u128 {
    if (input.len == 0) return null;

    // Find decimal point
    var decimal_pos: ?usize = null;
    for (input, 0..) |c, i| {
        if (c == '.') {
            decimal_pos = i;
            break;
        }
    }

    if (decimal_pos) |pos| {
        // Has decimal point - parse dollars and cents separately
        const dollars_str = input[0..pos];
        const cents_str = input[pos + 1 ..];

        const dollars = std.fmt.parseInt(u128, dollars_str, 10) catch return null;

        // Handle cents - pad or truncate to 2 digits
        var cents: u128 = 0;
        if (cents_str.len > 0) {
            if (cents_str.len == 1) {
                // "20.5" -> 50 cents
                cents = (std.fmt.parseInt(u128, cents_str, 10) catch return null) * 10;
            } else if (cents_str.len == 2) {
                // "20.05" or "20.50" -> as-is
                cents = std.fmt.parseInt(u128, cents_str, 10) catch return null;
            } else {
                // "20.123" -> take first 2 digits
                cents = std.fmt.parseInt(u128, cents_str[0..2], 10) catch return null;
            }
        }

        return dollars * 100 + cents;
    } else {
        // No decimal point - treat as whole dollars
        const dollars = std.fmt.parseInt(u128, input, 10) catch return null;
        return dollars * 100;
    }
}

// =============================================================================
// Connection State Machine (Phase 1 Refactoring)
// =============================================================================

/// Single source of truth for connection lifecycle.
/// Replaces scattered booleans (connected, connecting, registered).
const ConnectionState = enum {
    disconnected, // No connection
    connecting, // TB client init in progress
    registering, // Waiting for TB registration callback
    ready, // Connected and idle, can submit requests

    pub fn canSubmit(self: ConnectionState) bool {
        return self == .ready;
    }

    pub fn isConnected(self: ConnectionState) bool {
        return self == .ready;
    }

    pub fn statusText(self: ConnectionState) []const u8 {
        return switch (self) {
            .disconnected => "OFFLINE",
            .connecting => "CONNECTING...",
            .registering => "REGISTERING...",
            .ready => "ONLINE",
        };
    }

    pub fn statusColor(self: ConnectionState) Color {
        return switch (self) {
            .disconnected => theme.text_dim,
            .connecting, .registering => theme.warning,
            .ready => theme.success,
        };
    }
};

// =============================================================================
// Operation Tracking (Phase 1 Refactoring)
// =============================================================================

/// Tracks which operation type is in flight with its context.
const Operation = union(enum) {
    none,
    query_accounts,
    create_account: CreateAccountCtx,
    create_transfer: CreateTransferCtx,

    const CreateAccountCtx = struct {
        account_id: u128,
    };

    const CreateTransferCtx = struct {
        amount: u128,
    };

    pub fn isActive(self: Operation) bool {
        return self != .none;
    }

    pub fn name(self: Operation) []const u8 {
        return switch (self) {
            .none => "none",
            .query_accounts => "query_accounts",
            .create_account => "create_account",
            .create_transfer => "create_transfer",
        };
    }
};

// =============================================================================
// Operation Result (Phase 3 Refactoring)
// =============================================================================

/// Result delivered from TB IO thread to main thread.
/// Bundles the operation outcome for clean dispatch handling.
const OperationResult = union(enum) {
    query_accounts: QueryResult,
    create_account: CreateResult,
    create_transfer: CreateResult,

    const QueryResult = struct {
        count: usize,
    };

    const CreateResult = struct {
        success: bool,
        error_msg: ?[]const u8,
    };

    pub fn name(self: OperationResult) []const u8 {
        return switch (self) {
            .query_accounts => "query_accounts",
            .create_account => "create_account",
            .create_transfer => "create_transfer",
        };
    }
};

// =============================================================================
// Account Entity (Phase 4: UI-friendly account representation)
// =============================================================================

/// UI-friendly account representation for the Entity system.
/// Wraps TigerBeetle account data with convenient methods.
const Account = struct {
    id: u128,
    ledger: u32,
    code: u16,
    debits_pending: u128,
    debits_posted: u128,
    credits_pending: u128,
    credits_posted: u128,
    timestamp: u64,

    /// Create an Account from a TigerBeetle account
    pub fn fromTB(tb_acc: tb.Account) Account {
        return .{
            .id = tb_acc.id,
            .ledger = tb_acc.ledger,
            .code = tb_acc.code,
            .debits_pending = tb_acc.debits_pending,
            .debits_posted = tb_acc.debits_posted,
            .credits_pending = tb_acc.credits_pending,
            .credits_posted = tb_acc.credits_posted,
            .timestamp = tb_acc.timestamp,
        };
    }

    /// Calculate net balance (credits - debits)
    pub fn balance(self: Account) i128 {
        const credits: i128 = @intCast(self.credits_posted);
        const debits: i128 = @intCast(self.debits_posted);
        return credits - debits;
    }

    /// Get last 64 bits of account ID for display (shows as ~20 digit decimal)
    pub fn shortId(self: Account) u64 {
        return @truncate(self.id);
    }
};

// =============================================================================
// Theme - Based on tigerbeetle.com CSS tokens
// =============================================================================

const theme = struct {
    // Backgrounds - Pure black base
    pub const bg = Color.rgb(0.0, 0.0, 0.0); // #000000 - main background
    pub const surface = Color.rgb(0.02, 0.02, 0.02); // #050505 - cards/panels
    pub const surface_alt = Color.rgb(0.075, 0.078, 0.082); // #131415 - elevated surfaces
    pub const card = Color.rgba(0.075, 0.078, 0.082, 0.95);

    // Borders - Subtle grays
    pub const border = Color.rgb(0.192, 0.192, 0.192); // #313131
    pub const border_light = Color.rgb(0.44, 0.44, 0.44); // #707070
    pub const border_glow = Color.rgba(0.54, 0.91, 1.0, 0.2); // subtle cyan glow

    // Text - White hierarchy
    pub const text = Color.rgb(1.0, 1.0, 1.0); // #ffffff - headings
    pub const text_body = Color.rgba(1.0, 1.0, 1.0, 0.85); // #ffffffd9 - body text
    pub const text_muted = Color.rgb(0.44, 0.44, 0.44); // #707070 - muted
    pub const text_dim = Color.rgb(0.192, 0.192, 0.192); // #313131 - very dim

    // Accent Colors - Official TigerBeetle palette
    pub const cyan = Color.rgb(0.54, 0.91, 1.0); // #8ae8ff
    pub const cyan_dim = Color.rgba(0.54, 0.91, 1.0, 0.5);
    pub const cyan_glow = Color.rgba(0.54, 0.91, 1.0, 0.15);

    pub const yellow = Color.rgb(1.0, 0.937, 0.36); // #ffef5c
    pub const yellow_dim = Color.rgba(1.0, 0.937, 0.36, 0.5);

    pub const lime = Color.rgb(0.769, 0.941, 0.259); // #c4f042
    pub const lime_dim = Color.rgba(0.769, 0.941, 0.259, 0.5);

    pub const mint = Color.rgb(0.576, 0.992, 0.71); // #93fdb5
    pub const mint_dim = Color.rgba(0.576, 0.992, 0.71, 0.5);

    pub const purple = Color.rgb(0.62, 0.55, 0.988); // #9e8cfc
    pub const purple_dim = Color.rgba(0.62, 0.55, 0.988, 0.5);

    pub const danger = Color.rgb(0.945, 0.38, 0.325); // #f16153
    pub const danger_dim = Color.rgba(0.945, 0.38, 0.325, 0.3);

    // Semantic Aliases
    pub const success = mint;
    pub const success_dim = mint_dim;
    pub const warning = yellow;
    pub const warning_dim = yellow_dim;
    pub const accent = cyan;
    pub const primary = cyan;
    pub const secondary = purple;
    pub const magenta = purple;
    pub const magenta_dim = purple_dim;

    // Component-specific colors
    pub const button_primary_bg = lime;
    pub const button_primary_text = Color.rgb(0.0, 0.0, 0.0);
    pub const button_secondary_bg = Color.rgba(0.0, 0.0, 0.0, 0.0);
    pub const button_secondary_border = border_light;

    pub const input_bg = surface;
    pub const input_border = border;
    pub const input_focus_border = cyan;

    pub const selected_bg = Color.rgba(0.54, 0.91, 1.0, 0.1);
    pub const hover_bg = Color.rgba(1.0, 1.0, 1.0, 0.05);
};

// =============================================================================
// SVG Icon Paths (Material Design style)
// =============================================================================

const Icons = struct {
    pub const database = "M12 3C7.58 3 4 4.79 4 7v10c0 2.21 3.58 4 8 4s8-1.79 8-4V7c0-2.21-3.58-4-8-4zm0 2c3.87 0 6 1.5 6 2s-2.13 2-6 2-6-1.5-6-2 2.13-2 6-2zm6 12c0 .5-2.13 2-6 2s-6-1.5-6-2v-2.23c1.61.78 3.72 1.23 6 1.23s4.39-.45 6-1.23V17zm0-5c0 .5-2.13 2-6 2s-6-1.5-6-2V9.77c1.61.78 3.72 1.23 6 1.23s4.39-.45 6-1.23V12z";
    pub const wallet = "M21 18v1c0 1.1-.9 2-2 2H5c-1.11 0-2-.9-2-2V5c0-1.1.89-2 2-2h14c1.1 0 2 .9 2 2v1h-9c-1.11 0-2 .9-2 2v8c0 1.1.89 2 2 2h9zm-9-2h10V8H12v8zm4-2.5c-.83 0-1.5-.67-1.5-1.5s.67-1.5 1.5-1.5 1.5.67 1.5 1.5-.67 1.5-1.5 1.5z";
    pub const transfer = "M6.99 11L3 15l3.99 4v-3H14v-2H6.99v-3zM21 9l-3.99-4v3H10v2h7.01v3L21 9z";
    pub const add = "M19 13h-6v6h-2v-6H5v-2h6V5h2v6h6v2z";
    pub const refresh = "M12 4V1L8 5l4 4V6c3.31 0 6 2.69 6 6 0 1.01-.25 1.97-.7 2.8l1.46 1.46C19.54 15.03 20 13.57 20 12c0-4.42-3.58-8-8-8zm0 14c-3.31 0-6-2.69-6-6 0-1.01.25-1.97.7-2.8L5.24 7.74C4.46 8.97 4 10.43 4 12c0 4.42 3.58 8 8 8v3l4-4-4-4v3z";
    pub const check = "M9 16.17L4.83 12l-1.42 1.41L9 19 21 7l-1.41-1.41z";
    pub const warning_icon = "M1 21h22L12 2 1 21zm12-3h-2v-2h2v2zm0-4h-2v-4h2v4z";
    pub const link = "M3.9 12c0-1.71 1.39-3.1 3.1-3.1h4V7H7c-2.76 0-5 2.24-5 5s2.24 5 5 5h4v-1.9H7c-1.71 0-3.1-1.39-3.1-3.1zM8 13h8v-2H8v2zm9-6h-4v1.9h4c1.71 0 3.1 1.39 3.1 3.1s-1.39 3.1-3.1 3.1h-4V17h4c2.76 0 5-2.24 5-5s-2.24-5-5-5z";
    pub const unlink = "M17 7h-4v1.9h4c1.71 0 3.1 1.39 3.1 3.1 0 1.43-.98 2.63-2.31 2.98l1.46 1.46C20.88 15.61 22 13.95 22 12c0-2.76-2.24-5-5-5zm-1 4h-2.19l2 2H16v-2zM2 4.27l3.11 3.11C3.29 8.12 2 9.91 2 12c0 2.76 2.24 5 5 5h4v-1.9H7c-1.71 0-3.1-1.39-3.1-3.1 0-1.59 1.21-2.9 2.76-3.07L8.73 11H8v2h2.73L13 15.27V17h1.73l4.01 4L20 19.74 3.27 3 2 4.27z";
    pub const clock = "M11.99 2C6.47 2 2 6.48 2 12s4.47 10 9.99 10C17.52 22 22 17.52 22 12S17.52 2 11.99 2zM12 20c-4.42 0-8-3.58-8-8s3.58-8 8-8 8 3.58 8 8-3.58 8-8 8zm.5-13H11v6l5.25 3.15.75-1.23-4.5-2.67V7z";
    pub const info = "M12 2C6.48 2 2 6.48 2 12s4.48 10 10 10 10-4.48 10-10S17.52 2 12 2zm1 15h-2v-6h2v6zm0-8h-2V7h2v2z";
    pub const error_icon = "M12 2C6.48 2 2 6.48 2 12s4.48 10 10 10 10-4.48 10-10S17.52 2 12 2zm1 15h-2v-2h2v2zm0-4h-2V7h2v6z";
};

// =============================================================================
// Custom Button Components
// =============================================================================

/// Button style variants matching TigerBeetle website
const ButtonStyle = enum {
    primary, // Lime/green bg, black text (CTAs)
    secondary, // Transparent, border only
    danger, // Red accent for destructive actions
};

const CyberButton = struct {
    label: []const u8,
    style: ButtonStyle = .secondary,
    color: ?Color = null, // Override color (for backward compat)
    enabled: bool = true,
    handler: ?gooey.context.handler.HandlerRef = null,
    small: bool = false,

    pub fn render(self: @This(), cx: *Cx) void {
        const padding_x: f32 = if (self.small) 12 else 16;
        const padding_y: f32 = if (self.small) 6 else 8;
        const font_size: u16 = if (self.small) 11 else 12;

        // Determine colors based on style
        const bg_color: Color = switch (self.style) {
            .primary => if (self.enabled) theme.lime else theme.lime.withAlpha(0.3),
            .secondary => if (self.enabled) theme.hover_bg else Color.transparent,
            .danger => if (self.enabled) theme.danger.withAlpha(0.15) else theme.danger.withAlpha(0.05),
        };

        const hover_bg: ?Color = if (!self.enabled) null else switch (self.style) {
            .primary => theme.lime.withAlpha(0.85),
            .secondary => theme.hover_bg.withAlpha(0.1),
            .danger => theme.danger.withAlpha(0.25),
        };

        const border_color: Color = switch (self.style) {
            .primary => Color.transparent,
            .secondary => if (self.enabled) theme.border_light else theme.border,
            .danger => if (self.enabled) theme.danger.withAlpha(0.6) else theme.danger.withAlpha(0.2),
        };

        const text_color: Color = if (self.color) |c| (if (self.enabled) c else c.withAlpha(0.4)) else switch (self.style) {
            .primary => if (self.enabled) theme.button_primary_text else theme.button_primary_text.withAlpha(0.5),
            .secondary => if (self.enabled) theme.text else theme.text_muted,
            .danger => if (self.enabled) theme.danger else theme.danger.withAlpha(0.4),
        };

        cx.render(ui.box(.{
            .padding = .{ .symmetric = .{ .x = padding_x, .y = padding_y } },
            .background = bg_color,
            .corner_radius = 6, // Website uses 6px
            .border_color = border_color,
            .border_width = 1,
            .alignment = .{ .main = .center, .cross = .center },
            .hover_background = hover_bg,
            .on_click_handler = if (self.enabled) self.handler else null,
        }, .{
            ui.text(self.label, .{
                .size = font_size,
                .weight = .bold,
                .color = text_color,
            }),
        }));
    }
};

const IconButton = struct {
    path: []const u8,
    color: Color = theme.text_muted,
    enabled: bool = true,
    handler: ?gooey.context.handler.HandlerRef = null,

    pub fn render(self: @This(), cx: *Cx) void {
        const icon_color = if (self.enabled) self.color else self.color.withAlpha(0.4);

        cx.render(ui.box(.{
            .width = 28,
            .height = 28,
            .background = Color.transparent,
            .corner_radius = 6,
            .border_color = Color.transparent,
            .border_width = 0,
            .alignment = .{ .main = .center, .cross = .center },
            .hover_background = if (self.enabled) theme.hover_bg else null,
            .on_click_handler = if (self.enabled) self.handler else null,
        }, .{
            Svg{
                .path = self.path,
                .size = 16,
                .color = icon_color,
            },
        }));
    }
};

// =============================================================================
// Packet Pool - Static allocation for TigerBeetle packets
// =============================================================================

const PacketPool = struct {
    const Self = @This();

    packets: [PACKET_POOL_SIZE]tb.Packet = [_]tb.Packet{tb.Packet.init()} ** PACKET_POOL_SIZE,
    in_use: [PACKET_POOL_SIZE]std.atomic.Value(bool) = [_]std.atomic.Value(bool){std.atomic.Value(bool).init(false)} ** PACKET_POOL_SIZE,
    next_index: usize = 0,

    pub fn acquire(self: *Self) ?*tb.Packet {
        // Assertion: pool capacity check
        std.debug.assert(PACKET_POOL_SIZE > 0);

        var attempts: usize = 0;
        while (attempts < PACKET_POOL_SIZE) : (attempts += 1) {
            const i = (self.next_index + attempts) % PACKET_POOL_SIZE;
            const used = &self.in_use[i];

            if (used.cmpxchgStrong(false, true, .acquire, .monotonic) == null) {
                self.packets[i] = tb.Packet.init();
                self.next_index = (i + 1) % PACKET_POOL_SIZE;
                return &self.packets[i];
            }
        }
        log.warn("No packets available in pool", .{});
        return null;
    }

    pub fn release(self: *Self, packet: *tb.Packet) void {
        const base = @intFromPtr(&self.packets[0]);
        const ptr = @intFromPtr(packet);
        const packet_size = @sizeOf(tb.Packet);

        // Assertion: packet belongs to this pool
        std.debug.assert(ptr >= base and ptr < base + PACKET_POOL_SIZE * packet_size);

        if (ptr >= base and ptr < base + PACKET_POOL_SIZE * packet_size) {
            const index = (ptr - base) / packet_size;
            if (index < PACKET_POOL_SIZE) {
                self.in_use[index].store(false, .release);
                return;
            }
        }
        log.warn("Tried to release unknown packet at 0x{x}", .{ptr});
    }

    pub fn availableCount(self: *const Self) usize {
        var count: usize = 0;
        for (&self.in_use) |*used| {
            if (!used.load(.acquire)) count += 1;
        }
        return count;
    }

    pub fn reset(self: *Self) void {
        for (&self.in_use) |*used| {
            used.store(false, .release);
        }
        for (&self.packets) |*pkt| {
            pkt.* = tb.Packet.init();
        }
    }
};

// =============================================================================
// TigerBeetle Log Callback
// =============================================================================

fn tbLogCallback(level: tb.LogLevel, msg_ptr: [*]const u8, msg_len: u32) callconv(.c) void {
    const msg = msg_ptr[0..msg_len];
    const level_str = switch (level) {
        .err => "ERROR",
        .warn => "WARN",
        .info => "INFO",
        .debug => "DEBUG",
    };
    log.debug("[TB-{s}] {s}", .{ level_str, msg });
}

// =============================================================================
// TigerBeetle Completion Callback (called on IO thread)
// =============================================================================

fn tbCompletionCallback(
    context: usize,
    packet: *tb.Packet,
    timestamp: u64,
    result_ptr: ?[*]const u8,
    result_len: u32,
) callconv(.c) void {
    _ = timestamp;
    const self: *AppState = @ptrFromInt(context);
    defer self.packet_pool.release(packet);

    // Update rate limit timestamp
    self.last_callback_timestamp_ns.store(std.time.nanoTimestamp(), .release);

    // Update sequence tracking
    const seq = self.request_sequence.load(.acquire);
    self.last_completed_sequence.store(seq, .release);

    // Parse result based on operation tag
    const tag = packet.user_tag;
    const status = packet.getStatus();

    log.debug("TB callback: tag={}, status={}, result_len={}", .{ tag, status, result_len });

    // Handle status errors uniformly
    if (status != .ok) {
        log.err("TB operation failed: status={}", .{status});
        const error_msg: []const u8 = switch (status) {
            .ok => "OK",
            .too_much_data => "Too much data",
            .client_evicted => "Client evicted",
            .client_release_too_low => "Client release too low",
            .client_release_too_high => "Client release too high",
            .client_shutdown => "Client shutdown",
            .invalid_operation => "Invalid operation",
            .invalid_data_size => "Invalid data size",
            _ => "Unknown error",
        };

        // Create error result based on current operation tag
        self.pending_result = switch (tag) {
            REQUEST_TAG_QUERY_ACCOUNTS => .{ .query_accounts = .{ .count = 0 } },
            REQUEST_TAG_CREATE_ACCOUNTS => .{ .create_account = .{ .success = false, .error_msg = error_msg } },
            REQUEST_TAG_CREATE_TRANSFERS => .{ .create_transfer = .{ .success = false, .error_msg = error_msg } },
            else => null,
        };
        self.dispatchToMain();
        return;
    }

    // Parse result based on request type and create OperationResult
    const result: OperationResult = switch (tag) {
        REQUEST_TAG_QUERY_ACCOUNTS => blk: {
            if (result_ptr) |ptr| {
                const accounts = tb.parseAccounts(ptr, result_len);
                const count = @min(accounts.len, MAX_ACCOUNTS);

                // Copy to pending buffer (result_ptr only valid during callback)
                @memcpy(self.pending_accounts[0..count], accounts[0..count]);
                self.pending_account_count = count;

                log.info("Query returned {} accounts", .{count});
                break :blk .{ .query_accounts = .{ .count = count } };
            } else {
                self.pending_account_count = 0;
                log.info("Query returned no accounts", .{});
                break :blk .{ .query_accounts = .{ .count = 0 } };
            }
        },
        REQUEST_TAG_CREATE_ACCOUNTS => blk: {
            const results = tb.parseCreateAccountsResults(result_ptr, result_len);
            if (results.len == 0) {
                // Success - no errors means all accounts created
                log.info("Account created successfully", .{});
                break :blk .{ .create_account = .{ .success = true, .error_msg = null } };
            } else {
                // Some accounts failed
                const error_msg = accountErrorMessage(results[0].result);
                log.err("Account creation failed: {}", .{results[0].result});
                break :blk .{ .create_account = .{ .success = false, .error_msg = error_msg } };
            }
        },
        REQUEST_TAG_CREATE_TRANSFERS => blk: {
            const results = tb.parseCreateTransfersResults(result_ptr, result_len);
            if (results.len == 0) {
                // Success
                log.info("Transfer created successfully", .{});
                break :blk .{ .create_transfer = .{ .success = true, .error_msg = null } };
            } else {
                const error_msg = transferErrorMessage(results[0].result);
                log.err("Transfer creation failed: {}", .{results[0].result});
                break :blk .{ .create_transfer = .{ .success = false, .error_msg = error_msg } };
            }
        },
        else => {
            log.warn("Unknown request tag: {}", .{tag});
            return;
        },
    };

    // Store result and dispatch to main thread
    self.pending_result = result;
    self.dispatchToMain();
}

// =============================================================================
// Error Message Helpers
// =============================================================================

fn accountErrorMessage(result: tb.CreateAccountResult) []const u8 {
    return switch (result) {
        .ok => "Success",
        .linked_event_failed => "Linked event in batch failed",
        .linked_event_chain_open => "Linked event chain not closed",
        .timestamp_must_be_zero => "Timestamp must be zero",
        .reserved_field => "Reserved field must be zero",
        .reserved_flag => "Reserved flag must not be set",
        .id_must_not_be_zero => "Account ID cannot be zero",
        .id_must_not_be_int_max => "Account ID cannot be max value",
        .flags_are_mutually_exclusive => "Account flags are mutually exclusive",
        .debits_pending_must_be_zero => "Debits pending must be zero",
        .debits_posted_must_be_zero => "Debits posted must be zero",
        .credits_pending_must_be_zero => "Credits pending must be zero",
        .credits_posted_must_be_zero => "Credits posted must be zero",
        .ledger_must_not_be_zero => "Ledger must be specified",
        .code_must_not_be_zero => "Account code must be specified",
        .exists_with_different_flags => "Account exists with different flags",
        .exists => "Account already exists",
        else => "Unknown error",
    };
}

fn transferErrorMessage(result: tb.CreateTransferResult) []const u8 {
    return switch (result) {
        .ok => "Success",
        .linked_event_failed => "Linked event in batch failed",
        .debit_account_not_found => "Debit account not found",
        .credit_account_not_found => "Credit account not found",
        .accounts_must_be_different => "Accounts must be different",
        .accounts_must_have_the_same_ledger => "Accounts must have same ledger",
        .exceeds_credits => "Exceeds available credits",
        .exceeds_debits => "Exceeds available debits",
        .exists => "Transfer already exists",
        else => "Unknown error",
    };
}

// =============================================================================
// AppState
// =============================================================================

const AppState = struct {
    // =========================================================================
    // Connection State (Phase 1: single source of truth)
    // =========================================================================
    connection: ConnectionState = .disconnected,
    current_op: Operation = .none,

    // =========================================================================
    // Error Handling
    // =========================================================================
    last_error: ?[]const u8 = null,

    // =========================================================================
    // TigerBeetle Client
    // =========================================================================
    client: ?*tb.TBClient = null,
    packet_pool: PacketPool = .{},
    allocator: std.mem.Allocator = std.heap.page_allocator,

    // =========================================================================
    // Query Filter
    // =========================================================================
    query_filter: tb.QueryFilter = .{
        .user_data_128 = 0,
        .user_data_64 = 0,
        .user_data_32 = 0,
        .ledger = 0,
        .code = 0,
        .reserved = [_]u8{0} ** 6,
        .timestamp_min = 0,
        .timestamp_max = 0,
        .limit = MAX_ACCOUNTS,
        .flags = .{},
    },

    // =========================================================================
    // Account Data (Phase 4: Entity-based)
    // =========================================================================
    accounts: [MAX_ACCOUNTS]gooey.Entity(Account) = [_]gooey.Entity(Account){gooey.Entity(Account).nil()} ** MAX_ACCOUNTS,
    account_count: usize = 0,

    // Staging area for results from IO thread
    pending_accounts: [MAX_ACCOUNTS]tb.Account = undefined,
    pending_account_count: usize = 0,

    // Operation result from IO thread (Phase 3)
    pending_result: ?OperationResult = null,

    // New account creation buffer (persists during async call)
    pending_new_account: [1]tb.Account = undefined,

    // =========================================================================
    // Transfer State
    // =========================================================================
    transfer_amount: []const u8 = "",
    pending_transfer: [1]tb.Transfer = undefined,
    transfer_success: bool = false,
    transfer_error_msg: ?[]const u8 = null,

    // =========================================================================
    // UI State
    // =========================================================================
    list_state: UniformListState = UniformListState.init(0, ACCOUNT_ROW_HEIGHT),
    selected_index: ?u32 = null,

    // =========================================================================
    // Threading
    // =========================================================================
    request_sequence: std.atomic.Value(u32) = std.atomic.Value(u32).init(0),
    last_completed_sequence: std.atomic.Value(u32) = std.atomic.Value(u32).init(0),

    // Rate limiting (TB IO thread needs settling time)
    last_callback_timestamp_ns: std.atomic.Value(i128) = std.atomic.Value(i128).init(0),

    gooey_ptr: ?*gooey.Gooey = null,
    dispatcher: Dispatcher = Dispatcher.init(std.heap.page_allocator),

    // =========================================================================
    // State Transition Guards (Phase 1 Refactoring)
    // =========================================================================

    /// Check if we can submit a new operation
    pub fn canSubmit(self: *const AppState) bool {
        return self.connection.canSubmit() and !self.current_op.isActive();
    }

    /// Begin a new operation. Returns error if not ready or busy.
    fn beginOperation(self: *AppState, op: Operation) error{ NotReady, Busy }!void {
        // Assertions per CLAUDE.md
        std.debug.assert(op != .none);

        if (!self.connection.canSubmit()) {
            log.debug("beginOperation({s}): not connected (state={})", .{ op.name(), self.connection });
            return error.NotReady;
        }
        if (self.current_op.isActive()) {
            log.debug("beginOperation({s}): busy with {s}", .{ op.name(), self.current_op.name() });
            return error.Busy;
        }

        self.current_op = op;
        self.last_error = null; // Clear previous error on new operation
        log.debug("beginOperation({s}): started", .{op.name()});
    }

    /// Complete the current operation successfully
    fn completeOperation(self: *AppState) void {
        // Assertion: must have an active operation
        std.debug.assert(self.current_op.isActive());

        log.debug("completeOperation({s}): completed", .{self.current_op.name()});
        self.current_op = .none;
    }

    /// Fail the current operation with an error message
    fn failOperation(self: *AppState, msg: []const u8) void {
        log.err("failOperation({s}): {s}", .{ self.current_op.name(), msg });
        self.last_error = msg;
        self.current_op = .none;
    }

    /// Check if we should rate limit (TB IO thread needs settling time)
    fn shouldRateLimit(self: *const AppState) bool {
        const last = self.last_callback_timestamp_ns.load(.acquire);
        if (last == 0) return false;

        const now: i128 = std.time.nanoTimestamp();
        return (now - last) < MIN_CALLBACK_GAP_NS;
    }

    // =========================================================================
    // Connection Commands
    // =========================================================================

    pub fn connect(self: *AppState, g: *gooey.Gooey) void {
        // Guard: already connected or connecting
        if (self.connection != .disconnected) {
            log.debug("connect: already in state {}", .{self.connection});
            return;
        }

        log.info("Connecting to TigerBeetle...", .{});
        self.connection = .connecting;
        self.gooey_ptr = g;

        // Register log callback for debugging
        _ = tb.registerLogCallback(tbLogCallback, true);

        // Allocate client on heap (CRITICAL: must not move after init)
        const client_ptr = self.allocator.create(tb.TBClient) catch |err| {
            log.err("Failed to allocate TBClient: {}", .{err});
            self.connection = .disconnected;
            self.last_error = "Failed to allocate client";
            return;
        };

        // Initialize client in-place at its final location
        const init_fn = if (USE_ECHO_CLIENT) tb.TBClient.initEchoInPlace else tb.TBClient.initInPlace;
        init_fn(
            client_ptr,
            0, // cluster_id
            DEFAULT_ADDRESS,
            @intFromPtr(self),
            tbCompletionCallback,
        ) catch |err| {
            log.err("TigerBeetle client init failed: {}", .{err});
            self.allocator.destroy(client_ptr);
            self.connection = .disconnected;
            self.last_error = switch (err) {
                error.AddressInvalid => "Invalid server address",
                error.NetworkSubsystem => "Network error",
                error.SystemResources => "System resources exhausted",
                else => "Connection failed",
            };
            return;
        };

        self.client = client_ptr;
        self.connection = .ready;
        self.last_error = null;
        log.info("Connected to TigerBeetle successfully", .{});

        // Auto-query accounts on connect
        self.queryAccounts(g);
    }

    pub fn disconnect(self: *AppState, _: *gooey.Gooey) void {
        if (self.client) |client_ptr| {
            client_ptr.deinit();
            self.allocator.destroy(client_ptr);
            self.client = null;
        }

        self.connection = .disconnected;
        self.current_op = .none;
        self.account_count = 0;
        self.selected_index = null;
        self.last_error = null;
        self.packet_pool.reset();

        log.info("Disconnected from TigerBeetle", .{});
    }

    // =========================================================================
    // Query Operations
    // =========================================================================

    pub fn refreshAccounts(self: *AppState, g: *gooey.Gooey) void {
        self.queryAccounts(g);
    }

    pub fn queryAccounts(self: *AppState, g: *gooey.Gooey) void {
        // Guard: state machine check
        self.beginOperation(.query_accounts) catch |err| {
            switch (err) {
                error.NotReady => log.debug("queryAccounts: not connected", .{}),
                error.Busy => log.debug("queryAccounts: operation in progress", .{}),
            }
            return;
        };

        // Guard: rate limiting
        if (self.shouldRateLimit()) {
            log.debug("queryAccounts: rate limited, deferring", .{});
            self.current_op = .none; // Reset, will retry

            // Schedule retry via dispatcher
            const Ctx = struct { app: *AppState, g: *gooey.Gooey };
            self.dispatcher.dispatchAfter(
                SETTLE_DELAY_NS,
                Ctx,
                .{ .app = self, .g = g },
                struct {
                    fn cb(ctx: *Ctx) void {
                        ctx.app.queryAccounts(ctx.g);
                    }
                }.cb,
            ) catch {
                self.failOperation("Failed to schedule query");
            };
            return;
        }

        // Acquire packet
        const packet = self.packet_pool.acquire() orelse {
            self.failOperation("No packets available");
            return;
        };

        // Set request tag for routing in callback
        packet.user_tag = REQUEST_TAG_QUERY_ACCOUNTS;

        // Submit query
        const client = self.client orelse {
            self.packet_pool.release(packet);
            self.failOperation("Client not connected");
            return;
        };

        client.queryAccounts(packet, &self.query_filter) catch |err| {
            self.packet_pool.release(packet);
            self.failOperation(switch (err) {
                error.ClientInvalid => "Client invalid",
                else => "Query submission failed",
            });
            return;
        };

        log.debug("Query submitted", .{});
    }

    // =========================================================================
    // Create Operations
    // =========================================================================

    pub fn createAccount(self: *AppState, g: *gooey.Gooey) void {
        // Guard: state machine check
        self.beginOperation(.{ .create_account = .{ .account_id = 0 } }) catch |err| {
            switch (err) {
                error.NotReady => log.debug("createAccount: not connected", .{}),
                error.Busy => log.debug("createAccount: operation in progress", .{}),
            }
            return;
        };

        // Generate random account ID
        var rng = std.Random.DefaultPrng.init(@intCast(std.time.milliTimestamp()));
        const new_id: u128 = rng.random().int(u128);

        // Prepare account in persistent buffer
        self.pending_new_account[0] = .{
            .id = new_id,
            .debits_pending = 0,
            .debits_posted = 0,
            .credits_pending = 0,
            .credits_posted = 0,
            .user_data_128 = 0,
            .user_data_64 = 0,
            .user_data_32 = 0,
            .reserved = 0,
            .ledger = 1,
            .code = 1,
            .flags = .{},
            .timestamp = 0,
        };

        // Update operation context with actual ID
        self.current_op = .{ .create_account = .{ .account_id = new_id } };

        // Acquire packet
        const packet = self.packet_pool.acquire() orelse {
            self.failOperation("No packets available");
            return;
        };

        packet.user_tag = REQUEST_TAG_CREATE_ACCOUNTS;

        const client = self.client orelse {
            self.packet_pool.release(packet);
            self.failOperation("Client not connected");
            return;
        };

        // Explicit slice creation for FFI (per TIGERBEETLE_UI.md gotcha #3)
        const accounts_slice: []const tb.Account = self.pending_new_account[0..];

        client.createAccounts(packet, accounts_slice) catch |err| {
            self.packet_pool.release(packet);
            self.failOperation(switch (err) {
                error.ClientInvalid => "Client invalid",
                else => "Create submission failed",
            });
            return;
        };

        log.info("Creating account with ID: {x}", .{new_id});
        _ = g;
    }

    pub fn createTransfer(self: *AppState, g: *gooey.Gooey) void {
        // Need at least 2 accounts for a transfer
        if (self.account_count < 2) {
            self.last_error = "Need at least 2 accounts";
            return;
        }

        // Must have a selected account (and not the reserve account)
        const selected_idx = self.selected_index orelse {
            self.last_error = "Select an account to receive funds";
            return;
        };

        if (selected_idx == 0) {
            self.last_error = "Cannot transfer to reserve account (ACC-1)";
            return;
        }

        // Parse amount from input (dollars to cents)
        const amount: u128 = parseDollarsToCents(self.transfer_amount) orelse {
            self.last_error = "Invalid amount (use format: 20 or 20.00)";
            return;
        };

        if (amount == 0) {
            self.last_error = "Amount must be > 0";
            return;
        }

        // Guard: state machine check
        self.beginOperation(.{ .create_transfer = .{ .amount = amount } }) catch |err| {
            switch (err) {
                error.NotReady => log.debug("createTransfer: not connected", .{}),
                error.Busy => log.debug("createTransfer: operation in progress", .{}),
            }
            return;
        };

        // Generate random transfer ID
        var rng = std.Random.DefaultPrng.init(@intCast(std.time.milliTimestamp()));
        const transfer_id: u128 = rng.random().int(u128);

        // Use first two accounts as debit/credit (read from entities)
        const debit_account_id = blk: {
            const entity = self.accounts[0];
            if (self.gooey_ptr) |gp| {
                if (gp.readEntity(Account, entity)) |acc| {
                    break :blk acc.id;
                }
            }
            self.failOperation("Could not read debit account");
            return;
        };
        const credit_account_id = blk: {
            const entity = self.accounts[selected_idx];
            if (self.gooey_ptr) |gp| {
                if (gp.readEntity(Account, entity)) |acc| {
                    break :blk acc.id;
                }
            }
            self.failOperation("Could not read credit account");
            return;
        };

        // Prepare transfer in persistent buffer
        self.pending_transfer[0] = .{
            .id = transfer_id,
            .debit_account_id = debit_account_id,
            .credit_account_id = credit_account_id,
            .amount = amount,
            .pending_id = 0,
            .user_data_128 = 0,
            .user_data_64 = 0,
            .user_data_32 = 0,
            .timeout = 0,
            .ledger = 1,
            .code = 1,
            .flags = .{},
            .timestamp = 0,
        };

        // Defer submission by 50ms to let IO thread settle (per TIGERBEETLE_UI.md gotcha #7)
        const Ctx = struct { app: *AppState, g: *gooey.Gooey };
        self.dispatcher.dispatchAfter(
            SETTLE_DELAY_NS,
            Ctx,
            .{ .app = self, .g = g },
            struct {
                fn doSubmit(ctx: *Ctx) void {
                    const packet = ctx.app.packet_pool.acquire() orelse {
                        ctx.app.failOperation("No packets available");
                        return;
                    };

                    packet.user_tag = REQUEST_TAG_CREATE_TRANSFERS;

                    const client = ctx.app.client orelse {
                        ctx.app.packet_pool.release(packet);
                        ctx.app.failOperation("Client not connected");
                        return;
                    };

                    const transfers_slice: []const tb.Transfer = ctx.app.pending_transfer[0..];
                    client.createTransfers(packet, transfers_slice) catch |err| {
                        ctx.app.packet_pool.release(packet);
                        ctx.app.failOperation(switch (err) {
                            error.ClientInvalid => "Client invalid",
                            else => "Transfer submission failed",
                        });
                        return;
                    };

                    log.info("Transfer submitted: {} units", .{ctx.app.pending_transfer[0].amount});
                }
            }.doSubmit,
        ) catch {
            self.failOperation("Failed to schedule transfer");
        };
    }

    pub fn clearTransferInput(self: *AppState, g: *gooey.Gooey) void {
        if (g.textInput("transfer-amount")) |input| {
            input.clear();
        }
        self.transfer_amount = "";
        self.transfer_success = false;
        self.transfer_error_msg = null;
    }

    pub fn selectAccount(self: *AppState, index: u32) void {
        if (index < self.account_count) {
            self.selected_index = index;
        }
    }

    /// Get the selected account entity (if any)
    pub fn getSelectedAccountEntity(self: *const AppState) ?gooey.Entity(Account) {
        if (self.selected_index) |idx| {
            if (idx < self.account_count) {
                const entity = self.accounts[idx];
                if (entity.isValid()) {
                    return entity;
                }
            }
        }
        return null;
    }

    // =========================================================================
    // Thread Dispatch
    // =========================================================================

    const DispatchCtx = struct { app: *AppState };

    fn dispatchToMain(self: *AppState) void {
        self.dispatcher.dispatchOnMainThread(
            DispatchCtx,
            .{ .app = self },
            dispatchHandler,
        ) catch |err| {
            log.err("dispatchOnMainThread failed: {}", .{err});
        };
    }

    fn dispatchHandler(ctx: *DispatchCtx) void {
        const s = ctx.app;
        const g = s.gooey_ptr orelse return;

        // Apply pending result if present
        // applyResult returns true if it already completed the operation (e.g., triggered a refresh)
        var already_completed = false;
        if (s.pending_result) |result| {
            already_completed = s.applyResult(g, result);
            s.pending_result = null;
        }

        if (!already_completed) {
            s.completeOperation();
        }
        g.requestRender();
    }

    /// Apply an operation result to the app state (main thread only).
    /// Returns true if the operation was already completed (e.g., triggered a follow-up operation).
    fn applyResult(self: *AppState, g: *gooey.Gooey, result: OperationResult) bool {
        log.debug("applyResult: {s}", .{result.name()});

        switch (result) {
            .query_accounts => |r| {
                // Sync account entities from pending buffer
                self.syncAccountEntities(g, r.count);
                return false;
            },
            .create_account => |r| {
                if (r.success) {
                    // Success - complete this operation and trigger refresh
                    self.completeOperation();
                    self.queryAccounts(g);
                    return true; // Already completed, new operation started
                } else if (r.error_msg) |msg| {
                    self.last_error = msg;
                }
                return false;
            },
            .create_transfer => |r| {
                if (r.success) {
                    self.transfer_success = true;
                    self.transfer_error_msg = null;
                    self.clearTransferInput(g);
                    // Complete this operation and trigger refresh
                    self.completeOperation();
                    self.queryAccounts(g);
                    return true; // Already completed, new operation started
                } else {
                    self.transfer_success = false;
                    self.transfer_error_msg = r.error_msg;
                    self.last_error = r.error_msg;
                }
                return false;
            },
        }
    }

    // =========================================================================
    // Entity Sync (Phase 4)
    // =========================================================================

    /// Sync account entities from pending_accounts buffer (main thread only).
    /// Removes old entities and creates new ones from the TB response.
    fn syncAccountEntities(self: *AppState, g: *gooey.Gooey, count: usize) void {
        // Assertion: count within bounds
        std.debug.assert(count <= MAX_ACCOUNTS);

        // Remove old entities
        for (self.accounts[0..self.account_count]) |entity| {
            if (entity.isValid()) {
                g.getEntities().remove(entity.id);
            }
        }

        // Create new entities from pending buffer
        for (self.pending_accounts[0..count], 0..) |tb_acc, i| {
            const account = Account.fromTB(tb_acc);
            self.accounts[i] = g.createEntity(Account, account) catch {
                log.err("Failed to create account entity at index {}", .{i});
                // Mark remaining as nil and stop
                for (self.accounts[i..MAX_ACCOUNTS]) |*slot| {
                    slot.* = gooey.Entity(Account).nil();
                }
                self.account_count = i;
                self.list_state = UniformListState.init(@intCast(self.account_count), ACCOUNT_ROW_HEIGHT);
                return;
            };
        }

        // Clear any remaining slots
        for (self.accounts[count..MAX_ACCOUNTS]) |*slot| {
            slot.* = gooey.Entity(Account).nil();
        }

        self.account_count = count;
        self.list_state = UniformListState.init(@intCast(self.account_count), ACCOUNT_ROW_HEIGHT);
        log.info("Synced {} account entities", .{self.account_count});
    }

    /// Get account data by index (reads from entity system)
    pub fn getAccountAt(self: *const AppState, g: *gooey.Gooey, index: usize) ?*const Account {
        if (index >= self.account_count) return null;
        const entity = self.accounts[index];
        return g.readEntity(Account, entity);
    }
};

// =============================================================================
// Global State
// =============================================================================

var state = AppState{};

// =============================================================================
// Root Render Function
// =============================================================================

fn render(cx: *Cx) void {
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

// =============================================================================
// Sidebar Component
// =============================================================================

const Sidebar = struct {
    pub fn render(_: @This(), cx: *Cx) void {
        cx.render(ui.box(.{
            .width = SIDEBAR_WIDTH,
            .fill_height = true,
            .background = theme.surface,
            .border_color = theme.border,
            .border_width = 1,
            .direction = .column,
            .gap = 0,
        }, .{
            // Header section - clean, minimal
            ui.box(.{
                .fill_width = true,
                .padding = .{ .symmetric = .{ .x = 20, .y = 24 } },
                .direction = .row,
                .gap = 12,
                .alignment = .{ .cross = .center },
            }, .{
                // Logo accent mark
                ui.box(.{
                    .width = 4,
                    .height = 32,
                    .corner_radius = 2,
                    .background = theme.lime,
                }, .{}),
                ui.vstack(.{ .gap = 2 }, .{
                    ui.text("TigerBeetle", .{
                        .size = 20,
                        .weight = .bold,
                        .color = theme.text,
                    }),
                    ui.text("Financial Database", .{
                        .size = 12,
                        .color = theme.text_muted,
                    }),
                }),
            }),
            ConnectionPanel{},
            AccountListPanel{},
        }));
    }
};

// =============================================================================
// Connection Panel
// =============================================================================

const ConnectionPanel = struct {
    pub fn render(_: @This(), cx: *Cx) void {
        const s = cx.state(AppState);

        cx.render(ui.box(.{
            .fill_width = true,
            .padding = .{ .symmetric = .{ .x = 20, .y = 16 } },
            .background = theme.bg,
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
                ui.box(.{
                    .fill_width = true,
                    .padding = .{ .symmetric = .{ .x = 12, .y = 10 } },
                    .background = theme.surface,
                    .corner_radius = 6,
                    .border_color = theme.border,
                    .border_width = 1,
                }, .{
                    ui.text(DEFAULT_ADDRESS, .{
                        .size = 13,
                        .color = theme.text_body,
                    }),
                }),
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

const StatusDot = struct {
    color: Color,

    pub fn render(self: @This(), cx: *Cx) void {
        cx.render(ui.box(.{
            .width = 8,
            .height = 8,
            .corner_radius = 4,
            .background = self.color,
        }, .{}));
    }
};

// =============================================================================
// Account List Panel
// =============================================================================

const AccountListPanel = struct {
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
            ui.hstack(.{ .alignment = .center, .gap = 8 }, .{
                ui.text("Accounts", .{
                    .size = 13,
                    .weight = .bold,
                    .color = theme.text,
                }),
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
                ui.spacer(),
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

const AccountList = struct {
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

const AccountRow = struct {
    account: *const Account,
    index: u32,
    selected: bool,

    pub fn render(self: @This(), cx: *Cx) void {
        const bg = if (self.selected) theme.selected_bg else Color.transparent;
        const balance = self.account.balance();
        const balance_color = if (balance >= 0) theme.mint else theme.danger;

        cx.render(ui.box(.{
            .fill_width = true,
            .height = ACCOUNT_ROW_HEIGHT - 4,
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
                ui.text(formatBalance(balance), .{
                    .size = 14,
                    .weight = .bold,
                    .color = balance_color,
                }),
            }),
        }));
    }
};

// =============================================================================
// Main Panel
// =============================================================================

const MainPanel = struct {
    pub fn render(_: @This(), cx: *Cx) void {
        const s = cx.state(AppState);
        const g = cx.gooey();

        // Get selected account data from entity system
        const selected_account: ?*const Account = if (s.getSelectedAccountEntity()) |entity|
            g.readEntity(Account, entity)
        else
            null;

        cx.render(ui.box(.{
            .grow = true,
            .fill_height = true,
            .background = theme.bg,
            .padding = .{ .all = 24 },
            .direction = .column,
        }, .{
            ui.when(selected_account != null, .{
                AccountDetails{ .account = selected_account },
            }),
            ui.when(selected_account == null, .{
                EmptyState{
                    .title = "Select an Account",
                    .subtitle = "Choose an account from the sidebar to view details",
                },
            }),
        }));
    }
};

// =============================================================================
// Empty State
// =============================================================================

const EmptyState = struct {
    title: []const u8,
    subtitle: []const u8,

    pub fn render(self: @This(), cx: *Cx) void {
        cx.render(ui.box(.{
            .grow = true,
            .fill_width = true,
            .alignment = .{ .main = .center, .cross = .center },
        }, .{
            ui.vstack(.{ .gap = 16, .alignment = .center }, .{
                // Subtle icon
                Svg{ .path = Icons.database, .size = 40, .color = theme.border_light },
                ui.vstack(.{ .gap = 6, .alignment = .center }, .{
                    ui.text(self.title, .{
                        .size = 16,
                        .weight = .bold,
                        .color = theme.text,
                    }),
                    ui.text(self.subtitle, .{
                        .size = 13,
                        .color = theme.text_muted,
                    }),
                }),
            }),
        }));
    }
};

// =============================================================================
// Account Details
// =============================================================================

const AccountDetails = struct {
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
                    ui.text(formatBalance(balance), .{
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
        }));
    }
};

const BalanceCard = struct {
    title: []const u8,
    posted: u128,
    pending: u128,
    color: Color,

    pub fn render(self: @This(), cx: *Cx) void {
        cx.render(ui.box(.{
            .grow = true,
            .padding = .{ .all = 16 },
            .background = theme.surface,
            .corner_radius = 6,
            .border_color = theme.border,
            .border_width = 1,
        }, .{
            ui.vstack(.{ .gap = 8 }, .{
                // Title with color dot
                ui.hstack(.{ .gap = 8, .alignment = .center }, .{
                    ui.box(.{
                        .width = 8,
                        .height = 8,
                        .corner_radius = 4,
                        .background = self.color,
                    }, .{}),
                    ui.text(self.title, .{
                        .size = 12,
                        .weight = .bold,
                        .color = theme.text,
                    }),
                }),
                // Posted amount
                ui.vstack(.{ .gap = 2 }, .{
                    ui.text("Posted", .{
                        .size = 10,
                        .color = theme.text_muted,
                    }),
                    ui.text(formatMoney(self.posted), .{
                        .size = 22,
                        .weight = .bold,
                        .color = theme.text,
                    }),
                }),
                // Pending amount
                ui.vstack(.{ .gap = 2 }, .{
                    ui.text("Pending", .{
                        .size = 10,
                        .color = theme.text_muted,
                    }),
                    ui.text(formatMoney(self.pending), .{
                        .size = 16,
                        .color = self.color,
                    }),
                }),
            }),
        }));
    }
};

const TransferSection = struct {
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

// =============================================================================
// App Definition
// =============================================================================

const App = gooey.App(AppState, &state, render, .{
    .title = "TigersEye",
    .width = 1200,
    .height = 800,
    .min_size = .{ .width = 900, .height = 600 },
});

// =============================================================================
// Entry Point
// =============================================================================

pub fn main() !void {
    if (platform.is_wasm) unreachable;
    return App.main();
}
