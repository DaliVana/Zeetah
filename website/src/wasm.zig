//! Browser ABI for the Zeetah playground, compiled to `wasm32-freestanding`.
//!
//! Zeetah ships no C/WASM ABI (see zeetah's docs/WASM.md), so this is the
//! playground's own thin shim over the public `Regex` API. One compiled
//! `Regex` lives in the module at a time — the page recompiles on every
//! pattern or flag edit.
//!
//! Conventions (mirrored by `web/zeetah.js`):
//! - Strings cross the boundary as `(ptr, len)` byte pairs. JS copies UTF-8
//!   into a buffer from `zt_alloc` and releases it with `zt_free`.
//! - Every call that can fail returns a negative value on error; the error's
//!   name (`@errorName`, e.g. `InvalidPattern`) is then at `zt_err_ptr` /
//!   `zt_err_len`.
//! - Results land in two module-owned buffers that stay valid until the next
//!   call: `zt_res_ptr` (u32 words: match/group/segment spans as byte
//!   offsets) and `zt_out_ptr` (bytes: engine name, replace output, …).

const std = @import("std");
const zeetah = @import("zeetah");
const Regex = zeetah.Regex;

/// No stack traces or messages in a browser; a panic is a bug in the engine or
/// the shim and surfaces in JS as a `RuntimeError` trap.
pub const panic = std.debug.no_panic;

const gpa = std.heap.wasm_allocator;

/// Span value of a capture group that did not participate in the match.
const NONE: u32 = std.math.maxInt(u32);

var re: ?Regex = null;
var res: std.ArrayList(u32) = .empty;
var out: std.ArrayList(u8) = .empty;
var err_name: []const u8 = "";
var truncated: bool = false;

fn fail(e: anyerror) i32 {
    err_name = @errorName(e);
    return -1;
}

fn current() !*const Regex {
    if (re) |*r| return r;
    return error.NotCompiled;
}

fn setOut(bytes: []const u8) i32 {
    out.clearRetainingCapacity();
    out.appendSlice(gpa, bytes) catch |e| return fail(e);
    return @intCast(bytes.len);
}

// --- memory ----------------------------------------------------------------

export fn zt_alloc(n: usize) ?[*]u8 {
    const s = gpa.alloc(u8, @max(n, 1)) catch return null;
    return s.ptr;
}

export fn zt_free(p: [*]u8, n: usize) void {
    gpa.free(p[0..@max(n, 1)]);
}

export fn zt_res_ptr() [*]const u32 {
    return res.items.ptr;
}

export fn zt_out_ptr() [*]const u8 {
    return out.items.ptr;
}

export fn zt_err_ptr() [*]const u8 {
    return err_name.ptr;
}

export fn zt_err_len() usize {
    return err_name.len;
}

/// 1 if the last `zt_exec` stopped at its `limit` with matches left over.
export fn zt_truncated() u32 {
    return @intFromBool(truncated);
}

/// Library version as `major.minor.patch` in the out buffer; returns its length.
export fn zt_version() i32 {
    const v = zeetah.version;
    out.clearRetainingCapacity();
    out.print(gpa, "{d}.{d}.{d}", .{ v.major, v.minor, v.patch }) catch |e| return fail(e);
    return @intCast(out.items.len);
}

// --- compile ---------------------------------------------------------------

/// Flag bits: 1 = case_insensitive (i), 2 = multiline (m), 4 = dot_all (s),
/// 8 = extended (x), 16 = unicode (u, codepoint mode). Replaces the previously
/// compiled regex. Returns 0, or -1 on a compile error (`EmptyPattern`,
/// `InvalidPattern`, `NotImplemented`, `PatternTooComplex`, `OutOfMemory`).
export fn zt_compile(p: [*]const u8, n: usize, flags: u32) i32 {
    if (re) |*r| r.deinit();
    re = null;
    re = Regex.compileWithFlags(gpa, p[0..n], .{
        .case_insensitive = flags & 1 != 0,
        .multiline = flags & 2 != 0,
        .dot_all = flags & 4 != 0,
        .extended = flags & 8 != 0,
        .unicode = flags & 16 != 0,
    }) catch |e| return fail(e);
    return 0;
}

/// The executor the meta engine routed the pattern to (`@tagName` of the
/// regex's engine kind, e.g. `dfa`, `class_span`, `backtrack`).
export fn zt_engine() i32 {
    const r = current() catch |e| return fail(e);
    return setOut(@tagName(r.kind));
}

export fn zt_group_count() i32 {
    const r = current() catch |e| return fail(e);
    return @intCast(r.n_groups);
}

/// Name of capture group `i` (1-based) in the out buffer; 0 if unnamed.
export fn zt_group_name(i: u32) i32 {
    const r = current() catch |e| return fail(e);
    if (i == 0 or i > r.n_groups) return 0;
    return setOut(r.gnames[i] orelse "");
}

// --- matching --------------------------------------------------------------

/// Leftmost non-overlapping matches (all of them when `global` != 0, else the
/// first), at most `limit`. Each match appends `2 + 2*groups` words to the
/// result buffer: whole-match `start, end`, then each group's `start, end`
/// (`NONE` when the group did not participate). Returns the match count.
/// Capture-free patterns take the faster `iterator` path.
export fn zt_exec(p: [*]const u8, n: usize, global: u32, limit: u32) i32 {
    const r = current() catch |e| return fail(e);
    const input = p[0..n];
    res.clearRetainingCapacity();
    truncated = false;
    var count: u32 = 0;
    if (r.n_groups == 0) {
        var it = r.iterator(input);
        while (it.next(gpa) catch |e| return fail(e)) |m| {
            if (count == limit) {
                truncated = true;
                break;
            }
            res.appendSlice(gpa, &.{ @intCast(m.start), @intCast(m.end) }) catch |e| return fail(e);
            count += 1;
            if (global == 0) break;
        }
    } else {
        var it = r.capturesIterator(input);
        while (it.next(gpa) catch |e| return fail(e)) |found| {
            var m = found;
            defer m.deinit(gpa);
            if (count == limit) {
                truncated = true;
                break;
            }
            res.appendSlice(gpa, &.{ @intCast(m.start), @intCast(m.end) }) catch |e| return fail(e);
            var g: usize = 1;
            while (g <= r.n_groups) : (g += 1) {
                const span: [2]u32 = if (g < m.groups.len and m.groups[g] != null)
                    .{ @intCast(m.groups[g].?.start), @intCast(m.groups[g].?.end) }
                else
                    .{ NONE, NONE };
                res.appendSlice(gpa, &span) catch |e| return fail(e);
            }
            count += 1;
            if (global == 0) break;
        }
    }
    return @intCast(count);
}

/// Mode bits: 1 = every match (`replaceAll*`), 2 = literal replacement (no
/// `$1` / `${name}` expansion). The result is in the out buffer; returns its
/// length.
export fn zt_replace(p: [*]const u8, n: usize, t: [*]const u8, tn: usize, mode: u32) i32 {
    const r = current() catch |e| return fail(e);
    const input = p[0..n];
    const tmpl = t[0..tn];
    const all = mode & 1 != 0;
    const s = (if (mode & 2 != 0)
        (if (all) r.replaceAllLiteral(gpa, input, tmpl) else r.replaceLiteral(gpa, input, tmpl))
    else
        (if (all) r.replaceAll(gpa, input, tmpl) else r.replace(gpa, input, tmpl))) catch |e| return fail(e);
    defer gpa.free(s);
    return setOut(s);
}

/// `Regex.split` segments as `start, end` byte-offset pairs in the result
/// buffer; returns the segment count.
export fn zt_split(p: [*]const u8, n: usize) i32 {
    const r = current() catch |e| return fail(e);
    const input = p[0..n];
    const parts = r.split(gpa, input) catch |e| return fail(e);
    defer gpa.free(parts);
    res.clearRetainingCapacity();
    const base = @intFromPtr(input.ptr);
    for (parts) |part| {
        const s: u32 = @intCast(@intFromPtr(part.ptr) - base);
        res.appendSlice(gpa, &.{ s, s + @as(u32, @intCast(part.len)) }) catch |e| return fail(e);
    }
    return @intCast(parts.len);
}

/// Throughput probe: run `count` over the input `iters` times (the page
/// times the call). Returns the match count.
export fn zt_bench(p: [*]const u8, n: usize, iters: u32) i32 {
    const r = current() catch |e| return fail(e);
    const input = p[0..n];
    var c: usize = 0;
    var i: u32 = 0;
    while (i < iters) : (i += 1) {
        c = r.count(input) catch |e| return fail(e);
        std.mem.doNotOptimizeAway(c);
    }
    return @intCast(c);
}
