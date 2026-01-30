//! TigerBeetle Money Formatting Utilities
//!
//! This module contains formatting and parsing utilities for money values:
//! - formatMoney: Convert cents (u128) to display string "$X.XX"
//! - formatBalance: Convert signed cents (i128) to display string
//! - parseDollarsToCents: Parse user input to cents

const std = @import("std");

// =============================================================================
// Money Formatting (cents to dollars)
// =============================================================================

/// Multiple buffers for concurrent money formatting in same render pass.
/// We need at least 6 buffers: 2 for BalanceCard posted, 2 for pending, 1 for net balance, 1 for list items
const NUM_MONEY_BUFS = 8;
var money_bufs: [NUM_MONEY_BUFS][32]u8 = undefined;
var money_buf_idx: usize = 0;

pub fn formatMoney(cents: u128) []const u8 {
    const buf = &money_bufs[money_buf_idx];
    money_buf_idx = (money_buf_idx + 1) % NUM_MONEY_BUFS;

    const dollars = cents / 100;
    const remainder = cents % 100;
    const result = std.fmt.bufPrint(buf, "${}.{:0>2}", .{ dollars, remainder }) catch return "$0.00";
    return result;
}

pub fn formatBalance(cents: i128) []const u8 {
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
pub fn parseDollarsToCents(input: []const u8) ?u128 {
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
