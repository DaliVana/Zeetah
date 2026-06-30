const std = @import("std");

/// Character type used throughout the library
pub const Char = u8;

/// Position in the input string
pub const Position = usize;

/// Represents a range of characters (for character classes)
pub const CharRange = struct {
    start: Char,
    end: Char,

    pub fn contains(self: CharRange, c: Char) bool {
        return c >= self.start and c <= self.end;
    }

    pub fn init(start: Char, end: Char) CharRange {
        return .{ .start = start, .end = end };
    }
};

/// 256-bit set membership over a `[32]u8` bitmap: `set[c>>3] & (1 << (c&7))`.
/// The one canonical definition of the engine's hot-path byte-set test — the
/// per-module `hasBit` / `bitsetHas` / `inSet` names are thin aliases of this,
/// so the bit math lives in exactly one place.
pub inline fn hasBit(set: *const [32]u8, c: u8) bool {
    return (set[c >> 3] & (@as(u8, 1) << @as(u3, @intCast(c & 7)))) != 0;
}

/// Character class - represents a set of characters
pub const CharClass = struct {
    ranges: []const CharRange,
    negated: bool = false,
    /// Optional precomputed 256-bit membership table, with `negated` already
    /// folded in. When present, `matches` is a single O(1) bit test instead of
    /// an O(ranges) linear scan — this is the per-byte hot path in the VM.
    /// Built once at NFA-compile time (see `Transition.charClass`); comptime
    /// constant classes leave it null and use the range scan.
    bitmap: ?*const [32]u8 = null,

    pub fn matches(self: CharClass, c: Char) bool {
        if (self.bitmap) |bm| {
            return hasBit(bm, c);
        }
        var found = false;
        for (self.ranges) |range| {
            if (range.contains(c)) {
                found = true;
                break;
            }
        }
        return if (self.negated) !found else found;
    }

    /// Fill `out` with the post-negation membership bitmap for this class.
    pub fn fillBitmap(self: CharClass, out: *[32]u8) void {
        @memset(out, 0);
        var c: usize = 0;
        while (c < 256) : (c += 1) {
            var found = false;
            for (self.ranges) |range| {
                if (range.contains(@intCast(c))) {
                    found = true;
                    break;
                }
            }
            const member = if (self.negated) !found else found;
            if (member) out[c >> 3] |= (@as(u8, 1) << @as(u3, @intCast(c & 7)));
        }
    }
};

/// A Unicode scalar value.
pub const Codepoint = u21;

/// Largest valid Unicode codepoint.
pub const MAX_CODEPOINT: Codepoint = 0x10FFFF;

/// An inclusive range of codepoints. Unlike `CharRange` (byte-oriented, used by
/// the ASCII/Latin-1 hot path), this spans the full Unicode scalar range and is
/// only used by Unicode property classes (`\p{...}`), which the NFA compiler
/// expands into UTF-8 byte automata and the backtracker matches per-codepoint.
pub const CodepointRange = struct {
    lo: Codepoint,
    hi: Codepoint,

    pub fn contains(self: CodepointRange, c: Codepoint) bool {
        return c >= self.lo and c <= self.hi;
    }

    pub fn init(lo: Codepoint, hi: Codepoint) CodepointRange {
        return .{ .lo = lo, .hi = hi };
    }
};

/// A resolved Unicode property class: a sorted, non-overlapping, surrogate-free
/// set of codepoint ranges with any negation (`\P{...}`, `\p{^...}`, an
/// enclosing `[^...]`) already folded in. Produced by the parser via
/// `unicode_class.zig`; consumed by the NFA compiler (UTF-8 expansion) and the
/// backtracking engine (decode-and-test).
pub const UnicodeClass = struct {
    ranges: []const CodepointRange,
    /// Precomputed membership for U+0000..U+007F (128 bits): bit `cp` set iff
    /// `cp` is in `ranges`. The corpus for real workloads (e.g. LLM
    /// pre-tokenizers) is overwhelmingly ASCII, so this turns the per-codepoint
    /// test into one bitmap lookup instead of a UTF-8 decode + binary search.
    /// Only meaningful when `ascii_valid` (see `initRanges`).
    ascii: [16]u8 = [_]u8{0} ** 16,
    /// `false` => `ascii` not precomputed; `matches` uses the binary search
    /// (still correct, just not accelerated). Defaulting false keeps every
    /// plain `.{ .ranges = … }` construction (e.g. tests) behavior-identical.
    ascii_valid: bool = false,

    /// Build the ASCII (U+0000..U+007F) membership bitmap for `ranges`.
    /// Negation is already folded into `ranges` (see the type doc-comment),
    /// so this is a straight containment sweep — same convention
    /// `CharClass.fillBitmap` relies on.
    pub fn fillAscii(ranges: []const CodepointRange) [16]u8 {
        var out = [_]u8{0} ** 16;
        var cp: Codepoint = 0;
        while (cp < 128) : (cp += 1) {
            for (ranges) |r| {
                if (r.contains(cp)) {
                    out[cp >> 3] |= @as(u8, 1) << @as(u3, @intCast(cp & 7));
                    break;
                }
            }
        }
        return out;
    }

    /// Construct a `UnicodeClass` with the ASCII fast-path precomputed.
    /// Use this at parser construction sites; `ranges` ownership is unchanged.
    pub fn initRanges(ranges: []const CodepointRange) UnicodeClass {
        return .{ .ranges = ranges, .ascii = fillAscii(ranges), .ascii_valid = true };
    }

    /// Membership test. ASCII fast path (one bitmap lookup) when precomputed;
    /// otherwise a binary search over the sorted ranges.
    pub fn matches(self: UnicodeClass, cp: Codepoint) bool {
        if (self.ascii_valid and cp < 128) {
            return (self.ascii[cp >> 3] & (@as(u8, 1) << @as(u3, @intCast(cp & 7)))) != 0;
        }
        var lo: usize = 0;
        var hi: usize = self.ranges.len;
        while (lo < hi) {
            const mid = lo + (hi - lo) / 2;
            const r = self.ranges[mid];
            if (cp < r.lo) {
                hi = mid;
            } else if (cp > r.hi) {
                lo = mid + 1;
            } else {
                return true;
            }
        }
        return false;
    }
};

/// Regex compilation flags
pub const CompileFlags = packed struct {
    case_insensitive: bool = false,
    multiline: bool = false,
    dot_all: bool = false,
    extended: bool = false,
    /// Codepoint-aware matching (the inline `(?u)` mode): full-Unicode `\p`,
    /// scripts, simple case folding, codepoint-granular `.`, Unicode `\b`, and
    /// character-class set operations. Reserved follow-on — currently rejected
    /// with `error.NotImplemented` (see `tests/feat_unicode.zig`).
    ///
    /// INVARIANT — byte-mode is frozen, Unicode is always opt-in.
    /// The default (this flag off) is a byte-oriented engine: `.`/`\d`/`\w`/`\b`
    /// operate on bytes, `\p` is Latin-1, multibyte literals are byte sequences.
    /// That semantics MUST NOT change. When the Unicode extension lands, every
    /// codepoint-aware behavior — including any syntax with a benign byte-mode
    /// meaning today (e.g. `&&`/`--` as literals inside `[...]`) — lives behind
    /// this flag and is never retrofitted into the default. This is what lets
    /// the extension be purely additive and breaks zero existing patterns.
    /// Corollary: keep the reserved-syntax rejections (`(?u)`, `\x{>0xFF}`,
    /// `\p{Script}`, …) erroring rather than silently matching, so no pattern
    /// can come to depend on a byte-meaning the extension would later reinterpret.
    unicode: bool = false,
};

/// Span in the source pattern (for error reporting)
pub const Span = struct {
    start: Position,
    end: Position,

    pub fn init(start: Position, end: Position) Span {
        return .{ .start = start, .end = end };
    }

    pub fn len(self: Span) usize {
        return self.end - self.start;
    }
};

/// Predefined character classes
pub const CharClasses = struct {
    /// Digits: [0-9]
    pub const digit = CharClass{
        .ranges = &[_]CharRange{
            CharRange.init('0', '9'),
        },
        .negated = false,
    };

    /// Non-digits: [^0-9]
    pub const non_digit = CharClass{
        .ranges = &[_]CharRange{
            CharRange.init('0', '9'),
        },
        .negated = true,
    };

    /// Word characters: [a-zA-Z0-9_]
    pub const word = CharClass{
        .ranges = &[_]CharRange{
            CharRange.init('a', 'z'),
            CharRange.init('A', 'Z'),
            CharRange.init('0', '9'),
            CharRange.init('_', '_'),
        },
        .negated = false,
    };

    /// Non-word characters: [^a-zA-Z0-9_]
    pub const non_word = CharClass{
        .ranges = &[_]CharRange{
            CharRange.init('a', 'z'),
            CharRange.init('A', 'Z'),
            CharRange.init('0', '9'),
            CharRange.init('_', '_'),
        },
        .negated = true,
    };

    /// Whitespace: [ \t\n\r\f\v]
    pub const whitespace = CharClass{
        .ranges = &[_]CharRange{
            CharRange.init(' ', ' '),
            CharRange.init('\t', '\t'),
            CharRange.init('\n', '\n'),
            CharRange.init('\r', '\r'),
            CharRange.init(0x0C, 0x0C), // \f
            CharRange.init(0x0B, 0x0B), // \v
        },
        .negated = false,
    };

    /// Non-whitespace: [^ \t\n\r\f\v]
    pub const non_whitespace = CharClass{
        .ranges = &[_]CharRange{
            CharRange.init(' ', ' '),
            CharRange.init('\t', '\t'),
            CharRange.init('\n', '\n'),
            CharRange.init('\r', '\r'),
            CharRange.init(0x0C, 0x0C), // \f
            CharRange.init(0x0B, 0x0B), // \v
        },
        .negated = true,
    };

    // POSIX Character Classes
    // These follow the POSIX standard for character class names

    /// POSIX [:alnum:] - Alphanumeric characters [a-zA-Z0-9]
    pub const posix_alnum = CharClass{
        .ranges = &[_]CharRange{
            CharRange.init('a', 'z'),
            CharRange.init('A', 'Z'),
            CharRange.init('0', '9'),
        },
        .negated = false,
    };

    /// POSIX [:alpha:] - Alphabetic characters [a-zA-Z]
    pub const posix_alpha = CharClass{
        .ranges = &[_]CharRange{
            CharRange.init('a', 'z'),
            CharRange.init('A', 'Z'),
        },
        .negated = false,
    };

    /// POSIX [:blank:] - Space and tab [ \t]
    pub const posix_blank = CharClass{
        .ranges = &[_]CharRange{
            CharRange.init(' ', ' '),
            CharRange.init('\t', '\t'),
        },
        .negated = false,
    };

    /// POSIX [:cntrl:] - Control characters [\x00-\x1F\x7F]
    pub const posix_cntrl = CharClass{
        .ranges = &[_]CharRange{
            CharRange.init(0x00, 0x1F),
            CharRange.init(0x7F, 0x7F),
        },
        .negated = false,
    };

    /// POSIX [:digit:] - Digits [0-9]
    pub const posix_digit = CharClass{
        .ranges = &[_]CharRange{
            CharRange.init('0', '9'),
        },
        .negated = false,
    };

    /// POSIX [:graph:] - Visible characters [\x21-\x7E]
    pub const posix_graph = CharClass{
        .ranges = &[_]CharRange{
            CharRange.init(0x21, 0x7E),
        },
        .negated = false,
    };

    /// POSIX [:lower:] - Lowercase letters [a-z]
    pub const posix_lower = CharClass{
        .ranges = &[_]CharRange{
            CharRange.init('a', 'z'),
        },
        .negated = false,
    };

    /// POSIX [:print:] - Printable characters [\x20-\x7E]
    pub const posix_print = CharClass{
        .ranges = &[_]CharRange{
            CharRange.init(0x20, 0x7E),
        },
        .negated = false,
    };

    /// POSIX [:punct:] - Punctuation characters [!-/:-@\[-`{-~]
    pub const posix_punct = CharClass{
        .ranges = &[_]CharRange{
            CharRange.init('!', '/'),
            CharRange.init(':', '@'),
            CharRange.init('[', '`'),
            CharRange.init('{', '~'),
        },
        .negated = false,
    };

    /// POSIX [:space:] - Whitespace characters [ \t\n\r\f\v]
    pub const posix_space = CharClass{
        .ranges = &[_]CharRange{
            CharRange.init(' ', ' '),
            CharRange.init('\t', '\t'),
            CharRange.init('\n', '\n'),
            CharRange.init('\r', '\r'),
            CharRange.init(0x0C, 0x0C), // \f
            CharRange.init(0x0B, 0x0B), // \v
        },
        .negated = false,
    };

    /// POSIX [:upper:] - Uppercase letters [A-Z]
    pub const posix_upper = CharClass{
        .ranges = &[_]CharRange{
            CharRange.init('A', 'Z'),
        },
        .negated = false,
    };

    /// POSIX [:xdigit:] - Hexadecimal digits [0-9A-Fa-f]
    pub const posix_xdigit = CharClass{
        .ranges = &[_]CharRange{
            CharRange.init('0', '9'),
            CharRange.init('A', 'F'),
            CharRange.init('a', 'f'),
        },
        .negated = false,
    };
};

test "char range contains" {
    const range = CharRange.init('a', 'z');
    try std.testing.expect(range.contains('a'));
    try std.testing.expect(range.contains('m'));
    try std.testing.expect(range.contains('z'));
    try std.testing.expect(!range.contains('A'));
    try std.testing.expect(!range.contains('0'));
}

test "char class matches" {
    const digit_class = CharClasses.digit;
    try std.testing.expect(digit_class.matches('0'));
    try std.testing.expect(digit_class.matches('5'));
    try std.testing.expect(digit_class.matches('9'));
    try std.testing.expect(!digit_class.matches('a'));

    const non_digit_class = CharClasses.non_digit;
    try std.testing.expect(!non_digit_class.matches('0'));
    try std.testing.expect(non_digit_class.matches('a'));
}

test "word char class" {
    const word_class = CharClasses.word;
    try std.testing.expect(word_class.matches('a'));
    try std.testing.expect(word_class.matches('Z'));
    try std.testing.expect(word_class.matches('5'));
    try std.testing.expect(word_class.matches('_'));
    try std.testing.expect(!word_class.matches(' '));
    try std.testing.expect(!word_class.matches('-'));
}

test "whitespace char class" {
    const ws_class = CharClasses.whitespace;
    try std.testing.expect(ws_class.matches(' '));
    try std.testing.expect(ws_class.matches('\t'));
    try std.testing.expect(ws_class.matches('\n'));
    try std.testing.expect(!ws_class.matches('a'));
}
