// bigint_freestanding.zig
//
// A from-scratch arbitrary-precision (big) integer library for Zig, with
// ZERO usage of the Zig standard library ANYWHERE in this file -- not in
// the arithmetic core, and not in the demo/main harness either. There is
// no `@import("std")` in this file, full stop.
//
// Design
// ------
// - Sign-magnitude representation, same conceptual shape as bigint.zig:
//   a `negative: bool` flag plus a magnitude stored as a little-endian
//   array of base-1,000,000,000 (1e9) "limbs". Each limb is exactly 9
//   decimal digits, which keeps decimal parse/print trivial and exact.
// - Zero is canonicalized as `negative = false` with `len == 0`. There is
//   no "negative zero".
// - Magnitudes are always normalized: no trailing (most-significant)
//   zero limbs, except that zero itself has len == 0.
//
// Memory strategy: fixed-size stack allocation, no heap at all
// ---------------------------------------------------------------
// Rather than hand-rolling a bump allocator (which would still need *some*
// backing store, and adds indirection for no real benefit in a from-
// scratch demo), every BigInt simply embeds a fixed-size limb array:
//
//     limbs: [MAX_LIMBS]u32
//
// with MAX_LIMBS = 4096, i.e. up to 4096 * 9 = 36,864 decimal digits of
// magnitude. That comfortably covers any demo/sanity-check workload while
// requiring precisely zero calls to any allocator, zero `std.mem.Allocator`
// usage, and zero `@import("std")`. The tradeoff is that every `BigInt`
// value is ~16KB (mostly the limb array) and gets copied by value on
// every function call/return -- irrelevant for a handful of sanity
// checks, and a perfectly honest price to pay for "no heap, no std."
// Internal magnitude-level helpers (add/sub/mul/div) write results
// directly into caller-owned `*[MAX_LIMBS]u32` output buffers (often the
// `.limbs` field of the result `BigInt` itself), so there's no hidden
// allocation or copying beyond that.
//
// Printing: extern "c" write()/exit(), no std, no inline syscalls
// ---------------------------------------------------------------
// `std.debug.print` and `std.fmt` are completely avoided. Instead this
// file declares its own thin bindings to two libc functions:
//
//     extern "c" fn write(fd: c_int, buf: [*]const u8, count: usize) isize;
//     extern "c" fn exit(code: c_int) noreturn;
//
// and links against libc (see the build command in the comment above
// `main` below). This was chosen over raw `syscall`-via-inline-assembly
// because: (1) it's portable across the two Darwin architectures without
// hand-coding two different syscall-number/calling-convention tables,
// (2) libc is a different thing than std -- the task's "zero std"
// constraint is specifically about `@import("std")`, not about linking
// any C runtime at all, and (3) it actually compiles and runs reliably in
// this environment. `write(2)` is used for all demo output, and `exit(1)`
// is used by the hand-rolled `assert()` to abort on a failed check,
// mirroring what `std.debug.assert` would have done.
//
// Everything else -- decimal parsing, decimal printing, byte/limb
// comparison, add/sub/mul/divmod, even string equality for the
// sanity-check harness -- is hand-written from language primitives only
// (slices, arrays, integer arithmetic, builtins like `@abs`/`@intCast`
// that are part of the language, not std).
//
// Division semantics
// -------------------
// `divMod` implements truncating division (quotient rounds toward zero),
// matching Zig's own `@divTrunc` / `@rem` and C's `/` and `%`:
//   a == b * quotient + remainder
//   sign(remainder) == sign(a)  (or remainder == 0)
//   |remainder| < |b|
//
// Build/run (native target; libc is linked for write()/exit()):
//   zig build-exe bigint_freestanding.zig -lc -femit-bin=bigint_freestanding
//   ./bigint_freestanding
// or, if plain linking fails in a given environment:
//   zig build-exe bigint_freestanding.zig -lc -target aarch64-macos -femit-bin=bigint_freestanding

/// Each limb holds a value in [0, LIMB_BASE) and represents that many
/// units of LIMB_BASE^index. LIMB_BASE = 10^9 so a limb is always exactly
/// 9 decimal digits (zero-padded), which makes base-10 conversion trivial.
const LIMB_BASE: u32 = 1_000_000_000;
const LIMB_DIGITS: usize = 9;

/// Maximum number of base-1e9 limbs a BigInt can hold: 4096 limbs =
/// 36,864 decimal digits of magnitude. Fixed at compile time so every
/// BigInt can live entirely on the stack with no heap allocation.
pub const MAX_LIMBS: usize = 4096;

/// Result of a three-way comparison.
pub const Order = enum { less, equal, greater };

/// Errors specific to parsing a decimal string into a BigInt.
pub const ParseError = error{
    EmptyInput,
    InvalidCharacter,
    TooManyDigits,
};

/// Errors specific to division.
pub const MathError = error{
    DivisionByZero,
};

pub const BigInt = struct {
    /// True if the value is strictly negative. Always false when
    /// `len == 0` (canonical zero has no sign).
    negative: bool,
    /// Magnitude, little-endian base-LIMB_BASE, normalized (no trailing
    /// zero limbs beyond index `len - 1`). Only `limbs[0..len]` is
    /// meaningful; anything at or past index `len` is unspecified.
    limbs: [MAX_LIMBS]u32,
    /// Number of limbs actually in use. `len == 0` means zero.
    len: usize,

    /// Longest decimal string toString() can ever produce: an optional
    /// leading '-' plus MAX_LIMBS * LIMB_DIGITS digits.
    pub const MAX_STR_LEN: usize = 1 + MAX_LIMBS * LIMB_DIGITS;

    const ZERO = BigInt{ .negative = false, .limbs = [_]u32{0} ** MAX_LIMBS, .len = 0 };

    // ---------------------------------------------------------------
    // Construction
    // ---------------------------------------------------------------

    /// Build a BigInt from a signed 64-bit integer. Handles i64's minimum
    /// value correctly (its magnitude does not fit in an i64, only a u64).
    pub fn fromI64(value: i64) BigInt {
        var result = ZERO;
        const negative = value < 0;
        // @abs on a signed integer returns the corresponding unsigned
        // type and is defined even for minInt(i64), unlike naive `-value`.
        var mag: u64 = @abs(value);

        var count: usize = 0;
        while (mag > 0) : (count += 1) {
            result.limbs[count] = @intCast(mag % LIMB_BASE);
            mag /= LIMB_BASE;
        }
        result.negative = negative and count > 0;
        result.len = count;
        return result;
    }

    /// Parse a base-10 string into a BigInt. Accepts an optional leading
    /// '+' or '-', one or more decimal digits, and arbitrary leading
    /// zeros (e.g. "-007" parses as -7, "0" and "-0" both parse as 0).
    pub fn fromString(str: []const u8) ParseError!BigInt {
        if (str.len == 0) return ParseError.EmptyInput;

        var negative = false;
        var start: usize = 0;
        if (str[0] == '+' or str[0] == '-') {
            negative = (str[0] == '-');
            start = 1;
        }
        if (start >= str.len) return ParseError.EmptyInput;

        const digits = str[start..];
        for (digits) |c| {
            if (c < '0' or c > '9') return ParseError.InvalidCharacter;
        }

        // Skip leading zeros, but always keep at least one digit.
        var firstNonZero: usize = 0;
        while (firstNonZero < digits.len - 1 and digits[firstNonZero] == '0') : (firstNonZero += 1) {}
        const trimmed = digits[firstNonZero..];

        if (trimmed.len == 1 and trimmed[0] == '0') {
            return ZERO;
        }

        const numLimbs = (trimmed.len + LIMB_DIGITS - 1) / LIMB_DIGITS;
        if (numLimbs > MAX_LIMBS) return ParseError.TooManyDigits;

        var result = ZERO;

        // Fill limbs from least-significant (rightmost 9 digits) to most.
        var end: usize = trimmed.len;
        var limbIdx: usize = 0;
        while (limbIdx < numLimbs) : (limbIdx += 1) {
            const chunkLen: usize = if (end >= LIMB_DIGITS) LIMB_DIGITS else end;
            const chunkStart = end - chunkLen;
            var val: u32 = 0;
            for (trimmed[chunkStart..end]) |c| {
                val = val * 10 + (c - '0');
            }
            result.limbs[limbIdx] = val;
            end = chunkStart;
        }

        result.negative = negative;
        result.len = numLimbs;
        return result;
    }

    // ---------------------------------------------------------------
    // Queries
    // ---------------------------------------------------------------

    pub fn isZero(self: BigInt) bool {
        return self.len == 0;
    }

    /// Three-way comparison: self <=> other.
    pub fn compare(a: BigInt, b: BigInt) Order {
        if (a.negative != b.negative) {
            return if (a.negative) .less else .greater;
        }
        const magCmp = compareMagnitude(a.limbs[0..a.len], b.limbs[0..b.len]);
        if (a.negative) {
            // Both negative: larger magnitude means the more negative
            // (i.e. smaller) value, so the magnitude comparison flips.
            return switch (magCmp) {
                .less => .greater,
                .greater => .less,
                .equal => .equal,
            };
        }
        return magCmp;
    }

    pub fn eql(a: BigInt, b: BigInt) bool {
        return compare(a, b) == .equal;
    }

    // ---------------------------------------------------------------
    // Arithmetic
    // ---------------------------------------------------------------

    /// Return a new BigInt equal to -self. (Plain value copy -- there is
    /// no heap storage to clone, so this is trivially cheap and safe to
    /// call as many times as you like.)
    pub fn negate(self: BigInt) BigInt {
        var result = self;
        if (result.len > 0) result.negative = !result.negative;
        return result;
    }

    /// a + b.
    pub fn add(a: BigInt, b: BigInt) BigInt {
        var result = ZERO;
        if (a.negative == b.negative) {
            const n = addMagnitude(a.limbs[0..a.len], b.limbs[0..b.len], &result.limbs);
            result.len = n;
            result.negative = a.negative and n > 0;
            return result;
        }

        // Opposite signs: result magnitude is |larger| - |smaller|, and
        // the result takes the sign of whichever operand has the larger
        // magnitude.
        switch (compareMagnitude(a.limbs[0..a.len], b.limbs[0..b.len])) {
            .equal => return result, // ZERO
            .greater => {
                const n = subMagnitude(a.limbs[0..a.len], b.limbs[0..b.len], &result.limbs);
                result.len = n;
                result.negative = a.negative and n > 0;
                return result;
            },
            .less => {
                const n = subMagnitude(b.limbs[0..b.len], a.limbs[0..a.len], &result.limbs);
                result.len = n;
                result.negative = b.negative and n > 0;
                return result;
            },
        }
    }

    /// a - b.
    pub fn sub(a: BigInt, b: BigInt) BigInt {
        return add(a, b.negate());
    }

    /// a * b.
    pub fn mul(a: BigInt, b: BigInt) BigInt {
        var result = ZERO;
        const n = mulMagnitude(a.limbs[0..a.len], b.limbs[0..b.len], &result.limbs);
        result.len = n;
        result.negative = (a.negative != b.negative) and n > 0;
        return result;
    }

    pub const DivModResult = struct {
        quotient: BigInt,
        remainder: BigInt,
    };

    /// Truncating division: a == b * quotient + remainder, with
    /// sign(remainder) == sign(a) (or remainder == 0) and
    /// |remainder| < |b|. Returns MathError.DivisionByZero if b is zero.
    pub fn divMod(a: BigInt, b: BigInt) MathError!DivModResult {
        if (b.isZero()) return MathError.DivisionByZero;

        var q = ZERO;
        var r = ZERO;
        const lens = divModMagnitude(a.limbs[0..a.len], b.limbs[0..b.len], &q.limbs, &r.limbs);
        q.len = lens.qlen;
        r.len = lens.rlen;
        q.negative = (a.negative != b.negative) and lens.qlen > 0;
        r.negative = a.negative and lens.rlen > 0;
        return DivModResult{ .quotient = q, .remainder = r };
    }

    // ---------------------------------------------------------------
    // Decimal formatting
    // ---------------------------------------------------------------

    /// Render as a decimal string into caller-supplied `buf` (sized
    /// `MAX_STR_LEN`, so it's always big enough for any representable
    /// BigInt). Returns the used portion of `buf`.
    pub fn toString(self: BigInt, buf: *[MAX_STR_LEN]u8) []const u8 {
        if (self.len == 0) {
            buf[0] = '0';
            return buf[0..1];
        }

        // The most-significant limb is printed without zero padding;
        // every other limb is printed zero-padded to exactly 9 digits.
        var topBuf: [LIMB_DIGITS]u8 = undefined;
        formatLimbPadded(self.limbs[self.len - 1], &topBuf);
        var topStart: usize = 0;
        while (topStart < LIMB_DIGITS - 1 and topBuf[topStart] == '0') : (topStart += 1) {}
        const topDigits = topBuf[topStart..LIMB_DIGITS];

        var pos: usize = 0;
        if (self.negative) {
            buf[0] = '-';
            pos = 1;
        }
        copyBytes(buf[pos .. pos + topDigits.len], topDigits);
        pos += topDigits.len;

        var i: usize = self.len - 1;
        while (i > 0) {
            i -= 1;
            var limbBuf: [LIMB_DIGITS]u8 = undefined;
            formatLimbPadded(self.limbs[i], &limbBuf);
            copyBytes(buf[pos .. pos + LIMB_DIGITS], limbBuf[0..]);
            pos += LIMB_DIGITS;
        }

        return buf[0..pos];
    }
};

// =====================================================================
// Internal helpers: pure magnitude (unsigned) arithmetic on []const u32,
// writing normalized results into caller-owned *[MAX_LIMBS]u32 buffers.
// No allocation anywhere -- every buffer is either a BigInt's own
// `.limbs` field or a fixed-size local array on the stack.
// =====================================================================

/// Copy `src` into `dst` byte by byte. Stand-in for std.mem.copyForwards.
fn copyBytes(dst: []u8, src: []const u8) void {
    var i: usize = 0;
    while (i < src.len) : (i += 1) dst[i] = src[i];
}

/// Format `value` (< LIMB_BASE) as exactly LIMB_DIGITS decimal digit
/// characters, most-significant digit first, zero-padded.
fn formatLimbPadded(value: u32, buf: *[LIMB_DIGITS]u8) void {
    var v = value;
    var i: usize = LIMB_DIGITS;
    while (i > 0) {
        i -= 1;
        buf[i] = @as(u8, @intCast(v % 10)) + '0';
        v /= 10;
    }
}

/// Compare two normalized magnitudes.
fn compareMagnitude(a: []const u32, b: []const u32) Order {
    if (a.len != b.len) return if (a.len < b.len) .less else .greater;
    var i: usize = a.len;
    while (i > 0) {
        i -= 1;
        if (a[i] != b[i]) return if (a[i] < b[i]) .less else .greater;
    }
    return .equal;
}

/// Trim trailing (most-significant) zero limbs and return the new
/// logical length. Never touches the underlying storage -- length is
/// tracked separately from the fixed-size array.
fn normalizeLen(arr: []const u32, len: usize) usize {
    var l = len;
    while (l > 0 and arr[l - 1] == 0) : (l -= 1) {}
    return l;
}

/// a + b (magnitudes), written into `out`. Returns the result length.
fn addMagnitude(a: []const u32, b: []const u32, out: *[MAX_LIMBS]u32) usize {
    const maxLen = if (a.len > b.len) a.len else b.len;
    var carry: u64 = 0;
    var i: usize = 0;
    while (i < maxLen) : (i += 1) {
        const av: u64 = if (i < a.len) a[i] else 0;
        const bv: u64 = if (i < b.len) b[i] else 0;
        const sum = av + bv + carry;
        out[i] = @intCast(sum % LIMB_BASE);
        carry = sum / LIMB_BASE;
    }
    var total = maxLen;
    if (carry != 0) {
        assert(total < MAX_LIMBS, "BigInt overflow: add() exceeded MAX_LIMBS capacity");
        out[total] = @intCast(carry);
        total += 1;
    }
    return normalizeLen(out[0..total], total);
}

/// a - b (magnitudes), written into `out`. Requires a >= b (as values);
/// garbage (not a crash) otherwise for release builds -- the debug
/// assert below catches misuse during development, same contract as the
/// original allocator-based implementation.
fn subMagnitude(a: []const u32, b: []const u32, out: *[MAX_LIMBS]u32) usize {
    assert(compareMagnitude(a, b) != .less, "subMagnitude: a < b");
    var borrow: i64 = 0;
    var i: usize = 0;
    while (i < a.len) : (i += 1) {
        const av: i64 = a[i];
        const bv: i64 = if (i < b.len) b[i] else 0;
        var diff = av - bv - borrow;
        if (diff < 0) {
            diff += LIMB_BASE;
            borrow = 1;
        } else {
            borrow = 0;
        }
        out[i] = @intCast(diff);
    }
    return normalizeLen(out[0..a.len], a.len);
}

/// a * b (magnitudes), schoolbook O(len(a) * len(b)) multiplication.
/// Column sums are accumulated in u128 before carry-propagation, which is
/// comfortably safe for anything that fits within MAX_LIMBS.
fn mulMagnitude(a: []const u32, b: []const u32, out: *[MAX_LIMBS]u32) usize {
    if (a.len == 0 or b.len == 0) return 0;

    var acc: [2 * MAX_LIMBS]u128 = [_]u128{0} ** (2 * MAX_LIMBS);

    var i: usize = 0;
    while (i < a.len) : (i += 1) {
        if (a[i] == 0) continue;
        var j: usize = 0;
        while (j < b.len) : (j += 1) {
            acc[i + j] += @as(u128, a[i]) * @as(u128, b[j]);
        }
    }

    const totalLen = a.len + b.len;
    assert(totalLen <= MAX_LIMBS, "BigInt overflow: mul() exceeded MAX_LIMBS capacity");

    var carry: u128 = 0;
    i = 0;
    while (i < totalLen) : (i += 1) {
        const total = acc[i] + carry;
        out[i] = @intCast(total % LIMB_BASE);
        carry = total / LIMB_BASE;
    }
    assert(carry == 0, "mulMagnitude: unexpected leftover carry"); // fits by construction.
    return normalizeLen(out[0..totalLen], totalLen);
}

/// mag * scalar, where scalar is a single limb value (< LIMB_BASE).
fn mulMagnitudeBySmall(mag: []const u32, scalar: u32, out: *[MAX_LIMBS]u32) usize {
    if (mag.len == 0 or scalar == 0) return 0;
    var carry: u64 = 0;
    var i: usize = 0;
    while (i < mag.len) : (i += 1) {
        const prod = @as(u64, mag[i]) * @as(u64, scalar) + carry;
        out[i] = @intCast(prod % LIMB_BASE);
        carry = prod / LIMB_BASE;
    }
    var total = mag.len;
    if (carry != 0) {
        assert(total < MAX_LIMBS, "BigInt overflow: mulMagnitudeBySmall() exceeded MAX_LIMBS capacity");
        out[total] = @intCast(carry);
        total += 1;
    }
    return normalizeLen(out[0..total], total);
}

const DivModMagnitudeLens = struct {
    qlen: usize,
    rlen: usize,
};

/// Long division of magnitudes: dividend = divisor * quotient + remainder,
/// 0 <= remainder < divisor, written directly into caller-owned
/// `outQuotient` / `outRemainder` buffers. `divisor` must be non-zero
/// (checked by the caller, BigInt.divMod). Classic grade-school long
/// division, one base-LIMB_BASE digit at a time, using binary search
/// (over the ~1e9 possible digit values) to find each quotient digit.
fn divModMagnitude(dividend: []const u32, divisor: []const u32, outQuotient: *[MAX_LIMBS]u32, outRemainder: *[MAX_LIMBS]u32) DivModMagnitudeLens {
    assert(divisor.len > 0, "divModMagnitude: divisor is zero");

    if (compareMagnitude(dividend, divisor) == .less) {
        copyLimbs(outRemainder, dividend);
        return DivModMagnitudeLens{ .qlen = 0, .rlen = dividend.len };
    }

    var remainder: [MAX_LIMBS]u32 = [_]u32{0} ** MAX_LIMBS;
    var rlen: usize = 0;

    var i: usize = dividend.len;
    while (i > 0) {
        i -= 1;

        // Bring down the next limb: remainder = remainder * LIMB_BASE + dividend[i]
        var shifted: [MAX_LIMBS]u32 = [_]u32{0} ** MAX_LIMBS;
        assert(rlen + 1 <= MAX_LIMBS, "BigInt overflow: divMod() remainder exceeded MAX_LIMBS capacity");
        shifted[0] = dividend[i];
        var k: usize = 0;
        while (k < rlen) : (k += 1) shifted[1 + k] = remainder[k];
        rlen = normalizeLen(shifted[0 .. rlen + 1], rlen + 1);
        remainder = shifted;

        // Binary search for the largest digit in [0, LIMB_BASE) such
        // that digit * divisor <= remainder.
        var lo: u32 = 0;
        var hi: u32 = LIMB_BASE - 1;
        var digit: u32 = 0;
        while (lo <= hi) {
            const mid = lo + (hi - lo) / 2;
            var prod: [MAX_LIMBS]u32 = undefined;
            const plen = mulMagnitudeBySmall(divisor, mid, &prod);
            const feasible = compareMagnitude(prod[0..plen], remainder[0..rlen]) != .greater;
            if (feasible) {
                digit = mid;
                if (mid == LIMB_BASE - 1) break;
                lo = mid + 1;
            } else {
                if (mid == 0) break;
                hi = mid - 1;
            }
        }
        outQuotient[i] = digit;

        // remainder -= digit * divisor
        var toSubtract: [MAX_LIMBS]u32 = undefined;
        const tlen = mulMagnitudeBySmall(divisor, digit, &toSubtract);
        var newRemainder: [MAX_LIMBS]u32 = undefined;
        const nlen = subMagnitude(remainder[0..rlen], toSubtract[0..tlen], &newRemainder);
        remainder = newRemainder;
        rlen = nlen;
    }

    const qlen = normalizeLen(outQuotient[0..dividend.len], dividend.len);
    copyLimbsLen(outRemainder, remainder[0..rlen]);
    return DivModMagnitudeLens{ .qlen = qlen, .rlen = rlen };
}

fn copyLimbs(dst: *[MAX_LIMBS]u32, src: []const u32) void {
    var i: usize = 0;
    while (i < src.len) : (i += 1) dst[i] = src[i];
}

fn copyLimbsLen(dst: *[MAX_LIMBS]u32, src: []const u32) void {
    copyLimbs(dst, src);
}

// =====================================================================
// Zero-std, zero-syscall-asm I/O: bind directly to libc's write()/exit().
// This is the only "external" dependency in the whole file, and it is
// deliberately NOT `@import("std")` -- libc and std are different things.
// =====================================================================

extern "c" fn write(fd: c_int, buf: [*]const u8, count: usize) isize;
extern "c" fn exit(code: c_int) noreturn;

/// Write the entirety of `s` to stdout (fd 1), retrying on short writes.
fn writeAll(s: []const u8) void {
    var off: usize = 0;
    while (off < s.len) {
        const n = write(1, s.ptr + off, s.len - off);
        if (n <= 0) break; // give up on error/EOF rather than spin forever
        off += @intCast(n);
    }
}

/// Hand-rolled stand-in for std.debug.assert: on failure, print a message
/// and exit(1) rather than unwind (there's no std panic handler to catch
/// anything anyway).
fn assert(cond: bool, msg: []const u8) void {
    if (!cond) {
        writeAll("ASSERTION FAILED: ");
        writeAll(msg);
        writeAll("\n");
        exit(1);
    }
}

/// Hand-rolled stand-in for std.mem.eql(u8, a, b).
fn bytesEqual(a: []const u8, b: []const u8) bool {
    if (a.len != b.len) return false;
    var i: usize = 0;
    while (i < a.len) : (i += 1) {
        if (a[i] != b[i]) return false;
    }
    return true;
}

// =====================================================================
// Sanity-check harness. Runs the same category of hand-verified test
// cases as bigint.zig's harness and aborts (via our own assert()) on the
// first mismatch, printing every check as it passes -- all output going
// through the libc write() binding above, never std.debug.print.
// =====================================================================

fn expectString(label: []const u8, got: []const u8, want: []const u8) void {
    const ok = bytesEqual(got, want);
    writeAll("  [");
    writeAll(label);
    writeAll("] got=");
    writeAll(got);
    writeAll(" want=");
    writeAll(want);
    writeAll(" -> ");
    writeAll(if (ok) "OK" else "FAIL");
    writeAll("\n");
    assert(ok, label);
}

/// Unwrap a ParseError!BigInt or bail out via exit(1); keeps main() free
/// of `try`/error-union plumbing that would otherwise want std's panic
/// machinery when main() itself returns an error union.
fn mustParse(str: []const u8) BigInt {
    return BigInt.fromString(str) catch {
        writeAll("PARSE ERROR on input: ");
        writeAll(str);
        writeAll("\n");
        exit(1);
    };
}

fn mustDivMod(a: BigInt, b: BigInt) BigInt.DivModResult {
    return BigInt.divMod(a, b) catch {
        writeAll("DIVISION ERROR\n");
        exit(1);
    };
}

pub fn main() void {
    writeAll("=== bigint_freestanding.zig sanity checks ===\n");

    // 1. 999999999999999999 + 1 == 1000000000000000000
    {
        const x = mustParse("999999999999999999");
        const y = BigInt.fromI64(1);
        const sum = BigInt.add(x, y);
        var buf: [BigInt.MAX_STR_LEN]u8 = undefined;
        const s = sum.toString(&buf);
        expectString("999999999999999999 + 1", s, "1000000000000000000");
    }

    // 2. 123456789012345678901234567890 * 2 == 246913578024691357802469135780
    {
        const x = mustParse("123456789012345678901234567890");
        const two = BigInt.fromI64(2);
        const prod = BigInt.mul(x, two);
        var buf: [BigInt.MAX_STR_LEN]u8 = undefined;
        const s = prod.toString(&buf);
        expectString("123456789012345678901234567890 * 2", s, "246913578024691357802469135780");
    }

    // 3. Division with remainder:
    //    987654321098765432109876543210 / 333333333333
    //      = 2962962963299259259 remainder 97642962963
    //    (cross-checked independently with Python's // and %)
    {
        const num = mustParse("987654321098765432109876543210");
        const den = mustParse("333333333333");
        const dm = mustDivMod(num, den);
        var qbuf: [BigInt.MAX_STR_LEN]u8 = undefined;
        var rbuf: [BigInt.MAX_STR_LEN]u8 = undefined;
        const qs = dm.quotient.toString(&qbuf);
        const rs = dm.remainder.toString(&rbuf);
        expectString("987654321098765432109876543210 / 333333333333 (quotient)", qs, "2962962963299259259");
        expectString("987654321098765432109876543210 % 333333333333 (remainder)", rs, "97642962963");

        // Cross-check: den * quotient + remainder == num
        const reconstructed_mul = BigInt.mul(den, dm.quotient);
        const reconstructed = BigInt.add(reconstructed_mul, dm.remainder);
        assert(reconstructed.eql(num), "reconstruction: den*q + r == num");
        writeAll("  [reconstruction: den*q + r == num] OK\n");
    }

    // 4. Subtraction: 1000000000000000000 - 999999999999999999 == 1
    {
        const x = mustParse("1000000000000000000");
        const y = mustParse("999999999999999999");
        const diff = BigInt.sub(x, y);
        var buf: [BigInt.MAX_STR_LEN]u8 = undefined;
        const s = diff.toString(&buf);
        expectString("1000000000000000000 - 999999999999999999", s, "1");
    }

    // 5. Negative numbers: -123456789012345678901234567890 + 123456789012345678901234567890 == 0
    {
        const x = mustParse("-123456789012345678901234567890");
        const y = mustParse("123456789012345678901234567890");
        const sum = BigInt.add(x, y);
        var buf: [BigInt.MAX_STR_LEN]u8 = undefined;
        const s = sum.toString(&buf);
        expectString("-N + N", s, "0");
        assert(sum.isZero(), "-N + N is zero");
    }

    // 6. Truncating division semantics with negatives: -7 / 2 == -3 remainder -1
    {
        const x = BigInt.fromI64(-7);
        const y = BigInt.fromI64(2);
        const dm = mustDivMod(x, y);
        var qbuf: [BigInt.MAX_STR_LEN]u8 = undefined;
        var rbuf: [BigInt.MAX_STR_LEN]u8 = undefined;
        const qs = dm.quotient.toString(&qbuf);
        const rs = dm.remainder.toString(&rbuf);
        expectString("-7 / 2 (quotient, truncating)", qs, "-3");
        expectString("-7 % 2 (remainder)", rs, "-1");
    }

    // 7. i64::MIN round-trips correctly (magnitude doesn't fit in i64).
    {
        // std.math.minInt(i64) without std: build it as a comptime_int
        // (arbitrary precision) and coerce to i64 at the end.
        const min_i64: i64 = -9223372036854775807 - 1;
        const x = BigInt.fromI64(min_i64);
        var buf: [BigInt.MAX_STR_LEN]u8 = undefined;
        const s = x.toString(&buf);
        expectString("i64 min round-trip", s, "-9223372036854775808");
    }

    // 8. Comparisons.
    {
        const neg5 = BigInt.fromI64(-5);
        const pos3 = BigInt.fromI64(3);
        const hundred = BigInt.fromI64(100);
        const hundredAgain = mustParse("100");
        const negHundred = BigInt.fromI64(-100);

        assert(BigInt.compare(neg5, pos3) == .less, "-5 < 3");
        assert(BigInt.compare(hundred, hundredAgain) == .equal, "100 == \"100\"");
        assert(BigInt.compare(negHundred, negHundred) == .equal, "-100 == -100");
        assert(BigInt.compare(negHundred, pos3) == .less, "-100 < 3");
        assert(BigInt.compare(pos3, negHundred) == .greater, "3 > -100");
        writeAll("  [comparisons] OK\n");
    }

    // 9. Leading zeros / sign parsing edge cases.
    {
        const z1 = mustParse("-0");
        assert(z1.isZero() and !z1.negative, "\"-0\" is canonical zero");
        const z2 = mustParse("007");
        var buf: [BigInt.MAX_STR_LEN]u8 = undefined;
        const s2 = z2.toString(&buf);
        expectString("\"007\" parses as", s2, "7");
    }

    writeAll("=== all sanity checks passed ===\n");
}
