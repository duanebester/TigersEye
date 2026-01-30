//! TigerBeetle Client C FFI Bindings for Zig
//!
//! These bindings allow calling the TigerBeetle C client library (libtb_client.dylib/so/dll)
//! from Zig code. The C ABI is stable across Zig versions.
//!
//! Usage:
//!   1. Place libtb_client.dylib (or .so/.dll) in vendor/tigerbeetle/lib/
//!   2. Link against tb_client in build.zig
//!   3. Import this module and use TBClient

const std = @import("std");

// =============================================================================
// Account Types
// =============================================================================

pub const AccountFlags = packed struct(u16) {
    linked: bool = false,
    debits_must_not_exceed_credits: bool = false,
    credits_must_not_exceed_debits: bool = false,
    history: bool = false,
    imported: bool = false,
    closed: bool = false,
    _reserved: u10 = 0,
};

pub const Account = extern struct {
    id: u128,
    debits_pending: u128,
    debits_posted: u128,
    credits_pending: u128,
    credits_posted: u128,
    user_data_128: u128,
    user_data_64: u64,
    user_data_32: u32,
    reserved: u32,
    ledger: u32,
    code: u16,
    flags: AccountFlags,
    timestamp: u64,

    pub fn balance(self: *const Account) i128 {
        const credits: i128 = @intCast(self.credits_posted);
        const debits: i128 = @intCast(self.debits_posted);
        return credits - debits;
    }

    comptime {
        std.debug.assert(@sizeOf(Account) == 128);
    }
};

// =============================================================================
// Transfer Types
// =============================================================================

pub const TransferFlags = packed struct(u16) {
    linked: bool = false,
    pending: bool = false,
    post_pending_transfer: bool = false,
    void_pending_transfer: bool = false,
    balancing_debit: bool = false,
    balancing_credit: bool = false,
    closing_debit: bool = false,
    closing_credit: bool = false,
    imported: bool = false,
    _reserved: u7 = 0,
};

pub const Transfer = extern struct {
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
    flags: TransferFlags,
    timestamp: u64,

    comptime {
        std.debug.assert(@sizeOf(Transfer) == 128);
    }
};

// =============================================================================
// Result Types
// =============================================================================

pub const CreateAccountResult = enum(u32) {
    ok = 0,
    linked_event_failed = 1,
    linked_event_chain_open = 2,
    timestamp_must_be_zero = 3,
    reserved_field = 4,
    reserved_flag = 5,
    id_must_not_be_zero = 6,
    id_must_not_be_int_max = 7,
    flags_are_mutually_exclusive = 8,
    debits_pending_must_be_zero = 9,
    debits_posted_must_be_zero = 10,
    credits_pending_must_be_zero = 11,
    credits_posted_must_be_zero = 12,
    ledger_must_not_be_zero = 13,
    code_must_not_be_zero = 14,
    exists_with_different_flags = 15,
    exists_with_different_user_data_128 = 16,
    exists_with_different_user_data_64 = 17,
    exists_with_different_user_data_32 = 18,
    exists_with_different_ledger = 19,
    exists_with_different_code = 20,
    exists = 21,
    imported_event_expected = 22,
    imported_event_not_expected = 23,
    imported_event_timestamp_out_of_range = 24,
    imported_event_timestamp_must_not_advance = 25,
    imported_event_timestamp_must_not_regress = 26,
    _,
};

pub const CreateTransferResult = enum(u32) {
    ok = 0,
    linked_event_failed = 1,
    linked_event_chain_open = 2,
    timestamp_must_be_zero = 3,
    reserved_flag = 4,
    id_must_not_be_zero = 5,
    id_must_not_be_int_max = 6,
    flags_are_mutually_exclusive = 7,
    debit_account_id_must_not_be_zero = 8,
    debit_account_id_must_not_be_int_max = 9,
    credit_account_id_must_not_be_zero = 10,
    credit_account_id_must_not_be_int_max = 11,
    accounts_must_be_different = 12,
    pending_id_must_be_zero = 13,
    pending_id_must_not_be_zero = 14,
    pending_id_must_not_be_int_max = 15,
    pending_id_must_be_different = 16,
    timeout_reserved_for_pending_transfer = 17,
    ledger_must_not_be_zero = 19,
    code_must_not_be_zero = 20,
    debit_account_not_found = 21,
    credit_account_not_found = 22,
    accounts_must_have_the_same_ledger = 23,
    transfer_must_have_the_same_ledger_as_accounts = 24,
    pending_transfer_not_found = 25,
    pending_transfer_not_pending = 26,
    pending_transfer_has_different_debit_account_id = 27,
    pending_transfer_has_different_credit_account_id = 28,
    pending_transfer_has_different_ledger = 29,
    pending_transfer_has_different_code = 30,
    exceeds_pending_transfer_amount = 31,
    pending_transfer_has_different_amount = 32,
    pending_transfer_already_posted = 33,
    pending_transfer_already_voided = 34,
    pending_transfer_expired = 35,
    exists_with_different_flags = 36,
    exists_with_different_debit_account_id = 37,
    exists_with_different_credit_account_id = 38,
    exists_with_different_amount = 39,
    exists_with_different_pending_id = 40,
    exists_with_different_user_data_128 = 41,
    exists_with_different_user_data_64 = 42,
    exists_with_different_user_data_32 = 43,
    exists_with_different_timeout = 44,
    exists_with_different_code = 45,
    exists = 46,
    overflows_debits_pending = 47,
    overflows_credits_pending = 48,
    overflows_debits_posted = 49,
    overflows_credits_posted = 50,
    overflows_debits = 51,
    overflows_credits = 52,
    overflows_timeout = 53,
    exceeds_credits = 54,
    exceeds_debits = 55,
    imported_event_expected = 56,
    imported_event_not_expected = 57,
    imported_event_timestamp_out_of_range = 58,
    imported_event_timestamp_must_not_advance = 59,
    imported_event_timestamp_must_not_regress = 60,
    imported_event_timestamp_must_postdate_debit_account = 61,
    imported_event_timestamp_must_postdate_credit_account = 62,
    imported_event_timeout_must_be_zero = 63,
    closing_transfer_must_be_pending = 64,
    debit_account_already_closed = 65,
    credit_account_already_closed = 66,
    exists_with_different_ledger = 67,
    id_already_failed = 68,
    _,
};

pub const CreateAccountsResult = extern struct {
    index: u32,
    result: CreateAccountResult,
};

pub const CreateTransfersResult = extern struct {
    index: u32,
    result: CreateTransferResult,
};

// =============================================================================
// Filter Types
// =============================================================================

pub const AccountFilterFlags = packed struct(u32) {
    debits: bool = false,
    credits: bool = false,
    reversed: bool = false,
    _reserved: u29 = 0,
};

pub const AccountFilter = extern struct {
    account_id: u128,
    user_data_128: u128,
    user_data_64: u64,
    user_data_32: u32,
    code: u16,
    reserved: [58]u8 = [_]u8{0} ** 58,
    timestamp_min: u64,
    timestamp_max: u64,
    limit: u32,
    flags: AccountFilterFlags,
};

pub const QueryFilterFlags = packed struct(u32) {
    reversed: bool = false,
    _reserved: u31 = 0,
};

pub const QueryFilter = extern struct {
    user_data_128: u128,
    user_data_64: u64,
    user_data_32: u32,
    ledger: u32,
    code: u16,
    reserved: [6]u8 = [_]u8{0} ** 6,
    timestamp_min: u64,
    timestamp_max: u64,
    limit: u32,
    flags: QueryFilterFlags,
};

pub const AccountBalance = extern struct {
    debits_pending: u128,
    debits_posted: u128,
    credits_pending: u128,
    credits_posted: u128,
    timestamp: u64,
    reserved: [56]u8 = [_]u8{0} ** 56,
};

// =============================================================================
// Client Types
// =============================================================================

/// Operation codes - must match official TigerBeetle C API (tb_client.h)
pub const Operation = enum(u8) {
    pulse = 128,
    get_change_events = 137,
    create_accounts = 138,
    create_transfers = 139,
    lookup_accounts = 140,
    lookup_transfers = 141,
    get_account_transfers = 142,
    get_account_balances = 143,
    query_accounts = 144,
    query_transfers = 145,
};

pub const PacketStatus = enum(u8) {
    ok = 0,
    too_much_data = 1,
    client_evicted = 2,
    client_release_too_low = 3,
    client_release_too_high = 4,
    client_shutdown = 5,
    invalid_operation = 6,
    invalid_data_size = 7,
    _,
};

pub const InitStatus = enum(u8) {
    success = 0,
    unexpected = 1,
    out_of_memory = 2,
    address_invalid = 3,
    address_limit_exceeded = 4,
    system_resources = 5,
    network_subsystem = 6,
    _,
};

pub const ClientStatus = enum(u8) {
    ok = 0,
    invalid = 1,
};

/// Opaque client handle - must remain pinned (not moved) during lifetime
pub const Client = extern struct {
    _opaque: [4]u64,
};

/// Packet for submitting requests - must remain pinned during request lifetime
pub const Packet = extern struct {
    user_data: ?*anyopaque,
    data: ?*anyopaque,
    data_size: u32,
    user_tag: u16,
    operation: u8,
    status: u8,
    _opaque: [64]u8,

    pub fn init() Packet {
        return .{
            .user_data = null,
            .data = null,
            .data_size = 0,
            .user_tag = 0,
            .operation = 0,
            .status = 0,
            ._opaque = [_]u8{0} ** 64,
        };
    }

    pub fn getStatus(self: *const Packet) PacketStatus {
        return @enumFromInt(self.status);
    }

    pub fn setOperation(self: *Packet, op: Operation) void {
        self.operation = @intFromEnum(op);
    }
};

// =============================================================================
// Completion Callback Type
// =============================================================================

pub const CompletionFn = *const fn (
    context: usize,
    packet: *Packet,
    timestamp: u64,
    result_ptr: ?[*]const u8,
    result_len: u32,
) callconv(.c) void;

// =============================================================================
// C FFI Extern Functions
// =============================================================================

extern "tb_client" fn tb_client_init(
    client_out: *Client,
    cluster_id: *const [16]u8,
    address_ptr: [*]const u8,
    address_len: u32,
    completion_ctx: usize,
    completion_callback: CompletionFn,
) InitStatus;

extern "tb_client" fn tb_client_init_echo(
    client_out: *Client,
    cluster_id: *const [16]u8,
    address_ptr: [*]const u8,
    address_len: u32,
    completion_ctx: usize,
    completion_callback: CompletionFn,
) InitStatus;

extern "tb_client" fn tb_client_submit(
    client: *Client,
    packet: *Packet,
) ClientStatus;

extern "tb_client" fn tb_client_deinit(
    client: *Client,
) ClientStatus;

// Log callback support for debugging
pub const LogLevel = enum(u8) {
    err = 0,
    warn = 1,
    info = 2,
    debug = 3,
};

pub const RegisterLogCallbackStatus = enum(u8) {
    success = 0,
    already_registered = 1,
    not_registered = 2,
};

pub const LogCallbackFn = *const fn (LogLevel, [*]const u8, u32) callconv(.c) void;

extern "tb_client" fn tb_client_register_log_callback(
    callback: ?LogCallbackFn,
    debug_logs: bool,
) RegisterLogCallbackStatus;

/// Register a log callback to receive TigerBeetle internal logs
pub fn registerLogCallback(callback: LogCallbackFn, debug_logs: bool) RegisterLogCallbackStatus {
    return tb_client_register_log_callback(callback, debug_logs);
}

/// Unregister the log callback
pub fn unregisterLogCallback() RegisterLogCallbackStatus {
    return tb_client_register_log_callback(null, false);
}

// =============================================================================
// High-Level Client Wrapper
// =============================================================================

pub const TBClientError = error{
    Unexpected,
    OutOfMemory,
    AddressInvalid,
    AddressLimitExceeded,
    SystemResources,
    NetworkSubsystem,
    ClientInvalid,
};

pub const TBClient = struct {
    const Self = @This();

    client: Client = undefined,
    connected: bool = false,

    /// Initialize a new TigerBeetle client
    pub fn init(
        cluster_id: u128,
        address: []const u8,
        completion_ctx: usize,
        completion_callback: CompletionFn,
    ) TBClientError!Self {
        var self = Self{};

        // Convert cluster_id to little-endian bytes
        var cluster_bytes: [16]u8 = undefined;
        std.mem.writeInt(u128, &cluster_bytes, cluster_id, .little);

        const status = tb_client_init(
            &self.client,
            &cluster_bytes,
            address.ptr,
            @intCast(address.len),
            completion_ctx,
            completion_callback,
        );

        switch (status) {
            .success => {
                self.connected = true;
                return self;
            },
            .unexpected => return error.Unexpected,
            .out_of_memory => return error.OutOfMemory,
            .address_invalid => return error.AddressInvalid,
            .address_limit_exceeded => return error.AddressLimitExceeded,
            .system_resources => return error.SystemResources,
            .network_subsystem => return error.NetworkSubsystem,
            _ => return error.Unexpected,
        }
    }

    /// Initialize a TigerBeetle client in-place (avoids moving the Client struct)
    /// IMPORTANT: TigerBeetle's C library stores internal pointers in the opaque data.
    /// The client MUST be initialized at its final memory location to avoid stale pointers.
    pub fn initInPlace(
        self: *Self,
        cluster_id: u128,
        address: []const u8,
        completion_ctx: usize,
        completion_callback: CompletionFn,
    ) TBClientError!void {
        self.* = Self{};

        var cluster_bytes: [16]u8 = undefined;
        std.mem.writeInt(u128, &cluster_bytes, cluster_id, .little);

        const status = tb_client_init(
            &self.client,
            &cluster_bytes,
            address.ptr,
            @intCast(address.len),
            completion_ctx,
            completion_callback,
        );

        switch (status) {
            .success => {
                self.connected = true;
                return;
            },
            .unexpected => return error.Unexpected,
            .out_of_memory => return error.OutOfMemory,
            .address_invalid => return error.AddressInvalid,
            .address_limit_exceeded => return error.AddressLimitExceeded,
            .system_resources => return error.SystemResources,
            .network_subsystem => return error.NetworkSubsystem,
            _ => return error.Unexpected,
        }
    }

    /// Initialize an echo client (for testing)
    pub fn initEcho(
        cluster_id: u128,
        address: []const u8,
        completion_ctx: usize,
        completion_callback: CompletionFn,
    ) TBClientError!Self {
        var self = Self{};

        var cluster_bytes: [16]u8 = undefined;
        std.mem.writeInt(u128, &cluster_bytes, cluster_id, .little);

        const status = tb_client_init_echo(
            &self.client,
            &cluster_bytes,
            address.ptr,
            @intCast(address.len),
            completion_ctx,
            completion_callback,
        );

        switch (status) {
            .success => {
                self.connected = true;
                return self;
            },
            .unexpected => return error.Unexpected,
            .out_of_memory => return error.OutOfMemory,
            .address_invalid => return error.AddressInvalid,
            .address_limit_exceeded => return error.AddressLimitExceeded,
            .system_resources => return error.SystemResources,
            .network_subsystem => return error.NetworkSubsystem,
            _ => return error.Unexpected,
        }
    }

    /// Initialize an echo client in-place (for testing)
    /// IMPORTANT: Same as initInPlace - must be at final memory location.
    pub fn initEchoInPlace(
        self: *Self,
        cluster_id: u128,
        address: []const u8,
        completion_ctx: usize,
        completion_callback: CompletionFn,
    ) TBClientError!void {
        self.* = Self{};

        var cluster_bytes: [16]u8 = undefined;
        std.mem.writeInt(u128, &cluster_bytes, cluster_id, .little);

        const status = tb_client_init_echo(
            &self.client,
            &cluster_bytes,
            address.ptr,
            @intCast(address.len),
            completion_ctx,
            completion_callback,
        );

        switch (status) {
            .success => {
                self.connected = true;
                return;
            },
            .unexpected => return error.Unexpected,
            .out_of_memory => return error.OutOfMemory,
            .address_invalid => return error.AddressInvalid,
            .address_limit_exceeded => return error.AddressLimitExceeded,
            .system_resources => return error.SystemResources,
            .network_subsystem => return error.NetworkSubsystem,
            _ => return error.Unexpected,
        }
    }

    /// Deinitialize the client
    pub fn deinit(self: *Self) void {
        if (self.connected) {
            _ = tb_client_deinit(&self.client);
            self.connected = false;
        }
    }

    /// Submit a packet for processing
    pub fn submit(self: *Self, packet: *Packet) TBClientError!void {
        if (!self.connected) {
            return error.ClientInvalid;
        }

        const status = tb_client_submit(&self.client, packet);

        switch (status) {
            .ok => return,
            .invalid => return error.ClientInvalid,
        }
    }

    /// Helper: Submit create_accounts request
    pub fn createAccounts(self: *Self, packet: *Packet, accounts: []const Account) TBClientError!void {
        packet.setOperation(.create_accounts);
        packet.data = @ptrCast(@constCast(accounts.ptr));
        packet.data_size = @intCast(accounts.len * @sizeOf(Account));
        return self.submit(packet);
    }

    /// Helper: Submit create_transfers request
    pub fn createTransfers(self: *Self, packet: *Packet, transfers: []const Transfer) TBClientError!void {
        packet.setOperation(.create_transfers);
        packet.data = @ptrCast(@constCast(transfers.ptr));
        packet.data_size = @intCast(transfers.len * @sizeOf(Transfer));
        return self.submit(packet);
    }

    /// Helper: Submit lookup_accounts request
    pub fn lookupAccounts(self: *Self, packet: *Packet, ids: []const u128) TBClientError!void {
        packet.setOperation(.lookup_accounts);
        packet.data = @ptrCast(@constCast(ids.ptr));
        packet.data_size = @intCast(ids.len * @sizeOf(u128));
        return self.submit(packet);
    }

    /// Helper: Submit lookup_transfers request
    pub fn lookupTransfers(self: *Self, packet: *Packet, ids: []const u128) TBClientError!void {
        packet.setOperation(.lookup_transfers);
        packet.data = @ptrCast(@constCast(ids.ptr));
        packet.data_size = @intCast(ids.len * @sizeOf(u128));
        return self.submit(packet);
    }

    /// Helper: Submit query_accounts request
    pub fn queryAccounts(self: *Self, packet: *Packet, filter: *const QueryFilter) TBClientError!void {
        packet.setOperation(.query_accounts);
        packet.data = @ptrCast(@constCast(filter));
        packet.data_size = @sizeOf(QueryFilter);
        return self.submit(packet);
    }

    /// Helper: Submit query_transfers request
    pub fn queryTransfers(self: *Self, packet: *Packet, filter: *const QueryFilter) TBClientError!void {
        packet.setOperation(.query_transfers);
        packet.data = @ptrCast(@constCast(filter));
        packet.data_size = @sizeOf(QueryFilter);
        return self.submit(packet);
    }

    /// Helper: Submit get_account_transfers request
    pub fn getAccountTransfers(self: *Self, packet: *Packet, filter: *const AccountFilter) TBClientError!void {
        packet.setOperation(.get_account_transfers);
        packet.data = @ptrCast(@constCast(filter));
        packet.data_size = @sizeOf(AccountFilter);
        return self.submit(packet);
    }

    /// Helper: Submit get_account_balances request
    pub fn getAccountBalances(self: *Self, packet: *Packet, filter: *const AccountFilter) TBClientError!void {
        packet.setOperation(.get_account_balances);
        packet.data = @ptrCast(@constCast(filter));
        packet.data_size = @sizeOf(AccountFilter);
        return self.submit(packet);
    }
};

// =============================================================================
// Result Parsing Helpers
// =============================================================================

pub fn parseAccounts(data: ?[*]const u8, len: u32) []const Account {
    if (data == null or len == 0) return &.{};
    const count = len / @sizeOf(Account);
    const ptr: [*]const Account = @ptrCast(@alignCast(data.?));
    return ptr[0..count];
}

pub fn parseTransfers(data: ?[*]const u8, len: u32) []const Transfer {
    if (data == null or len == 0) return &.{};
    const count = len / @sizeOf(Transfer);
    const ptr: [*]const Transfer = @ptrCast(@alignCast(data.?));
    return ptr[0..count];
}

pub fn parseCreateAccountsResults(data: ?[*]const u8, len: u32) []const CreateAccountsResult {
    if (data == null or len == 0) return &.{};
    const count = len / @sizeOf(CreateAccountsResult);
    const ptr: [*]const CreateAccountsResult = @ptrCast(@alignCast(data.?));
    return ptr[0..count];
}

pub fn parseCreateTransfersResults(data: ?[*]const u8, len: u32) []const CreateTransfersResult {
    if (data == null or len == 0) return &.{};
    const count = len / @sizeOf(CreateTransfersResult);
    const ptr: [*]const CreateTransfersResult = @ptrCast(@alignCast(data.?));
    return ptr[0..count];
}

pub fn parseAccountBalances(data: ?[*]const u8, len: u32) []const AccountBalance {
    if (data == null or len == 0) return &.{};
    const count = len / @sizeOf(AccountBalance);
    const ptr: [*]const AccountBalance = @ptrCast(@alignCast(data.?));
    return ptr[0..count];
}

// =============================================================================
// Constants
// =============================================================================

pub const MAX_BATCH_SIZE: u32 = 8190;
pub const MAX_MESSAGE_SIZE: u32 = 1024 * 1024;

// =============================================================================
// Tests
// =============================================================================

test "Account struct size" {
    try std.testing.expectEqual(@as(usize, 128), @sizeOf(Account));
}

test "Transfer struct size" {
    try std.testing.expectEqual(@as(usize, 128), @sizeOf(Transfer));
}

test "AccountFlags" {
    const flags = AccountFlags{ .linked = true, .history = true };
    try std.testing.expect(flags.linked);
    try std.testing.expect(flags.history);
    try std.testing.expect(!flags.closed);
}

test "Account balance calculation" {
    const account = Account{
        .id = 1,
        .debits_pending = 0,
        .debits_posted = 500,
        .credits_pending = 0,
        .credits_posted = 1000,
        .user_data_128 = 0,
        .user_data_64 = 0,
        .user_data_32 = 0,
        .reserved = 0,
        .ledger = 1,
        .code = 1,
        .flags = .{},
        .timestamp = 0,
    };
    try std.testing.expectEqual(@as(i128, 500), account.balance());
}
