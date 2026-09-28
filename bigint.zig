// bigint.zig
//
// A from-scratch arbitrary-precision (big) integer library for Zig.
//
// Design
// ------
// - Sign-magnitude representation: a `negative: bool` flag plus a magnitude
//   stored as a little-endian slice of base-1,000,000,000 (1e9) "limbs"
//   (`[]u32`). Using base 1e9 instead of base 2^32 makes decimal parsing and
//   printing trivial and exact (each limb is exactly 9 decimal digits),
//   which is where a lot of from-scratch bigint implementations go subtly
//   wrong.
// - Zero is canonicalized as `negative = false` with an empty limb slice
//   (`limbs.len == 0`). There is no "negative zero".
// - Magnitudes are always normalized: no trailing (i.e. most-significant)
//   zero limbs, except that zero itself is the empty slice.
// - All arithmetic (add/sub/mul/div/mod, decimal parsing, decimal printing)
//   is implemented by hand, limb by limb. Nothing from `std.math.big` or
//   `std.fmt` is used anywhere in the library.
//
// Import policy
// -------------
// Per the task constraints, the *arithmetic implementation itself* uses
// only `std.mem` (for the `Allocator` interface, `copyForwards`, `dupe`,
// etc. -- all just basic memory operations) and `std.debug` (for
// `assert`). The `main()` demo/sanity-check harness at the bottom
// additionally uses `std.heap.page_allocator` / `std.heap.ArenaAllocator`
// to obtain a concrete allocator to drive the demo (there is no way to
// heap-allocate memory in Zig without *some* concrete allocator, and
// `std.mem` only defines the allocator *interface*, not an implementation)
// and `std.debug.print` to report results. No `std.fmt`, no
// `std.math.big`, and no third-party/external packages are used anywhere.
//
// Division semantics
// -------------------
// `divMod` implements truncating division (quotient rounds toward zero),
// matching Zig's own `@divTrunc` / `@rem` and C's `/` and `%`:
//   a == b * quotient + remainder
//   sign(remainder) == sign(a)  (or remainder == 0)
//   |remainder| < |b|

const std = @import("std");

/// Each limb holds a value in [0, LIMB_BASE) and represents that many
/// units of LIMB_BASE^index. LIMB_BASE = 10^9 so that a limb is always
/// exactly 9 decimal digits (with zero padding), which makes base-10
/// conversion trivial. It's declared without an explicit type (a
/// `comptime_int`) so it coerces cleanly to whatever integer type
/// (`u32`, `u64`, ...) each expression below needs.
const LIMB_BASE = 1_000_000_000;
const LIMB_DIGITS = 9;

/// Result of a three-way comparison.
pub const Order = enum { less, equal, greater };

/// Errors specific to parsing a decimal string into a BigInt.
pub const ParseError = error{
    EmptyInput,
    InvalidCharacter,
};

/// Errors specific to division.
pub const MathError = error{
    DivisionByZero,
};

pub const BigInt = struct {
    allocator: std.mem.Allocator,
    /// True if the value is strictly negative. Always false when
    /// `limbs.len == 0` (canonical zero has no sign).
    negative: bool,
    /// Magnitude, little-endian base-LIMB_BASE, normalized (no trailing
    /// zero limbs). Empty slice means the value is zero.
    limbs: []u32,

    // ---------------------------------------------------------------
    // Construction / destruction
    // ---------------------------------------------------------------

    /// Build a BigInt from a signed 64-bit integer. Handles i64's minimum
    /// value correctly (its magnitude does not fit in an i64, only a u64).
    pub fn fromI64(allocator: std.mem.Allocator, value: i64) !BigInt {
        const negative = value < 0;
        // @abs on a signed integer returns the corresponding unsigned
        // type and is defined even for minInt(i64), unlike naive `-value`.
        var mag: u64 = @abs(value);

        // u64 max (~1.8e19) needs at most 3 base-1e9 limbs (1e9^2 = 1e18
        // < u64 max < 1e9^3 = 1e27).
        var buf: [3]u32 = .{ 0, 0, 0 };
        var count: usize = 0;
        while (mag > 0) : (count += 1) {
            buf[count] = @intCast(mag % LIMB_BASE);
            mag /= LIMB_BASE;
        }

        const limbs = try allocator.alloc(u32, count);
        std.mem.copyForwards(u32, limbs, buf[0..count]);
        return BigInt{
            .allocator = allocator,
            .negative = negative and count > 0,
            .limbs = limbs,
        };
    }

    /// Parse a base-10 string into a BigInt. Accepts an optional leading
    /// '+' or '-', one or more decimal digits, and arbitrary leading
    /// zeros (e.g. "-007" parses as -7, "0" and "-0" both parse as 0).
    pub fn fromString(allocator: std.mem.Allocator, str: []const u8) !BigInt {
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
            return BigInt{
                .allocator = allocator,
                .negative = false,
                .limbs = try allocator.alloc(u32, 0),
            };
        }

        const numLimbs = (trimmed.len + LIMB_DIGITS - 1) / LIMB_DIGITS;
        const limbs = try allocator.alloc(u32, numLimbs);

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
            limbs[limbIdx] = val;
            end = chunkStart;
        }

        return BigInt{ .allocator = allocator, .negative = negative, .limbs = limbs };
    }

    /// Free the magnitude storage. Safe to call once; the BigInt should
    /// not be used afterward.
    pub fn deinit(self: *BigInt) void {
        self.allocator.free(self.limbs);
        self.limbs = &[_]u32{};
    }

    /// Deep-copy this BigInt using its own allocator.
    pub fn clone(self: BigInt) !BigInt {
        return BigInt{
            .allocator = self.allocator,
            .negative = self.negative,
            .limbs = try self.allocator.dupe(u32, self.limbs),
        };
    }

    // ---------------------------------------------------------------
    // Queries
    // ---------------------------------------------------------------

    pub fn isZero(self: BigInt) bool {
        return self.limbs.len == 0;
    }

    /// Three-way comparison: self <=> other.
    pub fn compare(a: BigInt, b: BigInt) Order {
        if (a.negative != b.negative) {
            return if (a.negative) .less else .greater;
        }
        const magCmp = compareMagnitude(a.limbs, b.limbs);
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

    /// Return a new BigInt equal to -self.
    pub fn negate(self: BigInt) !BigInt {
        var result = try self.clone();
        if (result.limbs.len > 0) result.negative = !result.negative;
        return result;
    }

    /// a + b. Uses a's allocator for the result; a and b must share the
    /// same allocator.
    pub fn add(a: BigInt, b: BigInt) !BigInt {
        const allocator = a.allocator;
        if (a.negative == b.negative) {
            const mag = try addMagnitude(allocator, a.limbs, b.limbs);
            return BigInt{ .allocator = allocator, .negative = a.negative and mag.len > 0, .limbs = mag };
        }

        // Opposite signs: result magnitude is |larger| - |smaller|, and
        // the result takes the sign of whichever operand has the larger
        // magnitude.
        return switch (compareMagnitude(a.limbs, b.limbs)) {
            .equal => BigInt{ .allocator = allocator, .negative = false, .limbs = try allocator.alloc(u32, 0) },
            .greater => blk: {
                const mag = try subMagnitude(allocator, a.limbs, b.limbs);
                break :blk BigInt{ .allocator = allocator, .negative = a.negative and mag.len > 0, .limbs = mag };
            },
            .less => blk: {
                const mag = try subMagnitude(allocator, b.limbs, a.limbs);
                break :blk BigInt{ .allocator = allocator, .negative = b.negative and mag.len > 0, .limbs = mag };
            },
        };
    }

    /// a - b.
    pub fn sub(a: BigInt, b: BigInt) !BigInt {
        var negB = try b.clone();
        defer negB.deinit();
        if (negB.limbs.len > 0) negB.negative = !negB.negative;
        return add(a, negB);
    }

    /// a * b.
    pub fn mul(a: BigInt, b: BigInt) !BigInt {
        const allocator = a.allocator;
        const mag = try mulMagnitude(allocator, a.limbs, b.limbs);
        return BigInt{
            .allocator = allocator,
            .negative = (a.negative != b.negative) and mag.len > 0,
            .limbs = mag,
        };
    }

    pub const DivModResult = struct {
        quotient: BigInt,
        remainder: BigInt,
    };

    /// Truncating division: a == b * quotient + remainder, with
    /// sign(remainder) == sign(a) (or remainder == 0) and
    /// |remainder| < |b|. Returns MathError.DivisionByZero if b is zero.
    pub fn divMod(a: BigInt, b: BigInt) !DivModResult {
        if (b.isZero()) return MathError.DivisionByZero;
        const allocator = a.allocator;
        const raw = try divModMagnitude(allocator, a.limbs, b.limbs);
        const qNegative = (a.negative != b.negative) and raw.quotient.len > 0;
        const rNegative = a.negative and raw.remainder.len > 0;
        return DivModResult{
            .quotient = BigInt{ .allocator = allocator, .negative = qNegative, .limbs = raw.quotient },
            .remainder = BigInt{ .allocator = allocator, .negative = rNegative, .limbs = raw.remainder },
        };
    }

    // ---------------------------------------------------------------
    // Decimal formatting
    // ---------------------------------------------------------------

    /// Render as a decimal string. Caller owns the returned slice and
    /// must free it with `allocator.free`.
    pub fn toString(self: BigInt, allocator: std.mem.Allocator) ![]u8 {
        if (self.limbs.len == 0) {
            const result = try allocator.alloc(u8, 1);
            result[0] = '0';
            return result;
        }

        // The most-significant limb is printed without zero padding;
        // every other limb is printed zero-padded to exactly 9 digits.
        var topBuf: [LIMB_DIGITS]u8 = undefined;
        formatLimbPadded(self.limbs[self.limbs.len - 1], &topBuf);
        var topStart: usize = 0;
        while (topStart < LIMB_DIGITS - 1 and topBuf[topStart] == '0') : (topStart += 1) {}
        const topDigits = topBuf[topStart..LIMB_DIGITS];

        const restLimbCount = self.limbs.len - 1;
        const signLen: usize = if (self.negative) 1 else 0;
        const totalLen = signLen + topDigits.len + restLimbCount * LIMB_DIGITS;

        const result = try allocator.alloc(u8, totalLen);
        var pos: usize = 0;
        if (self.negative) {
            result[0] = '-';
            pos = 1;
        }
        std.mem.copyForwards(u8, result[pos .. pos + topDigits.len], topDigits);
        pos += topDigits.len;

        var i: usize = self.limbs.len - 1;
        while (i > 0) {
            i -= 1;
            var buf: [LIMB_DIGITS]u8 = undefined;
            formatLimbPadded(self.limbs[i], &buf);
            std.mem.copyForwards(u8, result[pos .. pos + LIMB_DIGITS], buf[0..]);
            pos += LIMB_DIGITS;
        }

        return result;
    }
};

// =====================================================================
// Internal helpers: pure magnitude (unsigned) arithmetic on []u32.
// All of these treat their input slices as normalized (no trailing
// zero limbs) and return newly-allocated, normalized output slices.
// =====================================================================

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

/// Take ownership of `arr` and return a normalized (no trailing zero
/// limbs) slice with the same value, reallocating (and freeing `arr`)
/// only if trimming is actually needed.
fn normalizeOwned(allocator: std.mem.Allocator, arr: []u32) ![]u32 {
    var len: usize = arr.len;
    while (len > 0 and arr[len - 1] == 0) : (len -= 1) {}
    if (len == arr.len) return arr;
    const result = try allocator.alloc(u32, len);
    std.mem.copyForwards(u32, result, arr[0..len]);
    allocator.free(arr);
    return result;
}

/// a + b (magnitudes).
fn addMagnitude(allocator: std.mem.Allocator, a: []const u32, b: []const u32) ![]u32 {
    const maxLen = @max(a.len, b.len);
    const result = try allocator.alloc(u32, maxLen + 1);
    var carry: u64 = 0;
    var i: usize = 0;
    while (i < maxLen) : (i += 1) {
        const av: u64 = if (i < a.len) a[i] else 0;
        const bv: u64 = if (i < b.len) b[i] else 0;
        const sum = av + bv + carry;
        result[i] = @intCast(sum % LIMB_BASE);
        carry = sum / LIMB_BASE;
    }
    result[maxLen] = @intCast(carry);
    return normalizeOwned(allocator, result);
}

/// a - b (magnitudes). Requires a >= b (as values); undefined result
/// (garbage, not a crash) otherwise -- callers are responsible for
/// only calling this when that precondition holds.
fn subMagnitude(allocator: std.mem.Allocator, a: []const u32, b: []const u32) ![]u32 {
    std.debug.assert(compareMagnitude(a, b) != .less);
    const result = try allocator.alloc(u32, a.len);
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
        result[i] = @intCast(diff);
    }
    return normalizeOwned(allocator, result);
}

/// a * b (magnitudes), schoolbook O(len(a) * len(b)) multiplication.
/// Column sums are accumulated in u128 before carry-propagation, which
/// is comfortably safe for any input size that fits in memory.
fn mulMagnitude(allocator: std.mem.Allocator, a: []const u32, b: []const u32) ![]u32 {
    if (a.len == 0 or b.len == 0) return allocator.alloc(u32, 0);

    const acc = try allocator.alloc(u128, a.len + b.len);
    defer allocator.free(acc);
    @memset(acc, 0);

    var i: usize = 0;
    while (i < a.len) : (i += 1) {
        if (a[i] == 0) continue;
        var j: usize = 0;
        while (j < b.len) : (j += 1) {
            acc[i + j] += @as(u128, a[i]) * @as(u128, b[j]);
        }
    }

    const result = try allocator.alloc(u32, acc.len);
    var carry: u128 = 0;
    i = 0;
    while (i < acc.len) : (i += 1) {
        const total = acc[i] + carry;
        result[i] = @intCast(total % LIMB_BASE);
        carry = total / LIMB_BASE;
    }
    std.debug.assert(carry == 0); // fits by construction: len(a)+len(b) limbs suffice.
    return normalizeOwned(allocator, result);
}

/// mag * scalar, where scalar is a single limb value (< LIMB_BASE).
fn mulMagnitudeBySmall(allocator: std.mem.Allocator, mag: []const u32, scalar: u32) ![]u32 {
    if (mag.len == 0 or scalar == 0) return allocator.alloc(u32, 0);
    const result = try allocator.alloc(u32, mag.len + 1);
    var carry: u64 = 0;
    var i: usize = 0;
    while (i < mag.len) : (i += 1) {
        const prod = @as(u64, mag[i]) * @as(u64, scalar) + carry;
        result[i] = @intCast(prod % LIMB_BASE);
        carry = prod / LIMB_BASE;
    }
    result[mag.len] = @intCast(carry);
    return normalizeOwned(allocator, result);
}

/// Return mag * LIMB_BASE + digit (digit < LIMB_BASE), i.e. shift all
/// limbs up by one position and place `digit` in the new low limb.
fn shiftInLimb(allocator: std.mem.Allocator, mag: []const u32, digit: u32) ![]u32 {
    const result = try allocator.alloc(u32, mag.len + 1);
    result[0] = digit;
    std.mem.copyForwards(u32, result[1..], mag);
    return normalizeOwned(allocator, result);
}

const DivModMagnitudeResult = struct {
    quotient: []u32,
    remainder: []u32,
};

/// Long division of magnitudes: dividend = divisor * quotient + remainder,
/// 0 <= remainder < divisor. `divisor` must be non-zero (checked by the
/// caller, BigInt.divMod). Implemented as classic grade-school long
/// division, one base-LIMB_BASE digit at a time, using binary search
/// (over the ~1e9 possible digit values) to find each quotient digit.
fn divModMagnitude(allocator: std.mem.Allocator, dividend: []const u32, divisor: []const u32) !DivModMagnitudeResult {
    std.debug.assert(divisor.len > 0);

    if (compareMagnitude(dividend, divisor) == .less) {
        return DivModMagnitudeResult{
            .quotient = try allocator.alloc(u32, 0),
            .remainder = try allocator.dupe(u32, dividend),
        };
    }

    const quotient = try allocator.alloc(u32, dividend.len);
    @memset(quotient, 0);
    var remainder: []u32 = try allocator.alloc(u32, 0);

    var i: usize = dividend.len;
    while (i > 0) {
        i -= 1;

        // Bring down the next limb: remainder = remainder * LIMB_BASE + dividend[i]
        const shifted = try shiftInLimb(allocator, remainder, dividend[i]);
        allocator.free(remainder);
        remainder = shifted;

        // Binary search for the largest digit in [0, LIMB_BASE) such
        // that digit * divisor <= remainder.
        var lo: u32 = 0;
        var hi: u32 = LIMB_BASE - 1;
        var digit: u32 = 0;
        while (lo <= hi) {
            const mid = lo + (hi - lo) / 2;
            const prod = try mulMagnitudeBySmall(allocator, divisor, mid);
            const feasible = compareMagnitude(prod, remainder) != .greater;
            allocator.free(prod);
            if (feasible) {
                digit = mid;
                if (mid == LIMB_BASE - 1) break;
                lo = mid + 1;
            } else {
                if (mid == 0) break;
                hi = mid - 1;
            }
        }
        quotient[i] = digit;

        // remainder -= digit * divisor
        const toSubtract = try mulMagnitudeBySmall(allocator, divisor, digit);
        const newRemainder = try subMagnitude(allocator, remainder, toSubtract);
        allocator.free(toSubtract);
        allocator.free(remainder);
        remainder = newRemainder;
    }

    const trimmedQuotient = try normalizeOwned(allocator, quotient);
    return DivModMagnitudeResult{ .quotient = trimmedQuotient, .remainder = remainder };
}

// =====================================================================
// Sanity-check harness. Runs a handful of hand-verified test cases and
// aborts (via std.debug.assert) on the first mismatch, printing every
// check as it passes.
// =====================================================================

fn expectString(label: []const u8, got: []const u8, want: []const u8) void {
    const ok = std.mem.eql(u8, got, want);
    std.debug.print("  [{s}] got={s} want={s} -> {s}\n", .{ label, got, want, if (ok) "OK" else "FAIL" });
    std.debug.assert(ok);
}

pub fn main() !void {
    var arena = std.heap.ArenaAllocator.init(std.heap.page_allocator);
    defer arena.deinit();
    const a = arena.allocator();

    std.debug.print("=== bigint.zig sanity checks ===\n", .{});

    // 1. 999999999999999999 + 1 == 1000000000000000000
    {
        var x = try BigInt.fromString(a, "999999999999999999");
        var y = try BigInt.fromI64(a, 1);
        var sum = try BigInt.add(x, y);
        const s = try sum.toString(a);
        expectString("999999999999999999 + 1", s, "1000000000000000000");
        x.deinit();
        y.deinit();
        sum.deinit();
    }

    // 2. 123456789012345678901234567890 * 2 == 246913578024691357802469135780
    {
        var x = try BigInt.fromString(a, "123456789012345678901234567890");
        var two = try BigInt.fromI64(a, 2);
        var prod = try BigInt.mul(x, two);
        const s = try prod.toString(a);
        expectString("123456789012345678901234567890 * 2", s, "246913578024691357802469135780");
        x.deinit();
        two.deinit();
        prod.deinit();
    }

    // 3. Division with remainder:
    //    987654321098765432109876543210 / 333333333333
    //      = 2962962963299259259 remainder 97642962963
    //    (cross-checked independently with Python's // and %)
    {
        var num = try BigInt.fromString(a, "987654321098765432109876543210");
        var den = try BigInt.fromString(a, "333333333333");
        var dm = try BigInt.divMod(num, den);
        const qs = try dm.quotient.toString(a);
        const rs = try dm.remainder.toString(a);
        expectString("987654321098765432109876543210 / 333333333333 (quotient)", qs, "2962962963299259259");
        expectString("987654321098765432109876543210 % 333333333333 (remainder)", rs, "97642962963");

        // Cross-check: den * quotient + remainder == num
        var reconstructed_mul = try BigInt.mul(den, dm.quotient);
        var reconstructed = try BigInt.add(reconstructed_mul, dm.remainder);
        std.debug.assert(reconstructed.eql(num));
        std.debug.print("  [reconstruction: den*q + r == num] OK\n", .{});

        num.deinit();
        den.deinit();
        dm.quotient.deinit();
        dm.remainder.deinit();
        reconstructed_mul.deinit();
        reconstructed.deinit();
    }

    // 4. Subtraction: 1000000000000000000 - 999999999999999999 == 1
    {
        var x = try BigInt.fromString(a, "1000000000000000000");
        var y = try BigInt.fromString(a, "999999999999999999");
        var diff = try BigInt.sub(x, y);
        const s = try diff.toString(a);
        expectString("1000000000000000000 - 999999999999999999", s, "1");
        x.deinit();
        y.deinit();
        diff.deinit();
    }

    // 5. Negative numbers: -123456789012345678901234567890 + 123456789012345678901234567890 == 0
    {
        var x = try BigInt.fromString(a, "-123456789012345678901234567890");
        var y = try BigInt.fromString(a, "123456789012345678901234567890");
        var sum = try BigInt.add(x, y);
        const s = try sum.toString(a);
        expectString("-N + N", s, "0");
        std.debug.assert(sum.isZero());
        x.deinit();
        y.deinit();
        sum.deinit();
    }

    // 6. Truncating division semantics with negatives: -7 / 2 == -3 remainder -1
    {
        var x = try BigInt.fromI64(a, -7);
        var y = try BigInt.fromI64(a, 2);
        var dm = try BigInt.divMod(x, y);
        const qs = try dm.quotient.toString(a);
        const rs = try dm.remainder.toString(a);
        expectString("-7 / 2 (quotient, truncating)", qs, "-3");
        expectString("-7 % 2 (remainder)", rs, "-1");
        x.deinit();
        y.deinit();
        dm.quotient.deinit();
        dm.remainder.deinit();
    }

    // 7. i64::MIN round-trips correctly (magnitude doesn't fit in i64).
    {
        var x = try BigInt.fromI64(a, std.math.minInt(i64));
        const s = try x.toString(a);
        expectString("i64 min round-trip", s, "-9223372036854775808");
        x.deinit();
    }

    // 8. Comparisons.
    {
        var neg5 = try BigInt.fromI64(a, -5);
        var pos3 = try BigInt.fromI64(a, 3);
        var hundred = try BigInt.fromI64(a, 100);
        var hundredAgain = try BigInt.fromString(a, "100");
        var negHundred = try BigInt.fromI64(a, -100);

        std.debug.assert(BigInt.compare(neg5, pos3) == .less);
        std.debug.assert(BigInt.compare(hundred, hundredAgain) == .equal);
        std.debug.assert(BigInt.compare(negHundred, negHundred) == .equal);
        std.debug.assert(BigInt.compare(negHundred, pos3) == .less);
        std.debug.assert(BigInt.compare(pos3, negHundred) == .greater);
        std.debug.print("  [comparisons] OK\n", .{});

        neg5.deinit();
        pos3.deinit();
        hundred.deinit();
        hundredAgain.deinit();
        negHundred.deinit();
    }

    // 9. Leading zeros / sign parsing edge cases.
    {
        var z1 = try BigInt.fromString(a, "-0");
        std.debug.assert(z1.isZero() and !z1.negative);
        var z2 = try BigInt.fromString(a, "007");
        const s2 = try z2.toString(a);
        expectString("\"007\" parses as", s2, "7");
        z1.deinit();
        z2.deinit();
    }

    std.debug.print("=== all sanity checks passed ===\n", .{});
}
