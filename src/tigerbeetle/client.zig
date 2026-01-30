//! TigerBeetle Client Module
//!
//! This is the main entry point for TigerBeetle functionality.
//! Re-exports all public APIs from submodules for convenient access.

const std = @import("std");

// =============================================================================
// Re-exports from submodules
// =============================================================================

pub const callbacks = @import("callbacks.zig");
pub const format = @import("format.zig");

// Re-export commonly used items at top level
pub const PacketPool = callbacks.PacketPool;
pub const tbLogCallback = callbacks.tbLogCallback;
pub const createCompletionCallback = callbacks.createCompletionCallback;
pub const accountErrorMessage = callbacks.accountErrorMessage;
pub const transferErrorMessage = callbacks.transferErrorMessage;

pub const formatMoney = format.formatMoney;
pub const formatBalance = format.formatBalance;
pub const parseDollarsToCents = format.parseDollarsToCents;

// Re-export request tags
pub const REQUEST_TAG_QUERY_ACCOUNTS = callbacks.REQUEST_TAG_QUERY_ACCOUNTS;
pub const REQUEST_TAG_CREATE_ACCOUNTS = callbacks.REQUEST_TAG_CREATE_ACCOUNTS;
pub const REQUEST_TAG_CREATE_TRANSFERS = callbacks.REQUEST_TAG_CREATE_TRANSFERS;
pub const REQUEST_TAG_GET_ACCOUNT_TRANSFERS = callbacks.REQUEST_TAG_GET_ACCOUNT_TRANSFERS;

// =============================================================================
// Constants (per CLAUDE.md: "Put a limit on everything")
// =============================================================================

pub const MAX_ACCOUNTS: usize = callbacks.MAX_ACCOUNTS;
pub const MAX_TRANSFERS: usize = callbacks.MAX_TRANSFERS;
pub const PACKET_POOL_SIZE: usize = callbacks.PACKET_POOL_SIZE;
pub const DEFAULT_ADDRESS = "127.0.0.1:3000";

// Rate limiting for TigerBeetle IO thread synchronization
pub const MIN_CALLBACK_GAP_NS: i128 = 100_000_000; // 100ms
pub const SETTLE_DELAY_NS: u64 = 50_000_000; // 50ms

// Set to true to use echo client (for testing callbacks without a real TB server)
pub const USE_ECHO_CLIENT = false;
