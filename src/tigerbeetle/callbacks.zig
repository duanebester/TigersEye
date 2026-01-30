//! TigerBeetle Callbacks and Packet Pool
//!
//! This module contains:
//! - PacketPool: Static allocation for TigerBeetle packets
//! - tbLogCallback: Log callback for TigerBeetle client
//! - createCompletionCallback: Completion callback factory
//! - Error message helpers

const std = @import("std");
const log = std.log.scoped(.tigerseye);
const tb = @import("tigerbeetle");

const types = @import("../core/types.zig");
const OperationResult = types.OperationResult;
const Account = types.Account;

// =============================================================================
// Constants (per CLAUDE.md: "Put a limit on everything")
// =============================================================================

pub const PACKET_POOL_SIZE: usize = 8;
pub const MAX_ACCOUNTS: usize = 1024;
pub const MAX_TRANSFERS: usize = 256;

// Request routing tags (stored in packet.user_tag)
pub const REQUEST_TAG_QUERY_ACCOUNTS: u16 = 1;
pub const REQUEST_TAG_CREATE_ACCOUNTS: u16 = 2;
pub const REQUEST_TAG_CREATE_TRANSFERS: u16 = 3;
pub const REQUEST_TAG_GET_ACCOUNT_TRANSFERS: u16 = 4;

// =============================================================================
// Packet Pool - Static allocation for TigerBeetle packets
// =============================================================================

pub const PacketPool = struct {
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

pub fn tbLogCallback(level: tb.LogLevel, msg_ptr: [*]const u8, msg_len: u32) callconv(.c) void {
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

/// Creates a completion callback that works with the given AppState type.
/// AppState must have: packet_pool, last_callback_timestamp_ns, request_sequence,
/// last_completed_sequence, pending_result, pending_accounts, pending_account_count,
/// and dispatchToMain().
pub fn createCompletionCallback(comptime AppState: type) fn (usize, *tb.Packet, u64, ?[*]const u8, u32) callconv(.c) void {
    return struct {
        fn callback(
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
                    REQUEST_TAG_GET_ACCOUNT_TRANSFERS => .{ .get_account_transfers = .{ .count = 0 } },
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
                REQUEST_TAG_GET_ACCOUNT_TRANSFERS => blk: {
                    if (result_ptr) |ptr| {
                        const transfers = tb.parseTransfers(ptr, result_len);
                        const count = @min(transfers.len, MAX_TRANSFERS);

                        // Copy to pending buffer (result_ptr only valid during callback)
                        @memcpy(self.pending_transfers[0..count], transfers[0..count]);
                        self.pending_transfer_count = count;

                        log.info("Get account transfers returned {} transfers", .{count});
                        break :blk .{ .get_account_transfers = .{ .count = count } };
                    } else {
                        self.pending_transfer_count = 0;
                        log.info("Get account transfers returned no transfers", .{});
                        break :blk .{ .get_account_transfers = .{ .count = 0 } };
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
    }.callback;
}

// =============================================================================
// Error Message Helpers
// =============================================================================

pub fn accountErrorMessage(result: tb.CreateAccountResult) []const u8 {
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

pub fn transferErrorMessage(result: tb.CreateTransferResult) []const u8 {
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
