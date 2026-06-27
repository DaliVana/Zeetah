const std = @import("std");

/// Thread safety documentation and guarantees for the regex library.
///
/// # Thread Safety Overview
///
/// This regex library provides the following thread safety guarantees:
///
/// ## Compiled Regex Patterns (Regex struct)
///
/// - **Thread-safe for concurrent reads**: Once a `Regex` is compiled, it can be safely
///   shared and used concurrently by multiple threads for matching operations.
/// - **Immutable after compilation**: The `Regex` struct and its underlying NFA are
///   immutable after `compile()` returns, making them inherently thread-safe.
/// - **No internal synchronization needed**: Since the compiled pattern is read-only,
///   no locks or atomic operations are required.
///
/// ## Matching Operations
///
/// - **Pooled per-search scratch**: Match calls (`isMatch()`/`find()`/`findAll()`/
///   `captures()`/…) need mutable scratch — the lazy-DFA state memo and the
///   bounded-backtracker visited bitset. This scratch is NOT part of the
///   immutable program; each `Regex` owns thread-safe `Pool`s (`lazy_pool`,
///   `bt_pool`) and every search borrows its own scratch instance from them.
/// - **Shared mutable state is internally synchronized**: Those pools (and the
///   lazy memo's retained-state amortization) are the only shared mutable state,
///   and they are guarded by the pool's own lock-free-slot + spinlock protocol —
///   so no user-side locking is required.
/// - **Safe concurrent matching**: Multiple threads can call match operations on the
///   same `Regex` instance simultaneously without any synchronization.
///
/// ## Memory Management
///
/// - **Allocator thread safety**: Users must ensure their allocator is thread-safe
///   if using the same allocator across multiple threads. For concurrent usage,
///   consider using thread-local allocators or a thread-safe allocator like
///   `std.heap.ThreadSafeAllocator`.
/// - **Internal caching is pool-guarded**: The lazy DFA retains learned states
///   across reuse (an amortization), but that memo lives in a per-`Regex`
///   thread-safe pool — there is no unsynchronized shared cache.
///
/// ## Example Usage
///
/// ```zig
/// const std = @import("std");
/// const Regex = @import("zeetah").Regex;
///
/// // Compile once, use from multiple threads
/// var gpa: std.heap.DebugAllocator(.{}) = .init;
/// const allocator = gpa.allocator();
///
/// const regex = try Regex.compile(allocator, "\\d+");
/// defer regex.deinit();
///
/// // Thread 1
/// const match1 = try regex.find("abc123"); // Safe
///
/// // Thread 2 (concurrent with Thread 1)
/// const match2 = try regex.find("xyz789"); // Safe
/// ```
///
/// ## Best Practices
///
/// 1. **Compile once, match many**: Compile regex patterns once and reuse them
///    across threads for best performance.
/// 2. **Use thread-safe allocators**: When matching from multiple threads, use
///    a thread-safe allocator or give each thread its own allocator.
/// 3. **No mutex needed**: You do not need to protect `Regex` instances with
///    mutexes for concurrent read access.
/// 4. **Avoid deinit during use**: Do not call `deinit()` on a `Regex` while
///    other threads may be using it. Ensure all matching operations complete
///    before cleanup.
///
/// ## Thread Safety Guarantees Summary
///
/// | Operation | Thread Safety | Notes |
/// |-----------|---------------|-------|
/// | `Regex.compile()` | Not thread-safe | Creates new instance |
/// | `regex.deinit()` | Not thread-safe | Mutates and frees |
/// | `regex.isMatch()` | Thread-safe | Read-only program, pooled scratch |
/// | `regex.find()` | Thread-safe | Read-only program, pooled scratch |
/// | `regex.findAll()` | Thread-safe | Read-only program, pooled scratch |
/// | `regex.replace()` | Thread-safe | Read-only regex, new output |
/// | `regex.replaceAll()` | Thread-safe | Read-only regex, new output |
///
pub const ThreadSafety = struct {
    // Marker to indicate this module is for documentation only
};

/// Thread-safe wrapper for regex patterns with reference counting.
///
/// This wrapper provides automatic lifetime management for regex patterns
/// that are shared across threads. It uses atomic reference counting to
/// ensure the pattern is only freed when all threads are done using it.
///
/// Example:
/// ```zig
/// var shared_regex = try SharedRegex.init(allocator, "\\d+");
/// defer shared_regex.deinit();
///
/// // Thread 1
/// {
///     var ref = shared_regex.acquire();
///     defer ref.release();
///     const match = try ref.regex.find("123");
/// }
///
/// // Thread 2
/// {
///     var ref = shared_regex.acquire();
///     defer ref.release();
///     const match = try ref.regex.find("456");
/// }
/// ```
pub fn SharedRegex(comptime Regex: type) type {
    return struct {
        const Self = @This();

        regex: Regex,
        ref_count: std.atomic.Value(usize),
        allocator: std.mem.Allocator,

        /// Initialize a shared regex pattern
        pub fn init(allocator: std.mem.Allocator, pattern: []const u8) !*Self {
            const self = try allocator.create(Self);
            errdefer allocator.destroy(self);

            self.* = .{
                .regex = try Regex.compile(allocator, pattern),
                .ref_count = std.atomic.Value(usize).init(1),
                .allocator = allocator,
            };

            return self;
        }

        /// Acquire a reference to the regex (increments ref count)
        pub fn acquire(self: *Self) Reference {
            _ = self.ref_count.fetchAdd(1, .monotonic);
            return Reference{ .shared = self };
        }

        /// Release the initial reference and free if no other references exist
        pub fn deinit(self: *Self) void {
            const prev = self.ref_count.fetchSub(1, .acq_rel);
            if (prev == 1) {
                // Last reference, safe to free
                var mut_regex = self.regex;
                mut_regex.deinit();
                const allocator = self.allocator;
                allocator.destroy(self);
            }
        }

        /// A reference to a shared regex
        pub const Reference = struct {
            shared: *Self,

            /// Access the underlying regex as a `*const` pointer — safe to
            /// share and match on from multiple threads (the compiled regex is
            /// immutable, and matching keeps no shared mutable state).
            pub fn regex(self: Reference) *const Regex {
                return &self.shared.regex;
            }

            /// Release this reference
            pub fn release(self: Reference) void {
                const prev = self.shared.ref_count.fetchSub(1, .acq_rel);
                if (prev == 1) {
                    // Last reference, safe to free
                    var mut_regex = self.shared.regex;
                    mut_regex.deinit();
                    const allocator = self.shared.allocator;
                    allocator.destroy(self.shared);
                }
            }
        };
    };
}

/// Thread-local regex cache for efficient pattern reuse within a single thread.
///
/// This cache maintains compiled regex patterns in thread-local storage,
/// avoiding recompilation overhead. Each thread gets its own cache.
///
/// Example:
/// ```zig
/// threadlocal var regex_cache: RegexCache = undefined;
///
/// pub fn processText(text: []const u8) !void {
///     if (!regex_cache.initialized) {
///         regex_cache = try RegexCache.init(allocator);
///     }
///     defer if (regex_cache.initialized) regex_cache.deinit();
///
///     const regex = try regex_cache.get("\\d+");
///     const match = try regex.find(text);
/// }
/// ```
pub fn RegexCache(comptime Regex: type) type {
    return struct {
        const Self = @This();

        /// Values are **boxed** (`*Regex`) so a returned pointer stays valid
        /// across a later insert: a `StringHashMap(Regex)` stores values inline,
        /// so a rehash on `put` would move them and dangle every pointer handed
        /// out by an earlier `get` (use-after-free). The box is heap-stable.
        cache: std.StringHashMap(*Regex),
        allocator: std.mem.Allocator,
        initialized: bool = false,

        pub fn init(allocator: std.mem.Allocator) Self {
            return .{
                .cache = std.StringHashMap(*Regex).init(allocator),
                .allocator = allocator,
                .initialized = true,
            };
        }

        pub fn deinit(self: *Self) void {
            var it = self.cache.iterator();
            while (it.next()) |entry| {
                entry.value_ptr.*.deinit();
                self.allocator.destroy(entry.value_ptr.*);
                self.allocator.free(entry.key_ptr.*);
            }
            self.cache.deinit();
            self.initialized = false;
        }

        /// Get a compiled regex from cache, or compile and cache it. The
        /// returned pointer is stable for the lifetime of the cache entry
        /// (until `clear`/`deinit`), regardless of later `get` calls.
        pub fn get(self: *Self, pattern: []const u8) !*const Regex {
            if (self.cache.get(pattern)) |regex_ptr| return regex_ptr;

            // Not in cache: compile into a heap box, then store the box.
            const box = try self.allocator.create(Regex);
            errdefer self.allocator.destroy(box);
            box.* = try Regex.compile(self.allocator, pattern);
            errdefer box.deinit();

            const owned_pattern = try self.allocator.dupe(u8, pattern);
            errdefer self.allocator.free(owned_pattern);

            try self.cache.put(owned_pattern, box);
            return box;
        }

        /// Clear all cached patterns
        pub fn clear(self: *Self) void {
            var it = self.cache.iterator();
            while (it.next()) |entry| {
                entry.value_ptr.*.deinit();
                self.allocator.destroy(entry.value_ptr.*);
                self.allocator.free(entry.key_ptr.*);
            }
            self.cache.clearRetainingCapacity();
        }
    };
}

test "RegexCache.get returns pointers stable across later inserts (no UAF)" {
    const Regex = @import("regex.zig").Regex;
    const a = std.testing.allocator;
    var cache = RegexCache(Regex).init(a);
    defer cache.deinit();

    // Hold a pointer handed out by an early get, then insert many more patterns
    // to force the backing map to grow/rehash. Boxed values keep the pointer
    // valid (an inline-value map would move them → use-after-free).
    const first = try cache.get("\\d+");
    var buf: [8]u8 = undefined;
    var i: usize = 0;
    while (i < 64) : (i += 1) {
        const pat = try std.fmt.bufPrint(&buf, "x{d}y", .{i});
        _ = try cache.get(pat);
    }
    // `first` must still point at a live, correct Regex after the rehash.
    try std.testing.expect(try first.isMatch("abc123"));
    try std.testing.expect(!try first.isMatch("abc"));
    // Re-getting the same pattern returns the identical (stable) box.
    try std.testing.expectEqual(first, try cache.get("\\d+"));
}

test "thread safety documentation" {
    // This test exists to ensure the module compiles
    // The actual thread safety is guaranteed by the design
    const testing = std.testing;
    _ = testing;
}
