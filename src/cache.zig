//! Runtime-only scratch `Cache` + a thread-safe `Pool(Cache)`.
//!
//! The meta engine's DFA/literal fast paths are allocation-free. Engines
//! that need mutable per-search scratch (the lazy DFA's `LazyMemo`) keep it
//! off the immutable, shareable compiled `Regex` so one `Regex` stays safe
//! across threads — the lazy engine uses its own
//! `Pool(lazy_dfa.LazyMemo)`. This `Cache`/`Pool(Cache)` is the generic
//! borrow primitive (single-slot atomic fast path + spinlock fallback stack);
//! it is internal only — there is no public caller-supplied-cache API.

const std = @import("std");

/// Reusable per-search scratch. Owns buffers the engines refill instead of
/// re-allocating each call (currently the findAll span buffer).
pub const Cache = struct {
    allocator: std.mem.Allocator,
    /// Reusable `[]Span`-shaped scratch for cached findAll (kept as raw bytes
    /// so this module stays engine-agnostic; callers reinterpret).
    span_scratch: std.ArrayListUnmanaged(u8) = .empty,

    pub fn init(allocator: std.mem.Allocator) Cache {
        return .{ .allocator = allocator };
    }

    pub fn deinit(self: *Cache) void {
        self.span_scratch.deinit(self.allocator);
    }

    /// Drop retained capacity (call between unrelated workloads to bound RSS).
    pub fn reset(self: *Cache) void {
        self.span_scratch.clearRetainingCapacity();
    }
};

/// Tiny test-and-set spinlock (this Zig std build exposes no
/// `std.Thread.Mutex`). Only ever held for the few instructions of the
/// contended stack push/pop, so spinning is cheap and fair enough.
const SpinLock = struct {
    state: std.atomic.Value(bool) = .init(false),
    fn lock(self: *SpinLock) void {
        while (self.state.swap(true, .acquire)) {
            std.atomic.spinLoopHint();
        }
    }
    fn unlock(self: *SpinLock) void {
        self.state.store(false, .release);
    }
};

/// Thread-safe pool of `T`. Hot path: a single lock-free atomic slot (the
/// overwhelmingly common 1-or-2-thread reuse case). Contended path: a
/// spinlock-guarded stack. `get` never blocks on the fast path; `put`
/// returns the value for reuse. `T` must expose `init(allocator)`/`deinit`.
pub fn Pool(comptime T: type) type {
    return struct {
        const Self = @This();

        allocator: std.mem.Allocator,
        /// Lock-free fast slot. null == empty.
        slot: std.atomic.Value(?*T) = .init(null),
        mutex: SpinLock = .{},
        stack: std.ArrayListUnmanaged(*T) = .empty,

        pub fn init(allocator: std.mem.Allocator) Self {
            return .{ .allocator = allocator };
        }

        pub fn deinit(self: *Self) void {
            if (self.slot.swap(null, .acquire)) |p| {
                p.deinit();
                self.allocator.destroy(p);
            }
            for (self.stack.items) |p| {
                p.deinit();
                self.allocator.destroy(p);
            }
            self.stack.deinit(self.allocator);
        }

        /// Borrow a `T` (reused if available, else freshly created).
        pub fn get(self: *Self) !*T {
            if (self.slot.swap(null, .acquire)) |p| return p;
            self.mutex.lock();
            defer self.mutex.unlock();
            if (self.stack.pop()) |p| return p;
            const p = try self.allocator.create(T);
            p.* = T.init(self.allocator);
            return p;
        }

        /// Return a borrowed `T`. Tries the lock-free slot first.
        pub fn put(self: *Self, p: *T) void {
            if (self.slot.cmpxchgStrong(null, p, .release, .monotonic) == null) return;
            self.mutex.lock();
            defer self.mutex.unlock();
            self.stack.append(self.allocator, p) catch {
                // Pool full / OOM: free rather than leak (correctness > reuse).
                p.deinit();
                self.allocator.destroy(p);
            };
        }
    };
}

test "cache: pool reuse round-trips a Cache" {
    const a = std.testing.allocator;
    var pool = Pool(Cache).init(a);
    defer pool.deinit();

    const c1 = try pool.get();
    try c1.span_scratch.append(a, 7);
    pool.put(c1);
    const c2 = try pool.get(); // should reuse c1 via the atomic slot
    try std.testing.expectEqual(c1, c2);
    pool.put(c2);
}

test "cache: pool is safe under thread contention" {
    const a = std.testing.allocator;
    var pool = Pool(Cache).init(a);
    defer pool.deinit();

    const Worker = struct {
        fn run(p: *Pool(Cache)) void {
            var i: usize = 0;
            while (i < 2000) : (i += 1) {
                const c = p.get() catch return;
                c.reset();
                p.put(c);
            }
        }
    };

    var threads: [8]std.Thread = undefined;
    for (&threads) |*t| t.* = try std.Thread.spawn(.{}, Worker.run, .{&pool});
    for (threads) |t| t.join();
    // No leak/crash == pass (allocator + pool.deinit assert no leaks).
}
