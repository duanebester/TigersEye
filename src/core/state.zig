//! Application State Management for TigersEye
//!
//! This module contains the central AppState struct and all state management logic:
//! - Connection management (connect, disconnect)
//! - Operation state machine (beginOperation, completeOperation, failOperation)
//! - Query operations (queryAccounts, refreshAccounts)
//! - Create operations (createAccount, createTransfer)
//! - Thread dispatch for main thread UI updates
//! - Entity synchronization

const std = @import("std");
const log = std.log.scoped(.tigerseye);
const gooey = @import("gooey");
const platform = gooey.platform;
const tb = @import("tigerbeetle");

const Cx = gooey.Cx;
const UniformListState = gooey.UniformListState;

// Internal modules (updated paths for core/ location)
const types = @import("types.zig");
const theme = @import("theme.zig");
const tb_client = @import("../tigerbeetle/client.zig");

// Re-export types for convenience
pub const ConnectionState = types.ConnectionState;
pub const Operation = types.Operation;
pub const OperationResult = types.OperationResult;
pub const Account = types.Account;
pub const Transfer = types.Transfer;

// Platform-specific dispatcher for thread-safe UI updates
const Dispatcher = platform.mac.dispatcher.Dispatcher;

// =============================================================================
// AppState
// =============================================================================

pub const AppState = struct {
    const Self = @This();

    // =========================================================================
    // Connection State (Phase 1: single source of truth)
    // =========================================================================
    connection: ConnectionState = .disconnected,
    current_op: Operation = .none,
    server_address: []const u8 = tb_client.DEFAULT_ADDRESS,

    // =========================================================================
    // Error Handling
    // =========================================================================
    last_error: ?[]const u8 = null,

    // =========================================================================
    // TigerBeetle Client
    // =========================================================================
    client: ?*tb.TBClient = null,
    packet_pool: tb_client.PacketPool = .{},
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
        .limit = tb_client.MAX_ACCOUNTS,
        .flags = .{},
    },

    // =========================================================================
    // Account Data (Phase 4: Entity-based)
    // =========================================================================
    accounts: [tb_client.MAX_ACCOUNTS]gooey.Entity(Account) = [_]gooey.Entity(Account){gooey.Entity(Account).nil()} ** tb_client.MAX_ACCOUNTS,
    account_count: usize = 0,

    // Staging area for results from IO thread
    pending_accounts: [tb_client.MAX_ACCOUNTS]tb.Account = undefined,
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
    // Transfer History State
    // =========================================================================
    transfer_history: [tb_client.MAX_TRANSFERS]Transfer = undefined,
    transfer_history_count: usize = 0,
    transfer_history_account_id: ?u128 = null, // Account ID for which history is loaded

    // Staging area for transfer results from IO thread
    pending_transfers: [tb_client.MAX_TRANSFERS]tb.Transfer = undefined,
    pending_transfer_count: usize = 0,

    // Account filter for querying transfers
    account_filter: tb.AccountFilter = .{
        .account_id = 0,
        .user_data_128 = 0,
        .user_data_64 = 0,
        .user_data_32 = 0,
        .code = 0,
        .reserved = [_]u8{0} ** 58,
        .timestamp_min = 0,
        .timestamp_max = 0,
        .limit = tb_client.MAX_TRANSFERS,
        .flags = .{ .debits = true, .credits = true, .reversed = true }, // Most recent first
    },

    // =========================================================================
    // UI State
    // =========================================================================
    list_state: UniformListState = UniformListState.init(0, theme.ACCOUNT_ROW_HEIGHT),
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
    pub fn canSubmit(self: *const Self) bool {
        return self.connection.canSubmit() and !self.current_op.isActive();
    }

    /// Begin a new operation. Returns error if not ready or busy.
    fn beginOperation(self: *Self, op: Operation) error{ NotReady, Busy }!void {
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
    fn completeOperation(self: *Self) void {
        // Assertion: must have an active operation
        std.debug.assert(self.current_op.isActive());

        log.debug("completeOperation({s}): completed", .{self.current_op.name()});
        self.current_op = .none;
    }

    /// Fail the current operation with an error message
    fn failOperation(self: *Self, msg: []const u8) void {
        log.err("failOperation({s}): {s}", .{ self.current_op.name(), msg });
        self.last_error = msg;
        self.current_op = .none;
    }

    /// Check if we should rate limit (TB IO thread needs settling time)
    fn shouldRateLimit(self: *const Self) bool {
        const last = self.last_callback_timestamp_ns.load(.acquire);
        if (last == 0) return false;

        const now: i128 = std.time.nanoTimestamp();
        return (now - last) < tb_client.MIN_CALLBACK_GAP_NS;
    }

    // =========================================================================
    // Connection Commands
    // =========================================================================

    pub fn connect(self: *Self, g: *gooey.Gooey) void {
        // Guard: already connected or connecting
        if (self.connection != .disconnected) {
            log.debug("connect: already in state {}", .{self.connection});
            return;
        }

        log.info("Connecting to TigerBeetle...", .{});
        self.connection = .connecting;
        self.gooey_ptr = g;

        // Register log callback for debugging
        _ = tb.registerLogCallback(tb_client.tbLogCallback, true);

        // Allocate client on heap (CRITICAL: must not move after init)
        const client_ptr = self.allocator.create(tb.TBClient) catch |err| {
            log.err("Failed to allocate TBClient: {}", .{err});
            self.connection = .disconnected;
            self.last_error = "Failed to allocate client";
            return;
        };

        // Initialize client in-place at its final location
        const init_fn = if (tb_client.USE_ECHO_CLIENT) tb.TBClient.initEchoInPlace else tb.TBClient.initInPlace;
        init_fn(
            client_ptr,
            0, // cluster_id
            self.server_address,
            @intFromPtr(self),
            tb_client.createCompletionCallback(Self),
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

    pub fn disconnect(self: *Self, _: *gooey.Gooey) void {
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

    pub fn refreshAccounts(self: *Self, g: *gooey.Gooey) void {
        self.queryAccounts(g);
    }

    pub fn queryAccounts(self: *Self, g: *gooey.Gooey) void {
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
            const Ctx = struct { app: *Self, g: *gooey.Gooey };
            self.dispatcher.dispatchAfter(
                tb_client.SETTLE_DELAY_NS,
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
        packet.user_tag = tb_client.REQUEST_TAG_QUERY_ACCOUNTS;

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

    pub fn createAccount(self: *Self, g: *gooey.Gooey) void {
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

        packet.user_tag = tb_client.REQUEST_TAG_CREATE_ACCOUNTS;

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

    pub fn createTransfer(self: *Self, g: *gooey.Gooey) void {
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
        const amount: u128 = tb_client.parseDollarsToCents(self.transfer_amount) orelse {
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
        const Ctx = struct { app: *Self, g: *gooey.Gooey };
        self.dispatcher.dispatchAfter(
            tb_client.SETTLE_DELAY_NS,
            Ctx,
            .{ .app = self, .g = g },
            struct {
                fn doSubmit(ctx: *Ctx) void {
                    const packet = ctx.app.packet_pool.acquire() orelse {
                        ctx.app.failOperation("No packets available");
                        return;
                    };

                    packet.user_tag = tb_client.REQUEST_TAG_CREATE_TRANSFERS;

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

    pub fn clearTransferInput(self: *Self, g: *gooey.Gooey) void {
        if (g.textInput("transfer-amount")) |input| {
            input.clear();
        }
        self.transfer_amount = "";
        self.transfer_success = false;
        self.transfer_error_msg = null;
    }

    pub fn selectAccount(self: *Self, index: u32) void {
        if (index < self.account_count) {
            const prev_index = self.selected_index;
            self.selected_index = index;

            // Auto-fetch transfer history if selecting a different account
            if (prev_index == null or prev_index.? != index) {
                // Get the account ID from entity system
                const entity = self.accounts[index];
                if (self.gooey_ptr) |gp| {
                    if (gp.readEntity(Account, entity)) |acc| {
                        // Only fetch if we don't already have history for this account
                        if (self.transfer_history_account_id == null or
                            self.transfer_history_account_id.? != acc.id)
                        {
                            self.getAccountTransfers(acc.id);
                        }
                    }
                }
            }
        }
    }

    /// Fetch transfer history for a specific account
    pub fn getAccountTransfers(self: *Self, account_id: u128) void {
        // Guard: state machine check
        self.beginOperation(.{ .get_account_transfers = .{ .account_id = account_id } }) catch |err| {
            switch (err) {
                error.NotReady => log.debug("getAccountTransfers: not connected", .{}),
                error.Busy => log.debug("getAccountTransfers: operation in progress", .{}),
            }
            return;
        };

        // Set up the account filter
        self.account_filter.account_id = account_id;

        // Acquire packet
        const packet = self.packet_pool.acquire() orelse {
            self.failOperation("No packets available");
            return;
        };

        packet.user_tag = tb_client.REQUEST_TAG_GET_ACCOUNT_TRANSFERS;

        const client = self.client orelse {
            self.packet_pool.release(packet);
            self.failOperation("Client not connected");
            return;
        };

        client.getAccountTransfers(packet, &self.account_filter) catch |err| {
            self.packet_pool.release(packet);
            self.failOperation(switch (err) {
                error.ClientInvalid => "Client invalid",
                else => "Get account transfers failed",
            });
            return;
        };

        log.info("Fetching transfers for account: {x}", .{account_id});
    }

    /// Refresh transfer history for the currently selected account
    pub fn refreshTransferHistory(self: *Self, _: *gooey.Gooey) void {
        // Get the selected account
        const selected_account = self.getSelectedAccountEntity() orelse return;
        if (self.gooey_ptr) |gp| {
            if (gp.readEntity(Account, selected_account)) |acc| {
                self.getAccountTransfers(acc.id);
            }
        }
    }

    /// Get the selected account entity (if any)
    pub fn getSelectedAccountEntity(self: *const Self) ?gooey.Entity(Account) {
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

    const DispatchCtx = struct { app: *Self };

    pub fn dispatchToMain(self: *Self) void {
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

        // Guard: if disconnected, the callback arrived after disconnect() cleared state.
        // This is a race condition when user disconnects quickly - just ignore the stale callback.
        if (s.connection == .disconnected) {
            log.debug("dispatchHandler: ignoring stale callback after disconnect", .{});
            s.pending_result = null;
            return;
        }

        // Apply pending result if present
        // applyResult returns true if it already completed the operation (e.g., triggered a refresh)
        var already_completed = false;
        if (s.pending_result) |result| {
            already_completed = s.applyResult(g, result);
            s.pending_result = null;
        }

        // Only complete if operation is still active (disconnect may have cleared it)
        if (!already_completed and s.current_op.isActive()) {
            s.completeOperation();
        }
        g.requestRender();
    }

    /// Apply an operation result to the app state (main thread only).
    /// Returns true if the operation was already completed (e.g., triggered a follow-up operation).
    fn applyResult(self: *Self, g: *gooey.Gooey, result: OperationResult) bool {
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
            .get_account_transfers => |r| {
                // Sync transfer history from pending buffer
                self.syncTransferHistory(r.count);
                return false;
            },
        }
    }

    /// Sync transfer history from pending_transfers buffer (main thread only).
    fn syncTransferHistory(self: *Self, count: usize) void {
        // Assertion: count within bounds
        std.debug.assert(count <= tb_client.MAX_TRANSFERS);

        // Get current operation context for account ID
        const account_id: ?u128 = switch (self.current_op) {
            .get_account_transfers => |ctx| ctx.account_id,
            else => null,
        };

        // Convert TB transfers to app transfers
        for (self.pending_transfers[0..count], 0..) |tb_transfer, i| {
            self.transfer_history[i] = Transfer.fromTB(tb_transfer);
        }

        self.transfer_history_count = count;
        self.transfer_history_account_id = account_id;
        log.info("Synced {} transfers for account {?x}", .{ count, account_id });
    }

    // =========================================================================
    // Entity Sync (Phase 4)
    // =========================================================================

    /// Sync account entities from pending_accounts buffer (main thread only).
    /// Removes old entities and creates new ones from the TB response.
    fn syncAccountEntities(self: *Self, g: *gooey.Gooey, count: usize) void {
        // Assertion: count within bounds
        std.debug.assert(count <= tb_client.MAX_ACCOUNTS);

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
                for (self.accounts[i..tb_client.MAX_ACCOUNTS]) |*slot| {
                    slot.* = gooey.Entity(Account).nil();
                }
                self.account_count = i;
                self.list_state = UniformListState.init(@intCast(self.account_count), theme.ACCOUNT_ROW_HEIGHT);
                return;
            };
        }

        // Clear any remaining slots
        for (self.accounts[count..tb_client.MAX_ACCOUNTS]) |*slot| {
            slot.* = gooey.Entity(Account).nil();
        }

        self.account_count = count;
        self.list_state = UniformListState.init(@intCast(self.account_count), theme.ACCOUNT_ROW_HEIGHT);
        log.info("Synced {} account entities", .{self.account_count});
    }

    /// Get account data by index (reads from entity system)
    pub fn getAccountAt(self: *const Self, g: *gooey.Gooey, index: usize) ?*const Account {
        if (index >= self.account_count) return null;
        const entity = self.accounts[index];
        return g.readEntity(Account, entity);
    }
};
