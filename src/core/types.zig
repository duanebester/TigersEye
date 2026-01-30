//! Core domain types for TigersEye
//!
//! This module contains the fundamental types used throughout the application:
//! - ConnectionState: State machine for TigerBeetle connection
//! - Operation: Tagged union for in-flight operations
//! - OperationResult: Tagged union for operation results
//! - Account: Application-level account representation
//! - Transfer: Application-level transfer representation

const std = @import("std");
const gooey = @import("gooey");
const tb = @import("tigerbeetle");

const Color = gooey.Color;
const theme = @import("theme.zig"); // same directory

// =============================================================================
// Connection State Machine
// =============================================================================

pub const ConnectionState = enum {
    disconnected,
    connecting,
    registering,
    ready,

    pub fn canSubmit(self: ConnectionState) bool {
        return self == .ready;
    }

    pub fn isConnected(self: ConnectionState) bool {
        return self == .ready;
    }

    pub fn statusText(self: ConnectionState) []const u8 {
        return switch (self) {
            .disconnected => "DISCONNECTED",
            .connecting => "CONNECTING",
            .registering => "REGISTERING",
            .ready => "CONNECTED",
        };
    }

    pub fn statusColor(self: ConnectionState) Color {
        return switch (self) {
            .disconnected => theme.text_muted,
            .connecting, .registering => theme.yellow,
            .ready => theme.success,
        };
    }
};

// =============================================================================
// Operation Types (in-flight operations)
// =============================================================================

pub const Operation = union(enum) {
    none,
    query_accounts,
    create_account: CreateAccountCtx,
    create_transfer: CreateTransferCtx,
    get_account_transfers: GetAccountTransfersCtx,

    pub const CreateAccountCtx = struct {
        account_id: u128,
    };

    pub const CreateTransferCtx = struct {
        amount: u128,
    };

    pub const GetAccountTransfersCtx = struct {
        account_id: u128,
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
            .get_account_transfers => "get_account_transfers",
        };
    }
};

// =============================================================================
// Operation Results (from IO thread)
// =============================================================================

pub const OperationResult = union(enum) {
    query_accounts: QueryResult,
    create_account: CreateResult,
    create_transfer: CreateResult,
    get_account_transfers: TransfersResult,

    pub const QueryResult = struct {
        count: usize,
    };

    pub const CreateResult = struct {
        success: bool,
        error_msg: ?[]const u8,
    };

    pub const TransfersResult = struct {
        count: usize,
    };

    pub fn name(self: OperationResult) []const u8 {
        return switch (self) {
            .query_accounts => "query_accounts",
            .create_account => "create_account",
            .create_transfer => "create_transfer",
            .get_account_transfers => "get_account_transfers",
        };
    }
};

// =============================================================================
// Account (Application-level representation)
// =============================================================================

pub const Account = struct {
    id: u128,
    ledger: u32,
    code: u16,
    debits_pending: u128,
    debits_posted: u128,
    credits_pending: u128,
    credits_posted: u128,
    timestamp: u64,

    /// Convert from TigerBeetle account to our application Account
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

    /// Calculate net balance (credits - debits, including pending)
    pub fn balance(self: *const Account) i128 {
        const credits: i128 = @intCast(self.credits_posted + self.credits_pending);
        const debits: i128 = @intCast(self.debits_posted + self.debits_pending);
        return credits - debits;
    }

    /// Get shortened ID for display (last 4 hex digits)
    pub fn shortId(self: *const Account) u16 {
        return @truncate(self.id);
    }
};

// =============================================================================
// Transfer (Application-level representation)
// =============================================================================

pub const Transfer = struct {
    id: u128,
    debit_account_id: u128,
    credit_account_id: u128,
    amount: u128,
    pending_id: u128,
    user_data_128: u128,
    user_data_64: u64,
    user_data_32: u32,
    timeout: u32,
    ledger: u32,
    code: u16,
    flags: tb.TransferFlags,
    timestamp: u64,

    /// Convert from TigerBeetle transfer to our application Transfer
    pub fn fromTB(tb_transfer: tb.Transfer) Transfer {
        return .{
            .id = tb_transfer.id,
            .debit_account_id = tb_transfer.debit_account_id,
            .credit_account_id = tb_transfer.credit_account_id,
            .amount = tb_transfer.amount,
            .pending_id = tb_transfer.pending_id,
            .user_data_128 = tb_transfer.user_data_128,
            .user_data_64 = tb_transfer.user_data_64,
            .user_data_32 = tb_transfer.user_data_32,
            .timeout = tb_transfer.timeout,
            .ledger = tb_transfer.ledger,
            .code = tb_transfer.code,
            .flags = tb_transfer.flags,
            .timestamp = tb_transfer.timestamp,
        };
    }

    /// Check if this is a pending transfer
    pub fn isPending(self: *const Transfer) bool {
        return self.flags.pending;
    }

    /// Check if this is a debit from the given account
    pub fn isDebitFrom(self: *const Transfer, account_id: u128) bool {
        return self.debit_account_id == account_id;
    }

    /// Check if this is a credit to the given account
    pub fn isCreditTo(self: *const Transfer, account_id: u128) bool {
        return self.credit_account_id == account_id;
    }

    /// Get shortened ID for display (last 4 hex digits)
    pub fn shortId(self: *const Transfer) u16 {
        return @truncate(self.id);
    }
};
