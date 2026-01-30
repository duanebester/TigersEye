# TigerBeetle + Gooey Integration Plan

## Overview

This document outlines the plan for integrating TigerBeetle's Zig client with Gooey on macOS, using GCD (Grand Central Dispatch) for thread-safe async operations and Gooey's built-in `command`/`defer` patterns for clean state management.

## Architecture

```
┌─────────────────────────────────────────────────────────────────┐
│  UI Event (button click)                                         │
│    ↓ cx.command(AppState, refreshAccounts)                       │
├─────────────────────────────────────────────────────────────────┤
│  TBClient.lookupAccounts(ids, REQUEST_TAG_ACCOUNTS)              │
│    ↓ (async, TigerBeetle IO thread)                              │
├─────────────────────────────────────────────────────────────────┤
│  onCompletion → dispatcher.dispatchOnMainThread                  │
│    ↓ (main thread)                                               │
├─────────────────────────────────────────────────────────────────┤
│  gooey.deferCommandWith(AppState, response, onAccountsLoaded)    │
│    ↓ (runs after event flush)                                    │
│  AppState.onAccountsLoaded(self, g, response) → render           │
└─────────────────────────────────────────────────────────────────┘
```

## Key Insight: Gooey's Command/Defer System

Gooey provides a complete solution for async state updates without global state:

```zig
// Initiate async operation from UI event
cx.command(AppState, AppState.refreshAccounts)

// Handle async completion (runs after current event handling)
g.deferCommandWith(AppState, response, AppState.onAccountsLoaded)
```

This eliminates the need for:

- ❌ HashMap of callbacks
- ❌ Mutex for callback registration
- ❌ Global state references

## GCD Dispatcher

Gooey has a GCD-based dispatcher at `gooey.platform.mac.dispatcher`:

```zig
const Dispatcher = gooey.platform.mac.dispatcher.Dispatcher;

// Dispatch work to main thread from any thread
dispatcher.dispatchOnMainThread(Context, context, callback);

// Dispatch to background thread
dispatcher.dispatch(Context, context, callback);

// Check current thread
Dispatcher.isMainThread();
```

The dispatcher heap-allocates and copies the context, so it's safe to pass stack values.

## Integration Pattern

### The Problem

TigerBeetle's completion callback runs on its **IO thread**:

```zig
fn onCompletion(ctx: usize, packet: *tb_packet_t, timestamp: u64, result: ?[*]const u8, result_size: u32) callconv(.c) void {
    // ⚠️ This is NOT the main thread!
    // Cannot safely touch AppState or call requestRender() here
}
```

### The Solution

Use GCD to dispatch from IO thread → main thread, then use Gooey's `deferCommandWith` to update state:

```zig
fn onCompletion(
    ctx: usize,
    packet: *tb_packet_t,
    timestamp: u64,
    result: ?[*]const u8,
    result_size: u32,
) callconv(.c) void {
    const self: *TBClient = @ptrFromInt(ctx);

    // Assertions per CLAUDE.md
    std.debug.assert(!Dispatcher.isMainThread());
    std.debug.assert(result_size <= MAX_RESULT_BYTES);

    // Parse result on IO thread (CPU work, no UI access)
    const response = parseResponse(packet.operation, result, result_size, timestamp);

    // GCD copies context and runs callback on main thread
    self.dispatcher.dispatchOnMainThread(CompletionCtx, .{
        .gooey = self.gooey_ctx,
        .request_tag = packet.user_tag,
        .response = response,
    }, handleOnMain) catch {};

    // Release packet back to pool
    self.packet_pool.release(packet);
}

fn handleOnMain(ctx: *CompletionCtx) void {
    // Assertion: verify we're on main thread
    std.debug.assert(Dispatcher.isMainThread());

    // Route to appropriate handler using request tag (no callback map needed!)
    switch (ctx.request_tag) {
        REQUEST_TAG_LOOKUP_ACCOUNTS => {
            ctx.gooey.deferCommandWith(AppState, ctx.response, AppState.onAccountsLoaded);
        },
        REQUEST_TAG_LOOKUP_TRANSFERS => {
            ctx.gooey.deferCommandWith(AppState, ctx.response, AppState.onTransfersLoaded);
        },
        REQUEST_TAG_CREATE_ACCOUNTS => {
            ctx.gooey.deferCommandWith(AppState, ctx.response, AppState.onAccountsCreated);
        },
        REQUEST_TAG_CREATE_TRANSFERS => {
            ctx.gooey.deferCommandWith(AppState, ctx.response, AppState.onTransfersCreated);
        },
        else => unreachable,
    }
}
```

## Critical Implementation Gotchas

These are hard-won lessons from debugging the TigerBeetle integration. Each caused subtle bugs that were difficult to diagnose.

### 1. TBClient Must Be Initialized In-Place (No Struct Movement)

**Problem**: TigerBeetle's C library stores internal pointers in the opaque `_opaque` field during `tb_client_init()`. If you initialize the `TBClient` struct on the stack and then copy/move it to its final location, those internal pointers become stale. **Callbacks will silently never fire.**

This is extremely difficult to debug because:

- `tb_client_submit()` returns success
- TigerBeetle's internal logs show the request being queued
- No errors are reported anywhere
- The callback simply never gets called

```zig
// ❌ BAD: Struct is initialized on stack, then moved to heap
// Internal pointers in _opaque now point to invalid stack memory!
const client_ptr = try allocator.create(tb.TBClient);
client_ptr.* = try tb.TBClient.init(
    cluster_id,
    address,
    @intFromPtr(ctx),
    completionCallback,
);

// ✅ GOOD: Initialize directly at the final memory location
const client_ptr = try allocator.create(tb.TBClient);
try client_ptr.initInPlace(
    cluster_id,
    address,
    @intFromPtr(ctx),
    completionCallback,
);
```

The `initInPlace` function calls `tb_client_init(&self.client, ...)` where `self` is already at its final heap address, so the internal pointers remain valid.

**Symptoms of this bug:**

- Everything appears to work (connection succeeds, submit succeeds)
- TigerBeetle logs show requests being sent and replies received
- Your completion callback is never invoked
- Adding debug prints may "fix" the issue (timing/memory barrier side effects)

### 2. Data Lifetime for Async Operations

**Problem**: TigerBeetle's callback runs on a separate IO thread _after_ your function returns. Stack-allocated data will be garbage by then.

```zig
// ❌ BAD: Stack-allocated array - dangling pointer in callback!
pub fn createAccount(self: *AppState) void {
    const accounts = [_]tb.Account{.{ .id = new_id, ... }};
    self.client.createAccounts(packet, &accounts);  // returns immediately
    // accounts is deallocated here, but callback hasn't fired yet!
}

// ✅ GOOD: Store in AppState so it persists until callback
pub fn createAccount(self: *AppState) void {
    self.pending_new_account[0] = .{ .id = new_id, ... };
    self.client.createAccounts(packet, self.pending_new_account[0..]);
}
```

### 3. Explicit Slice Creation for FFI

**Problem**: Implicit coercion from `*[N]T` to `[]T` can fail silently when passed through C FFI boundaries.

```zig
// ❌ BAD: Implicit coercion - may not work correctly through FFI
self.client.createAccounts(packet, &self.pending_new_account);

// ✅ GOOD: Explicit slice creation
const accounts_slice: []const tb.Account = self.pending_new_account[0..];
self.client.createAccounts(packet, accounts_slice);
```

### 4. Request Sequencing with Atomic Counters

**Problem**: Submitting a new request before the previous callback fully completes can cause TigerBeetle's client to silently drop requests.

```zig
// In AppState:
request_sequence: std.atomic.Value(u32) = std.atomic.Value(u32).init(0),
last_completed_sequence: std.atomic.Value(u32) = std.atomic.Value(u32).init(0),

// Before submitting any request:
const current_seq = self.request_sequence.load(.acquire);
const completed_seq = self.last_completed_sequence.load(.acquire);
if (current_seq != completed_seq) {
    return;  // Previous request still pending
}
self.request_sequence.store(current_seq +% 1, .release);

// In callback, after processing:
const current_seq = self.request_sequence.load(.acquire);
self.last_completed_sequence.store(current_seq, .release);
```

### 5. Rate Limiting Between Requests

**Problem**: TigerBeetle's IO thread needs time to fully return from the callback before accepting new requests. Rapid-fire requests can cause hangs.

```zig
// In AppState:
last_callback_timestamp_ns: std.atomic.Value(i128) = std.atomic.Value(i128).init(0),

// Before submitting:
const MIN_CALLBACK_GAP_NS: i128 = 100_000_000; // 100ms
const last_callback = self.last_callback_timestamp_ns.load(.acquire);
if (last_callback > 0) {
    const now_ns: i128 = std.time.nanoTimestamp();
    if (now_ns - last_callback < MIN_CALLBACK_GAP_NS) {
        // Schedule retry after gap expires
        return;
    }
}

// In callback, after processing:
self.last_callback_timestamp_ns.store(std.time.nanoTimestamp(), .release);
```

### 6. Distinguish Operation Types in Main Thread Handler

**Problem**: The main thread handler receives callbacks for different operation types. Use flags to distinguish query results from create results.

```zig
// In dispatchToMain handler:
if (s.loading_accounts) {
    // This was a query_accounts callback
    // Apply pending_accounts to accounts
    s.loading_accounts = false;
    s.pending_operation = false;
} else if (s.pending_operation and !s.loading_accounts) {
    // This was a create_accounts callback (success case)
    s.pending_operation = false;
    // Optionally trigger a refresh to show new account
}
```

### 7. IO Thread Signaling Race Condition (Deferred Submission)

**Problem**: TigerBeetle's IO thread doesn't wake up properly when you submit a new request immediately after a callback completes. The request gets queued (`tb_client_submit` returns `.ok`) but the IO thread never processes it, causing the UI to hang indefinitely.

**Symptoms**:

- `tb_client_submit` returns `.ok` (request accepted)
- No `[TB-INTERNAL]` logs showing request processing
- No callback fires
- Server logs show no incoming request

**Root Cause**: After a callback completes, the IO thread returns to its wait state. If you submit a new request before the IO thread is fully ready to receive signals, the wake-up signal is lost.

```zig
// ❌ BAD: Submit immediately - IO thread may miss the signal
pub fn createTransfer(self: *AppState) void {
    // ... setup transfer ...
    self.client.createTransfers(packet, transfers);  // May hang forever!
}

// ✅ GOOD: Defer submission by ~50ms to let IO thread settle
pub fn createTransfer(self: *AppState) void {
    // ... setup transfer and acquire packet ...

    const SUBMIT_DELAY_NS: u64 = 50_000_000; // 50ms
    self.dispatcher.dispatchAfter(
        SUBMIT_DELAY_NS,
        SubmitCtx,
        .{ .app = self, .packet = packet },
        struct {
            fn doSubmit(ctx: *SubmitCtx) void {
                ctx.app.client.createTransfers(ctx.packet, ctx.app.pending_transfer[0..]) catch |err| {
                    // Handle error, release packet
                    return;
                };
            }
        }.doSubmit,
    ) catch { /* handle scheduling failure */ };
}
```

**Additional Safety**: Add a timeout to reset UI state if callback never fires:

```zig
// Schedule timeout (e.g., 5 seconds) after submission
const TIMEOUT_NS: u64 = 5_000_000_000;
self.dispatcher.dispatchAfter(TIMEOUT_NS, TimeoutCtx, .{ .app = self, .seq = expected_seq },
    struct {
        fn onTimeout(ctx: *TimeoutCtx) void {
            if (ctx.app.last_completed_sequence.load(.acquire) < ctx.seq) {
                ctx.app.pending_operation = false;
                ctx.app.error_msg = "Request timed out";
                ctx.app.gooey_ptr.?.requestRender();
            }
        }
    }.onTimeout,
) catch {};
```

### Debugging Tip: Thread ID Logging

When debugging async issues, always log thread IDs to verify which thread code runs on:

```zig
std.debug.print("[DEBUG] function called (thread={})\n", .{std.Thread.getCurrentId()});
```

## Constants & Limits

Per CLAUDE.md: "Put a limit on everything"

```zig
// Request routing tags (stored in packet.user_tag)
const REQUEST_TAG_LOOKUP_ACCOUNTS: u16 = 1;
const REQUEST_TAG_LOOKUP_TRANSFERS: u16 = 2;
const REQUEST_TAG_CREATE_ACCOUNTS: u16 = 3;
const REQUEST_TAG_CREATE_TRANSFERS: u16 = 4;
const REQUEST_TAG_GET_ACCOUNT_TRANSFERS: u16 = 5;
const REQUEST_TAG_GET_ACCOUNT_BALANCES: u16 = 6;
const REQUEST_TAG_QUERY_ACCOUNTS: u16 = 7;
const REQUEST_TAG_QUERY_TRANSFERS: u16 = 8;

// Capacity limits
const MAX_ACCOUNTS: usize = 1024;
const MAX_TRANSFERS: usize = 4096;
const MAX_PENDING_REQUESTS: usize = 64;
const MAX_RESULT_BYTES: u32 = 8192 * 128;  // ~1MB max batch response
const MAX_BATCH_SIZE: usize = 8190;        // TigerBeetle's actual batch limit
const SERVER_ADDRESS_MAX_LEN: usize = 256;
```

## Implementation Plan

### Phase 1: Packet Pool (Static Allocation)

Per CLAUDE.md: "No dynamic allocation after initialization"

```zig
const PacketPool = struct {
    packets: [MAX_PENDING_REQUESTS]tb_packet_t = undefined,
    free_mask: u64 = std.math.maxInt(u64),

    pub fn acquire(self: *PacketPool) ?*tb_packet_t {
        const idx = @ctz(self.free_mask);
        if (idx >= MAX_PENDING_REQUESTS) return null;
        self.free_mask &= ~(@as(u64, 1) << @intCast(idx));
        return &self.packets[idx];
    }

    pub fn release(self: *PacketPool, packet: *tb_packet_t) void {
        const base = @intFromPtr(&self.packets);
        const ptr = @intFromPtr(packet);
        const idx = (ptr - base) / @sizeOf(tb_packet_t);

        std.debug.assert(idx < MAX_PENDING_REQUESTS);
        std.debug.assert(self.free_mask & (@as(u64, 1) << @intCast(idx)) == 0);

        self.free_mask |= @as(u64, 1) << @intCast(idx);
    }

    pub fn availableCount(self: *const PacketPool) u32 {
        return @popCount(self.free_mask);
    }
};
```

### Phase 2: TBClient Wrapper

Create `src/tigerbeetle/client.zig`:

```zig
const std = @import("std");
const gooey = @import("gooey");
const Gooey = gooey.Gooey;
const Dispatcher = gooey.platform.mac.dispatcher.Dispatcher;

pub const TBClient = struct {
    const Self = @This();

    client: tb_client_t,
    dispatcher: Dispatcher,
    allocator: std.mem.Allocator,
    packet_pool: PacketPool,
    gooey_ctx: *Gooey,

    pub const Response = union(enum) {
        accounts: struct {
            items: []const tb_account_t,
            timestamp: u64,
        },
        transfers: struct {
            items: []const tb_transfer_t,
            timestamp: u64,
        },
        create_accounts: struct {
            results: []const tb_create_accounts_result_t,
            timestamp: u64,
        },
        create_transfers: struct {
            results: []const tb_create_transfers_result_t,
            timestamp: u64,
        },
        err: TB_PACKET_STATUS,
    };

    pub fn init(allocator: std.mem.Allocator, g: *Gooey, cluster_id: u128, addresses: []const u8) !*Self {
        std.debug.assert(addresses.len > 0);
        std.debug.assert(addresses.len <= SERVER_ADDRESS_MAX_LEN);

        const self = try allocator.create(Self);
        errdefer allocator.destroy(self);

        self.* = .{
            .client = undefined,
            .dispatcher = Dispatcher.init(allocator),
            .allocator = allocator,
            .packet_pool = .{},
            .gooey_ctx = g,
        };

        // Initialize TigerBeetle client
        var cluster_bytes: [16]u8 = undefined;
        std.mem.writeInt(u128, &cluster_bytes, cluster_id, .little);

        const status = tb_client_init(
            &self.client,
            &cluster_bytes,
            addresses.ptr,
            @intCast(addresses.len),
            @intFromPtr(self),
            Self.onCompletion,
        );

        if (status != .TB_INIT_SUCCESS) {
            allocator.destroy(self);
            return error.TigerBeetleInitFailed;
        }

        return self;
    }

    pub fn deinit(self: *Self) void {
        _ = tb_client_deinit(&self.client);
        self.allocator.destroy(self);
    }

    /// Called on TigerBeetle IO thread
    fn onCompletion(
        ctx: usize,
        packet: *tb_packet_t,
        timestamp: u64,
        result: ?[*]const u8,
        result_size: u32,
    ) callconv(.c) void {
        const self: *Self = @ptrFromInt(ctx);

        // Assertions: validate IO thread context
        std.debug.assert(!Dispatcher.isMainThread());
        std.debug.assert(result_size <= MAX_RESULT_BYTES);

        // Parse response (CPU work on IO thread)
        const response: Response = if (packet.status != .TB_PACKET_OK)
            .{ .err = packet.status }
        else
            parseResponse(packet.operation, result, result_size, timestamp);

        // Dispatch to main thread
        self.dispatcher.dispatchOnMainThread(CompletionCtx, .{
            .gooey = self.gooey_ctx,
            .request_tag = packet.user_tag,
            .response = response,
            .pool = &self.packet_pool,
            .packet = packet,
        }, handleOnMain) catch {
            // If dispatch fails, still release the packet
            self.packet_pool.release(packet);
        };
    }

    const CompletionCtx = struct {
        gooey: *Gooey,
        request_tag: u16,
        response: Response,
        pool: *PacketPool,
        packet: *tb_packet_t,
    };

    /// Runs on main thread
    fn handleOnMain(ctx: *CompletionCtx) void {
        // Assertion: verify main thread
        std.debug.assert(Dispatcher.isMainThread());

        // Release packet back to pool
        ctx.pool.release(ctx.packet);

        // Route response to appropriate state handler
        switch (ctx.request_tag) {
            REQUEST_TAG_LOOKUP_ACCOUNTS => {
                ctx.gooey.deferCommandWith(AppState, ctx.response, AppState.onAccountsLoaded);
            },
            REQUEST_TAG_LOOKUP_TRANSFERS => {
                ctx.gooey.deferCommandWith(AppState, ctx.response, AppState.onTransfersLoaded);
            },
            REQUEST_TAG_CREATE_ACCOUNTS => {
                ctx.gooey.deferCommandWith(AppState, ctx.response, AppState.onAccountsCreated);
            },
            REQUEST_TAG_CREATE_TRANSFERS => {
                ctx.gooey.deferCommandWith(AppState, ctx.response, AppState.onTransfersCreated);
            },
            else => {
                std.log.warn("Unknown request tag: {}", .{ctx.request_tag});
            },
        }
    }

    fn parseResponse(operation: TB_OPERATION, result: ?[*]const u8, result_size: u32, timestamp: u64) Response {
        const data = result orelse return .{ .err = .TB_PACKET_INVALID_DATA_SIZE };

        return switch (operation) {
            .TB_OPERATION_LOOKUP_ACCOUNTS => .{
                .accounts = .{
                    .items = std.mem.bytesAsSlice(tb_account_t, data[0..result_size]),
                    .timestamp = timestamp,
                },
            },
            .TB_OPERATION_LOOKUP_TRANSFERS => .{
                .transfers = .{
                    .items = std.mem.bytesAsSlice(tb_transfer_t, data[0..result_size]),
                    .timestamp = timestamp,
                },
            },
            .TB_OPERATION_CREATE_ACCOUNTS => .{
                .create_accounts = .{
                    .results = std.mem.bytesAsSlice(tb_create_accounts_result_t, data[0..result_size]),
                    .timestamp = timestamp,
                },
            },
            .TB_OPERATION_CREATE_TRANSFERS => .{
                .create_transfers = .{
                    .results = std.mem.bytesAsSlice(tb_create_transfers_result_t, data[0..result_size]),
                    .timestamp = timestamp,
                },
            },
            else => .{ .err = .TB_PACKET_INVALID_OPERATION },
        };
    }

    // =========================================================================
    // Public API
    // =========================================================================

    pub fn lookupAccounts(self: *Self, ids: []const u128) !void {
        std.debug.assert(ids.len > 0);
        std.debug.assert(ids.len <= MAX_BATCH_SIZE);

        const packet = self.packet_pool.acquire() orelse return error.NoPacketsAvailable;
        packet.* = .{
            .user_data = null,
            .data = @ptrCast(ids.ptr),
            .data_size = @intCast(ids.len * @sizeOf(u128)),
            .user_tag = REQUEST_TAG_LOOKUP_ACCOUNTS,
            .operation = @intFromEnum(TB_OPERATION.TB_OPERATION_LOOKUP_ACCOUNTS),
            .status = 0,
            .opaque = undefined,
        };

        const status = tb_client_submit(&self.client, packet);
        if (status != .TB_CLIENT_OK) {
            self.packet_pool.release(packet);
            return error.SubmitFailed;
        }
    }

    pub fn createAccounts(self: *Self, accounts: []const tb_account_t) !void {
        std.debug.assert(accounts.len > 0);
        std.debug.assert(accounts.len <= MAX_BATCH_SIZE);

        const packet = self.packet_pool.acquire() orelse return error.NoPacketsAvailable;
        packet.* = .{
            .user_data = null,
            .data = @ptrCast(accounts.ptr),
            .data_size = @intCast(accounts.len * @sizeOf(tb_account_t)),
            .user_tag = REQUEST_TAG_CREATE_ACCOUNTS,
            .operation = @intFromEnum(TB_OPERATION.TB_OPERATION_CREATE_ACCOUNTS),
            .status = 0,
            .opaque = undefined,
        };

        const status = tb_client_submit(&self.client, packet);
        if (status != .TB_CLIENT_OK) {
            self.packet_pool.release(packet);
            return error.SubmitFailed;
        }
    }

    pub fn createTransfers(self: *Self, transfers: []const tb_transfer_t) !void {
        std.debug.assert(transfers.len > 0);
        std.debug.assert(transfers.len <= MAX_BATCH_SIZE);

        const packet = self.packet_pool.acquire() orelse return error.NoPacketsAvailable;
        packet.* = .{
            .user_data = null,
            .data = @ptrCast(transfers.ptr),
            .data_size = @intCast(transfers.len * @sizeOf(tb_transfer_t)),
            .user_tag = REQUEST_TAG_CREATE_TRANSFERS,
            .operation = @intFromEnum(TB_OPERATION.TB_OPERATION_CREATE_TRANSFERS),
            .status = 0,
            .opaque = undefined,
        };

        const status = tb_client_submit(&self.client, packet);
        if (status != .TB_CLIENT_OK) {
            self.packet_pool.release(packet);
            return error.SubmitFailed;
        }
    }
};
```

### Phase 3: AppState Integration

Using Gooey's `cx.command()` and `deferCommandWith()` patterns:

```zig
const AppState = struct {
    // TigerBeetle client (null until connected)
    tb: ?*TBClient = null,

    // UI state - fixed-size arrays per CLAUDE.md
    accounts: [MAX_ACCOUNTS]tb_account_t = undefined,
    account_count: usize = 0,
    accounts_timestamp: u64 = 0,

    transfers: [MAX_TRANSFERS]tb_transfer_t = undefined,
    transfer_count: usize = 0,
    transfers_timestamp: u64 = 0,

    // Loading/error state
    loading_accounts: bool = false,
    loading_transfers: bool = false,
    error_msg: ?[]const u8 = null,

    // Connection state
    server_address: [SERVER_ADDRESS_MAX_LEN]u8 = undefined,
    server_address_len: usize = 0,
    connected: bool = false,

    // =========================================================================
    // Command Handlers (called via cx.command from UI)
    // =========================================================================

    /// Connect to TigerBeetle cluster
    /// Usage: cx.command(AppState, AppState.connect)
    pub fn connect(self: *AppState, g: *Gooey) void {
        if (self.tb != null) return;

        std.debug.assert(self.server_address_len > 0);
        std.debug.assert(self.server_address_len <= SERVER_ADDRESS_MAX_LEN);

        const addr = self.server_address[0..self.server_address_len];
        self.tb = TBClient.init(g.allocator, g, 0, addr) catch |e| {
            self.error_msg = @errorName(e);
            return;
        };
        self.connected = true;
        self.error_msg = null;
    }

    /// Disconnect from TigerBeetle cluster
    /// Usage: cx.command(AppState, AppState.disconnect)
    pub fn disconnect(self: *AppState, _: *Gooey) void {
        if (self.tb) |client| {
            client.deinit();
            self.tb = null;
        }
        self.connected = false;
        self.account_count = 0;
        self.transfer_count = 0;
    }

    /// Refresh accounts list
    /// Usage: cx.command(AppState, AppState.refreshAccounts)
    pub fn refreshAccounts(self: *AppState, _: *Gooey) void {
        const client = self.tb orelse return;
        if (self.loading_accounts) return;

        self.loading_accounts = true;
        self.error_msg = null;

        // Submit lookup request - response handled via deferCommandWith
        client.lookupAccounts(&watched_account_ids) catch |e| {
            self.loading_accounts = false;
            self.error_msg = @errorName(e);
        };
    }

    // =========================================================================
    // Deferred Handlers (called via deferCommandWith from TBClient)
    // =========================================================================

    /// Handle accounts lookup response
    /// Called by TBClient via: g.deferCommandWith(AppState, response, onAccountsLoaded)
    pub fn onAccountsLoaded(self: *AppState, _: *Gooey, response: TBClient.Response) void {
        self.loading_accounts = false;

        switch (response) {
            .accounts => |data| {
                std.debug.assert(data.items.len <= MAX_ACCOUNTS);

                self.account_count = @min(data.items.len, MAX_ACCOUNTS);
                @memcpy(
                    self.accounts[0..self.account_count],
                    data.items[0..self.account_count],
                );
                self.accounts_timestamp = data.timestamp;
                self.error_msg = null;
            },
            .err => |status| {
                self.error_msg = packetStatusMessage(status);
            },
            else => {
                self.error_msg = "Unexpected response type";
            },
        }
        // Note: requestRender() is called automatically by deferCommandWith
    }

    /// Handle transfers lookup response
    pub fn onTransfersLoaded(self: *AppState, _: *Gooey, response: TBClient.Response) void {
        self.loading_transfers = false;

        switch (response) {
            .transfers => |data| {
                std.debug.assert(data.items.len <= MAX_TRANSFERS);

                self.transfer_count = @min(data.items.len, MAX_TRANSFERS);
                @memcpy(
                    self.transfers[0..self.transfer_count],
                    data.items[0..self.transfer_count],
                );
                self.transfers_timestamp = data.timestamp;
                self.error_msg = null;
            },
            .err => |status| {
                self.error_msg = packetStatusMessage(status);
            },
            else => {
                self.error_msg = "Unexpected response type";
            },
        }
    }

    /// Handle account creation response
    pub fn onAccountsCreated(self: *AppState, g: *Gooey, response: TBClient.Response) void {
        switch (response) {
            .create_accounts => |data| {
                if (data.results.len == 0) {
                    // Success - all accounts created, refresh list
                    self.refreshAccounts(g);
                } else {
                    // Some accounts failed
                    self.error_msg = "Some accounts failed to create";
                }
            },
            .err => |status| {
                self.error_msg = packetStatusMessage(status);
            },
            else => {
                self.error_msg = "Unexpected response type";
            },
        }
    }

    /// Handle transfer creation response
    pub fn onTransfersCreated(self: *AppState, g: *Gooey, response: TBClient.Response) void {
        switch (response) {
            .create_transfers => |data| {
                if (data.results.len == 0) {
                    // Success - all transfers created, refresh list
                    self.refreshAccounts(g);
                } else {
                    // Some transfers failed
                    self.error_msg = "Some transfers failed to create";
                }
            },
            .err => |status| {
                self.error_msg = packetStatusMessage(status);
            },
            else => {
                self.error_msg = "Unexpected response type";
            },
        }
    }
};

fn packetStatusMessage(status: TB_PACKET_STATUS) []const u8 {
    return switch (status) {
        .TB_PACKET_OK => "OK",
        .TB_PACKET_TOO_MUCH_DATA => "Too much data",
        .TB_PACKET_CLIENT_EVICTED => "Client evicted",
        .TB_PACKET_CLIENT_RELEASE_TOO_LOW => "Client release too low",
        .TB_PACKET_CLIENT_RELEASE_TOO_HIGH => "Client release too high",
        .TB_PACKET_CLIENT_SHUTDOWN => "Client shutdown",
        .TB_PACKET_INVALID_OPERATION => "Invalid operation",
        .TB_PACKET_INVALID_DATA_SIZE => "Invalid data size",
    };
}
```

### Phase 4: UI Components

Example UI using Gooey's command pattern:

```zig
const ConnectionPanel = struct {
    pub fn render(cx: *Cx) void {
        const state = cx.state(AppState);

        cx.render(ui.vstack(.{ .gap = 12 }, .{
            // Server address input
            ui.textInput(.{
                .placeholder = "127.0.0.1:3000",
                .value = state.server_address[0..state.server_address_len],
                .on_change = cx.update(AppState, AppState.setServerAddress),
            }),

            // Connect/Disconnect button
            ui.hstack(.{ .gap = 8 }, .{
                if (state.connected)
                    Button{
                        .label = "Disconnect",
                        .variant = .danger,
                        .on_click_handler = cx.command(AppState, AppState.disconnect),
                    }
                else
                    Button{
                        .label = "Connect",
                        .variant = .primary,
                        .on_click_handler = cx.command(AppState, AppState.connect),
                        .disabled = state.server_address_len == 0,
                    },

                // Refresh button (only when connected)
                if (state.connected)
                    Button{
                        .label = if (state.loading_accounts) "Loading..." else "Refresh",
                        .on_click_handler = cx.command(AppState, AppState.refreshAccounts),
                        .disabled = state.loading_accounts,
                    }
                else
                    ui.spacer(),
            }),

            // Error display
            if (state.error_msg) |msg|
                ui.text(.{
                    .content = msg,
                    .color = Color.rgb(1, 0.3, 0.3),
                })
            else
                ui.spacer(),
        }));
    }
};

const AccountList = struct {
    pub fn render(cx: *Cx) void {
        const state = cx.state(AppState);

        cx.render(ui.vstack(.{ .gap = 4 }, .{
            // Header
            ui.text(.{ .content = "Accounts", .font_size = 18, .font_weight = .bold }),

            // Account rows
            for (state.accounts[0..state.account_count]) |account| {
                AccountRow{ .account = account };
            },

            if (state.account_count == 0 and !state.loading_accounts)
                ui.text(.{ .content = "No accounts", .color = Color.gray(0.5) }),
        }));
    }
};

const AccountRow = struct {
    account: tb_account_t,

    pub fn render(self: AccountRow, cx: *Cx) void {
        cx.render(ui.hstack(.{ .gap = 16, .padding = 8, .background = Color.gray(0.1) }, .{
            // ID (truncated hex)
            ui.text(.{ .content = formatU128Hex(self.account.id), .font_family = .monospace }),

            ui.spacer(),

            // Balances
            ui.vstack(.{ .gap = 2 }, .{
                ui.text(.{ .content = std.fmt.comptimePrint("Credits: {}", .{self.account.credits_posted}) }),
                ui.text(.{ .content = std.fmt.comptimePrint("Debits: {}", .{self.account.debits_posted}) }),
            }),
        }));
    }
};
```

## TigerBeetle C API Types Reference

From `tb_client.h`:

```zig
// Account structure (128 bytes)
typedef struct tb_account_t {
    tb_uint128_t id;
    tb_uint128_t debits_pending;
    tb_uint128_t debits_posted;
    tb_uint128_t credits_pending;
    tb_uint128_t credits_posted;
    tb_uint128_t user_data_128;
    uint64_t user_data_64;
    uint32_t user_data_32;
    uint32_t reserved;
    uint32_t ledger;
    uint16_t code;
    uint16_t flags;
    uint64_t timestamp;
} tb_account_t;

// Transfer structure (128 bytes)
typedef struct tb_transfer_t {
    tb_uint128_t id;
    tb_uint128_t debit_account_id;
    tb_uint128_t credit_account_id;
    tb_uint128_t amount;
    tb_uint128_t pending_id;
    tb_uint128_t user_data_128;
    uint64_t user_data_64;
    uint32_t user_data_32;
    uint32_t timeout;
    uint32_t ledger;
    uint16_t code;
    uint16_t flags;
    uint64_t timestamp;
} tb_transfer_t;

// Completion callback signature
typedef void (*tb_completion_t)(
    uintptr_t userdata,
    tb_packet_t* packet,
    uint64_t timestamp,
    const uint8_t *result,  // nullable
    uint32_t result_size
);
```

## Operations

| Operation                            | Request Tag                         | Description                  |
| ------------------------------------ | ----------------------------------- | ---------------------------- |
| `TB_OPERATION_CREATE_ACCOUNTS`       | `REQUEST_TAG_CREATE_ACCOUNTS`       | Create accounts in batch     |
| `TB_OPERATION_CREATE_TRANSFERS`      | `REQUEST_TAG_CREATE_TRANSFERS`      | Create transfers in batch    |
| `TB_OPERATION_LOOKUP_ACCOUNTS`       | `REQUEST_TAG_LOOKUP_ACCOUNTS`       | Look up accounts by ID       |
| `TB_OPERATION_LOOKUP_TRANSFERS`      | `REQUEST_TAG_LOOKUP_TRANSFERS`      | Look up transfers by ID      |
| `TB_OPERATION_GET_ACCOUNT_TRANSFERS` | `REQUEST_TAG_GET_ACCOUNT_TRANSFERS` | Get transfers for an account |
| `TB_OPERATION_GET_ACCOUNT_BALANCES`  | `REQUEST_TAG_GET_ACCOUNT_BALANCES`  | Get balance history          |
| `TB_OPERATION_QUERY_ACCOUNTS`        | `REQUEST_TAG_QUERY_ACCOUNTS`        | Query with filters           |
| `TB_OPERATION_QUERY_TRANSFERS`       | `REQUEST_TAG_QUERY_TRANSFERS`       | Query transfers with filters |

## Error Code Mapping

Build a comptime lookup table for user-friendly error messages:

```zig
// Account creation errors (from tb_client.h TB_CREATE_ACCOUNT_RESULT)
const CreateAccountError = enum(u32) {
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
    // Import-related errors (for data migration scenarios)
    imported_event_expected = 22,
    imported_event_not_expected = 23,
    imported_event_timestamp_out_of_range = 24,
    imported_event_timestamp_must_not_advance = 25,
    imported_event_timestamp_must_not_regress = 26,
};

// Transfer creation errors (from tb_client.h TB_CREATE_TRANSFER_RESULT)
const CreateTransferError = enum(u32) {
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
    // Import-related errors
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
};

const account_error_messages = blk: {
    var msgs: [32][]const u8 = .{""} ** 32;
    msgs[@intFromEnum(CreateAccountError.ok)] = "Success";
    msgs[@intFromEnum(CreateAccountError.linked_event_failed)] = "Linked event in batch failed";
    msgs[@intFromEnum(CreateAccountError.linked_event_chain_open)] = "Linked event chain not closed";
    msgs[@intFromEnum(CreateAccountError.timestamp_must_be_zero)] = "Timestamp must be zero (set by server)";
    msgs[@intFromEnum(CreateAccountError.reserved_field)] = "Reserved field must be zero";
    msgs[@intFromEnum(CreateAccountError.reserved_flag)] = "Reserved flag must not be set";
    msgs[@intFromEnum(CreateAccountError.id_must_not_be_zero)] = "Account ID cannot be zero";
    msgs[@intFromEnum(CreateAccountError.id_must_not_be_int_max)] = "Account ID cannot be max value";
    msgs[@intFromEnum(CreateAccountError.flags_are_mutually_exclusive)] = "Account flags are mutually exclusive";
    msgs[@intFromEnum(CreateAccountError.debits_pending_must_be_zero)] = "Debits pending must be zero on creation";
    msgs[@intFromEnum(CreateAccountError.debits_posted_must_be_zero)] = "Debits posted must be zero on creation";
    msgs[@intFromEnum(CreateAccountError.credits_pending_must_be_zero)] = "Credits pending must be zero on creation";
    msgs[@intFromEnum(CreateAccountError.credits_posted_must_be_zero)] = "Credits posted must be zero on creation";
    msgs[@intFromEnum(CreateAccountError.ledger_must_not_be_zero)] = "Ledger must be specified";
    msgs[@intFromEnum(CreateAccountError.code_must_not_be_zero)] = "Account code must be specified";
    msgs[@intFromEnum(CreateAccountError.exists_with_different_flags)] = "Account exists with different flags";
    msgs[@intFromEnum(CreateAccountError.exists_with_different_user_data_128)] = "Account exists with different user_data_128";
    msgs[@intFromEnum(CreateAccountError.exists_with_different_user_data_64)] = "Account exists with different user_data_64";
    msgs[@intFromEnum(CreateAccountError.exists_with_different_user_data_32)] = "Account exists with different user_data_32";
    msgs[@intFromEnum(CreateAccountError.exists_with_different_ledger)] = "Account exists with different ledger";
    msgs[@intFromEnum(CreateAccountError.exists_with_different_code)] = "Account exists with different code";
    msgs[@intFromEnum(CreateAccountError.exists)] = "Account already exists (identical)";
    msgs[@intFromEnum(CreateAccountError.imported_event_expected)] = "Import flag required for this operation";
    msgs[@intFromEnum(CreateAccountError.imported_event_not_expected)] = "Import flag not allowed for this operation";
    msgs[@intFromEnum(CreateAccountError.imported_event_timestamp_out_of_range)] = "Imported timestamp out of valid range";
    msgs[@intFromEnum(CreateAccountError.imported_event_timestamp_must_not_advance)] = "Imported timestamp must not advance";
    msgs[@intFromEnum(CreateAccountError.imported_event_timestamp_must_not_regress)] = "Imported timestamp must not regress";
    break :blk msgs;
};

pub fn accountErrorMessage(result: u32) []const u8 {
    if (result >= account_error_messages.len) return "Unknown error";
    const msg = account_error_messages[result];
    return if (msg.len > 0) msg else "Unknown error";
}

const transfer_error_messages = blk: {
    var msgs: [69][]const u8 = .{""} ** 69;
    msgs[@intFromEnum(CreateTransferError.ok)] = "Success";
    msgs[@intFromEnum(CreateTransferError.linked_event_failed)] = "Linked event in batch failed";
    msgs[@intFromEnum(CreateTransferError.linked_event_chain_open)] = "Linked event chain not closed";
    msgs[@intFromEnum(CreateTransferError.timestamp_must_be_zero)] = "Timestamp must be zero (set by server)";
    msgs[@intFromEnum(CreateTransferError.reserved_flag)] = "Reserved flag must not be set";
    msgs[@intFromEnum(CreateTransferError.id_must_not_be_zero)] = "Transfer ID cannot be zero";
    msgs[@intFromEnum(CreateTransferError.id_must_not_be_int_max)] = "Transfer ID cannot be max value";
    msgs[@intFromEnum(CreateTransferError.flags_are_mutually_exclusive)] = "Transfer flags are mutually exclusive";
    msgs[@intFromEnum(CreateTransferError.debit_account_id_must_not_be_zero)] = "Debit account ID cannot be zero";
    msgs[@intFromEnum(CreateTransferError.debit_account_id_must_not_be_int_max)] = "Debit account ID cannot be max value";
    msgs[@intFromEnum(CreateTransferError.credit_account_id_must_not_be_zero)] = "Credit account ID cannot be zero";
    msgs[@intFromEnum(CreateTransferError.credit_account_id_must_not_be_int_max)] = "Credit account ID cannot be max value";
    msgs[@intFromEnum(CreateTransferError.accounts_must_be_different)] = "Debit and credit accounts must be different";
    msgs[@intFromEnum(CreateTransferError.pending_id_must_be_zero)] = "Pending ID must be zero for non-pending transfers";
    msgs[@intFromEnum(CreateTransferError.pending_id_must_not_be_zero)] = "Pending ID required for post/void transfers";
    msgs[@intFromEnum(CreateTransferError.pending_id_must_not_be_int_max)] = "Pending ID cannot be max value";
    msgs[@intFromEnum(CreateTransferError.pending_id_must_be_different)] = "Pending ID must differ from transfer ID";
    msgs[@intFromEnum(CreateTransferError.timeout_reserved_for_pending_transfer)] = "Timeout only valid for pending transfers";
    msgs[@intFromEnum(CreateTransferError.ledger_must_not_be_zero)] = "Ledger must be specified";
    msgs[@intFromEnum(CreateTransferError.code_must_not_be_zero)] = "Transfer code must be specified";
    msgs[@intFromEnum(CreateTransferError.debit_account_not_found)] = "Debit account not found";
    msgs[@intFromEnum(CreateTransferError.credit_account_not_found)] = "Credit account not found";
    msgs[@intFromEnum(CreateTransferError.accounts_must_have_the_same_ledger)] = "Both accounts must be on the same ledger";
    msgs[@intFromEnum(CreateTransferError.transfer_must_have_the_same_ledger_as_accounts)] = "Transfer ledger must match account ledgers";
    msgs[@intFromEnum(CreateTransferError.pending_transfer_not_found)] = "Referenced pending transfer not found";
    msgs[@intFromEnum(CreateTransferError.pending_transfer_not_pending)] = "Referenced transfer is not pending";
    msgs[@intFromEnum(CreateTransferError.pending_transfer_has_different_debit_account_id)] = "Pending transfer has different debit account";
    msgs[@intFromEnum(CreateTransferError.pending_transfer_has_different_credit_account_id)] = "Pending transfer has different credit account";
    msgs[@intFromEnum(CreateTransferError.pending_transfer_has_different_ledger)] = "Pending transfer has different ledger";
    msgs[@intFromEnum(CreateTransferError.pending_transfer_has_different_code)] = "Pending transfer has different code";
    msgs[@intFromEnum(CreateTransferError.exceeds_pending_transfer_amount)] = "Amount exceeds pending transfer amount";
    msgs[@intFromEnum(CreateTransferError.pending_transfer_has_different_amount)] = "Amount must match pending transfer (for void)";
    msgs[@intFromEnum(CreateTransferError.pending_transfer_already_posted)] = "Pending transfer already posted";
    msgs[@intFromEnum(CreateTransferError.pending_transfer_already_voided)] = "Pending transfer already voided";
    msgs[@intFromEnum(CreateTransferError.pending_transfer_expired)] = "Pending transfer has expired";
    msgs[@intFromEnum(CreateTransferError.exists_with_different_flags)] = "Transfer exists with different flags";
    msgs[@intFromEnum(CreateTransferError.exists_with_different_debit_account_id)] = "Transfer exists with different debit account";
    msgs[@intFromEnum(CreateTransferError.exists_with_different_credit_account_id)] = "Transfer exists with different credit account";
    msgs[@intFromEnum(CreateTransferError.exists_with_different_amount)] = "Transfer exists with different amount";
    msgs[@intFromEnum(CreateTransferError.exists_with_different_pending_id)] = "Transfer exists with different pending_id";
    msgs[@intFromEnum(CreateTransferError.exists_with_different_user_data_128)] = "Transfer exists with different user_data_128";
    msgs[@intFromEnum(CreateTransferError.exists_with_different_user_data_64)] = "Transfer exists with different user_data_64";
    msgs[@intFromEnum(CreateTransferError.exists_with_different_user_data_32)] = "Transfer exists with different user_data_32";
    msgs[@intFromEnum(CreateTransferError.exists_with_different_timeout)] = "Transfer exists with different timeout";
    msgs[@intFromEnum(CreateTransferError.exists_with_different_code)] = "Transfer exists with different code";
    msgs[@intFromEnum(CreateTransferError.exists)] = "Transfer already exists (identical)";
    msgs[@intFromEnum(CreateTransferError.overflows_debits_pending)] = "Would overflow debits_pending";
    msgs[@intFromEnum(CreateTransferError.overflows_credits_pending)] = "Would overflow credits_pending";
    msgs[@intFromEnum(CreateTransferError.overflows_debits_posted)] = "Would overflow debits_posted";
    msgs[@intFromEnum(CreateTransferError.overflows_credits_posted)] = "Would overflow credits_posted";
    msgs[@intFromEnum(CreateTransferError.overflows_debits)] = "Would overflow total debits";
    msgs[@intFromEnum(CreateTransferError.overflows_credits)] = "Would overflow total credits";
    msgs[@intFromEnum(CreateTransferError.overflows_timeout)] = "Timeout value would overflow";
    msgs[@intFromEnum(CreateTransferError.exceeds_credits)] = "Exceeds account credit limit";
    msgs[@intFromEnum(CreateTransferError.exceeds_debits)] = "Exceeds account debit limit";
    msgs[@intFromEnum(CreateTransferError.imported_event_expected)] = "Import flag required";
    msgs[@intFromEnum(CreateTransferError.imported_event_not_expected)] = "Import flag not allowed";
    msgs[@intFromEnum(CreateTransferError.imported_event_timestamp_out_of_range)] = "Imported timestamp out of range";
    msgs[@intFromEnum(CreateTransferError.imported_event_timestamp_must_not_advance)] = "Imported timestamp must not advance";
    msgs[@intFromEnum(CreateTransferError.imported_event_timestamp_must_not_regress)] = "Imported timestamp must not regress";
    msgs[@intFromEnum(CreateTransferError.imported_event_timestamp_must_postdate_debit_account)] = "Timestamp must postdate debit account";
    msgs[@intFromEnum(CreateTransferError.imported_event_timestamp_must_postdate_credit_account)] = "Timestamp must postdate credit account";
    msgs[@intFromEnum(CreateTransferError.imported_event_timeout_must_be_zero)] = "Imported transfers cannot have timeout";
    msgs[@intFromEnum(CreateTransferError.closing_transfer_must_be_pending)] = "Closing transfer must be pending";
    msgs[@intFromEnum(CreateTransferError.debit_account_already_closed)] = "Debit account is closed";
    msgs[@intFromEnum(CreateTransferError.credit_account_already_closed)] = "Credit account is closed";
    msgs[@intFromEnum(CreateTransferError.exists_with_different_ledger)] = "Transfer exists with different ledger";
    msgs[@intFromEnum(CreateTransferError.id_already_failed)] = "Transfer ID was previously rejected";
    break :blk msgs;
};

pub fn transferErrorMessage(result: u32) []const u8 {
    if (result >= transfer_error_messages.len) return "Unknown error";
    const msg = transfer_error_messages[result];
    return if (msg.len > 0) msg else "Unknown error";
}
```

## UI Considerations

1. **u128 Display**: Store natively, format for display only

   ```zig
   fn formatU128Hex(value: u128) [34]u8 {
       var buf: [34]u8 = undefined;
       buf[0] = '0';
       buf[1] = 'x';
       _ = std.fmt.bufPrint(buf[2..], "{x:0>32}", .{value}) catch unreachable;
       return buf;
   }
   ```

2. **Balance Display**: Show pending vs posted separately with color coding
   - Pending amounts in yellow/orange
   - Posted amounts in green (credits) / red (debits)

3. **Batch Operations**: Use fixed-size selection arrays

   ```zig
   selected_accounts: [MAX_ACCOUNTS]bool = .{false} ** MAX_ACCOUNTS,
   selected_count: usize = 0,
   ```

4. **Loading States**: Per-operation loading flags (not global)

   ```zig
   loading_accounts: bool = false,
   loading_transfers: bool = false,
   creating_account: bool = false,
   creating_transfer: bool = false,
   ```

5. **Timestamp Display**: Convert TigerBeetle timestamps (nanoseconds since cluster start) to relative time

## UI Components Checklist

- [ ] **ConnectionPanel** - Server address input, connect/disconnect buttons, status indicator
- [ ] **AccountList** - Paginated account display with balances
- [ ] **AccountDetail** - Full account info with transfer history
- [ ] **TransferForm** - Create new transfers with validation
- [ ] **TransferList** - List transfers with filtering
- [ ] **ErrorBanner** - Dismissable error display
- [ ] **LoadingOverlay** - Per-component loading indicators

## Future: Linux Support

Linux will need an `eventfd`-based dispatcher to wake the Wayland event loop from the TigerBeetle IO thread:

```zig
// Linux dispatcher (future implementation)
const LinuxDispatcher = struct {
    event_fd: std.posix.fd_t,
    pending_queue: BoundedQueue(DeferredTask, MAX_DEFERRED_COMMANDS),

    pub fn init() !LinuxDispatcher {
        const efd = try std.posix.eventfd(0, .{ .NONBLOCK = true });
        return .{ .event_fd = efd, .pending_queue = .{} };
    }

    pub fn dispatchOnMainThread(self: *LinuxDispatcher, comptime Context: type, context: Context, comptime callback: fn (*Context) void) !void {
        // Queue the task
        try self.pending_queue.push(.{ .context = context, .callback = callback });
        // Signal the event fd to wake the event loop
        _ = try std.posix.write(self.event_fd, &std.mem.toBytes(@as(u64, 1)));
    }

    // Called from Wayland event loop when event_fd is readable
    pub fn processPending(self: *LinuxDispatcher) void {
        // Drain eventfd
        var buf: [8]u8 = undefined;
        _ = std.posix.read(self.event_fd, &buf) catch {};

        // Process all queued tasks
        while (self.pending_queue.pop()) |task| {
            task.callback(&task.context);
        }
    }
};
```

The same `command`/`deferCommandWith` pattern works - only the thread marshaling mechanism differs.

## Future: WASM Support

WASM is single-threaded, so TigerBeetle's Zig client (which spawns IO threads) won't work directly.

**Options:**

1. **HTTP Gateway Proxy** (Recommended)
   - Run a small HTTP server that wraps TigerBeetle
   - Use `fetch()` from WASM to make requests
   - Gooey's `platform.web.http` module can handle this

2. **WebSocket Gateway**
   - Real-time updates via WebSocket
   - Server pushes balance changes

3. **Native-only Feature**
   - Mark TigerBeetle integration as desktop-only
   - Show "Not available in browser" message on WASM

**Proposed WASM API:**

```zig
// Abstract over native vs WASM
const TBBackend = if (builtin.cpu.arch == .wasm32)
    @import("tigerbeetle/http_backend.zig").HttpBackend
else
    @import("tigerbeetle/native_backend.zig").NativeBackend;

pub const TBClient = struct {
    backend: TBBackend,
    // ... rest of implementation unchanged
};
```

## Project Structure (Future Standalone)

```
tigerbeetle-ui/
├── build.zig
├── build.zig.zon              # depends on gooey
├── src/
│   ├── main.zig               # Entry point
│   ├── app.zig                # AppState, root component
│   ├── tigerbeetle/
│   │   ├── client.zig         # TBClient wrapper
│   │   ├── packet_pool.zig    # Static packet allocation
│   │   ├── errors.zig         # Error code mapping
│   │   ├── native_backend.zig # Native TigerBeetle client
│   │   └── http_backend.zig   # WASM HTTP fallback
│   └── ui/
│       ├── connection_panel.zig
│       ├── account_list.zig
│       ├── account_detail.zig
│       ├── transfer_form.zig
│       ├── transfer_list.zig
│       └── error_banner.zig
├── CLAUDE.md                  # Inherit from gooey's rules
└── README.md
```
