// x25519.zig
//
// X25519 (Curve25519 Diffie-Hellman function), implemented literally per
// RFC 7748 Section 5 ("The X25519 and X448 Functions") using the
// from-scratch `bigint.zig` sign-magnitude BigInt library for all
// underlying field arithmetic mod p = 2^255 - 19.
//
// This is a standard, publicly documented algorithm (used in TLS 1.3,
// SSH, Signal, WireGuard, etc.) implemented here as an algorithms/bigint
// exercise: the goal is bit-exact reproduction of the official RFC 7748
// Section 5.2 test vectors, not production-grade / constant-time
// side-channel hardening. In particular `cswap` below is an ordinary
// (non-constant-time) conditional swap of BigInt values, which is fine
// for this purpose but would NOT be fine in a real security-sensitive
// implementation.
//
// RFC 7748 Section 5 pseudocode being followed:
//
//   x1 = u
//   x2 = 1
//   z2 = 0
//   x3 = u
//   z3 = 1
//   swap = 0
//
//   For t = bits-1 down to 0:
//       k_t = (k >> t) & 1
//       swap ^= k_t
//       (x2, x3) = cswap(swap, x2, x3)
//       (z2, z3) = cswap(swap, z2, z3)
//       swap = k_t
//
//       A = x2 + z2
//       AA = A^2
//       B = x2 - z2
//       BB = B^2
//       E = AA - BB
//       C = x3 + z3
//       D = x3 - z3
//       DA = D * A
//       CB = C * B
//       x3 = (DA + CB)^2
//       z3 = x1 * (DA - CB)^2
//       x2 = AA * BB
//       z2 = E * (AA + a24 * E)
//
//   (x2, x3) = cswap(swap, x2, x3)
//   (z2, z3) = cswap(swap, z2, z3)
//   Return x2 * (z2^(p - 2))
//
// with p = 2^255 - 19, a24 = 121665, bits = 255.

const std = @import("std");
const bigint = @import("bigint.zig");
const BigInt = bigint.BigInt;

/// p = 2^255 - 19, decimal, for Curve25519 / X25519.
const P_DECIMAL = "57896044618658097711785492504343953926634992332820282019728792003956564819949";

/// a24 = (486662 - 2) / 4 = 121665, the Montgomery-curve constant for
/// Curve25519 used in the ladder step z2 = E * (AA + a24 * E).
const A24: i64 = 121665;

// =====================================================================
// Field arithmetic mod p, built on top of BigInt add/sub/mul/divMod.
// All of these allocate fresh BigInts using the arena allocator supplied
// by the caller; nothing is explicitly deinit'd (the whole computation
// runs inside a single arena that is freed once at the end).
// =====================================================================

/// Reduce x into [0, p) by truncating divMod followed by a correction
/// for negative remainders (BigInt.divMod's remainder takes the sign of
/// the dividend, matching Zig's @rem, not Euclidean/"mod" semantics).
fn modReduce(x: BigInt, p: BigInt) !BigInt {
    const dm = try BigInt.divMod(x, p);
    if (dm.remainder.negative) {
        return BigInt.add(dm.remainder, p);
    }
    return dm.remainder;
}

fn addMod(a: BigInt, b: BigInt, p: BigInt) !BigInt {
    return modReduce(try BigInt.add(a, b), p);
}

fn subMod(a: BigInt, b: BigInt, p: BigInt) !BigInt {
    return modReduce(try BigInt.sub(a, b), p);
}

fn mulMod(a: BigInt, b: BigInt, p: BigInt) !BigInt {
    return modReduce(try BigInt.mul(a, b), p);
}

/// base^exp mod modulus via standard right-to-left binary exponentiation.
/// `exp` must be non-negative. Used for the Fermat's-little-theorem
/// modular inverse z^(p-2) mod p that RFC 7748 specifies for the final
/// ladder step (p is prime, so z^(p-2) == z^-1 mod p for z != 0).
fn modPow(allocator: std.mem.Allocator, base_in: BigInt, exp_in: BigInt, modulus: BigInt) !BigInt {
    var result = try BigInt.fromI64(allocator, 1);
    var base = try modReduce(base_in, modulus);
    var exp = exp_in;
    const two = try BigInt.fromI64(allocator, 2);

    while (!exp.isZero()) {
        const dm = try BigInt.divMod(exp, two);
        if (!dm.remainder.isZero()) {
            result = try mulMod(result, base, modulus);
        }
        base = try mulMod(base, base, modulus);
        exp = dm.quotient;
    }
    return result;
}

// =====================================================================
// RFC 7748 Section 5 decoding helpers.
// =====================================================================

/// decodeLittleEndian(b): interprets a little-endian byte array as the
/// integer sum(b[i] * 256^i), per RFC 7748 Section 5.
fn decodeLittleEndian(allocator: std.mem.Allocator, bytes: []const u8) !BigInt {
    var value = try BigInt.fromI64(allocator, 0);
    const base256 = try BigInt.fromI64(allocator, 256);
    var i: usize = bytes.len;
    while (i > 0) {
        i -= 1;
        const byteVal = try BigInt.fromI64(allocator, @intCast(bytes[i]));
        value = try BigInt.add(try BigInt.mul(value, base256), byteVal);
    }
    return value;
}

/// decodeUCoordinate for the 255-bit (X25519) case: mask the most
/// significant bit of the final byte (bit 255) to zero before decoding,
/// per RFC 7748 Section 5 ("since bits (in our case) is 255, one bit is
/// masked").
fn decodeUCoordinate(allocator: std.mem.Allocator, u_in: [32]u8) !BigInt {
    var u = u_in;
    u[31] &= 0x7f;
    return decodeLittleEndian(allocator, &u);
}

/// decodeScalar25519 per RFC 7748 Section 5: clear the low 3 bits of the
/// first byte, clear the high bit and set bit 6 of the last byte. This
/// is the standard X25519 scalar clamping. Returned as raw clamped bytes
/// (not a BigInt) since we extract individual bits from it directly in
/// the ladder loop below.
fn decodeScalar25519(k_in: [32]u8) [32]u8 {
    var k = k_in;
    k[0] &= 248;
    k[31] &= 127;
    k[31] |= 64;
    return k;
}

/// Bit t (0 = least significant) of a 32-byte little-endian scalar.
fn scalarBit(k: [32]u8, t: usize) bool {
    const byte = k[t / 8];
    const shift: u3 = @intCast(t % 8);
    return ((byte >> shift) & 1) == 1;
}

fn cswap(swap: bool, a: *BigInt, b: *BigInt) void {
    if (swap) {
        const tmp = a.*;
        a.* = b.*;
        b.* = tmp;
    }
}

// =====================================================================
// The X25519 function itself: the Montgomery ladder from RFC 7748
// Section 5, specialized to Curve25519 (p = 2^255-19, a24 = 121665,
// bits = 255).
// =====================================================================

pub fn x25519(allocator: std.mem.Allocator, k_bytes: [32]u8, u_bytes: [32]u8) ![32]u8 {
    const p = try BigInt.fromString(allocator, P_DECIMAL);
    const a24 = try BigInt.fromI64(allocator, A24);

    const k = decodeScalar25519(k_bytes);
    const u = try decodeUCoordinate(allocator, u_bytes);

    const x1 = u;
    var x2 = try BigInt.fromI64(allocator, 1);
    var z2 = try BigInt.fromI64(allocator, 0);
    var x3 = try u.clone();
    var z3 = try BigInt.fromI64(allocator, 1);
    var swap = false;

    // bits = 255, so t ranges from 254 down to 0 (t = bits - 1 .. 0).
    var t: i32 = 254;
    while (t >= 0) : (t -= 1) {
        const tIdx: usize = @intCast(t);
        const kt = scalarBit(k, tIdx);

        swap = swap != kt; // swap ^= k_t
        cswap(swap, &x2, &x3);
        cswap(swap, &z2, &z3);
        swap = kt;

        const A = try addMod(x2, z2, p);
        const AA = try mulMod(A, A, p);
        const B = try subMod(x2, z2, p);
        const BB = try mulMod(B, B, p);
        const E = try subMod(AA, BB, p);
        const C = try addMod(x3, z3, p);
        const D = try subMod(x3, z3, p);
        const DA = try mulMod(D, A, p);
        const CB = try mulMod(C, B, p);

        const dapcb = try addMod(DA, CB, p);
        x3 = try mulMod(dapcb, dapcb, p);

        const damcb = try subMod(DA, CB, p);
        const damcb2 = try mulMod(damcb, damcb, p);
        z3 = try mulMod(x1, damcb2, p);

        x2 = try mulMod(AA, BB, p);

        const a24E = try mulMod(a24, E, p);
        const aaPlus = try addMod(AA, a24E, p);
        z2 = try mulMod(E, aaPlus, p);
    }

    cswap(swap, &x2, &x3);
    cswap(swap, &z2, &z3);

    const two = try BigInt.fromI64(allocator, 2);
    const pMinus2 = try BigInt.sub(p, two);
    const zInv = try modPow(allocator, z2, pMinus2, p);
    const result = try mulMod(x2, zInv, p);

    return encodeUCoordinate(allocator, result);
}

/// Encode a field element (already reduced into [0, p)) as 32
/// little-endian bytes, per RFC 7748 Section 5's implicit encoding
/// (inverse of decodeLittleEndian / decodeUCoordinate).
fn encodeUCoordinate(allocator: std.mem.Allocator, value_in: BigInt) ![32]u8 {
    var out: [32]u8 = [_]u8{0} ** 32;
    var value = value_in;
    const base256 = try BigInt.fromI64(allocator, 256);
    var i: usize = 0;
    while (i < 32) : (i += 1) {
        const dm = try BigInt.divMod(value, base256);
        // divisor is 256 < LIMB_BASE (1e9), so the remainder (< 256)
        // fits entirely in a single limb (or is the empty/zero magnitude).
        const rem: u32 = if (dm.remainder.limbs.len > 0) dm.remainder.limbs[0] else 0;
        out[i] = @intCast(rem);
        value = dm.quotient;
    }
    return out;
}

// =====================================================================
// Hex helpers (test-vector I/O only; not part of the RFC algorithm).
// =====================================================================

fn hexDigit(c: u8) u8 {
    return switch (c) {
        '0'...'9' => c - '0',
        'a'...'f' => c - 'a' + 10,
        'A'...'F' => c - 'A' + 10,
        else => unreachable,
    };
}

fn hexToBytes32(hex: []const u8) [32]u8 {
    std.debug.assert(hex.len == 64);
    var out: [32]u8 = undefined;
    var i: usize = 0;
    while (i < 32) : (i += 1) {
        out[i] = (hexDigit(hex[i * 2]) << 4) | hexDigit(hex[i * 2 + 1]);
    }
    return out;
}

fn bytesToHex32(bytes: [32]u8, out: *[64]u8) void {
    const digits = "0123456789abcdef";
    var i: usize = 0;
    while (i < 32) : (i += 1) {
        out[i * 2] = digits[bytes[i] >> 4];
        out[i * 2 + 1] = digits[bytes[i] & 0xf];
    }
}

// =====================================================================
// RFC 7748 Section 5.2 official test vectors.
// =====================================================================

fn runVector(label: []const u8, allocator: std.mem.Allocator, scalar_hex: []const u8, u_hex: []const u8, expected_hex: []const u8) !bool {
    const k = hexToBytes32(scalar_hex);
    const u = hexToBytes32(u_hex);
    const result = try x25519(allocator, k, u);

    var got_hex: [64]u8 = undefined;
    bytesToHex32(result, &got_hex);

    const ok = std.mem.eql(u8, &got_hex, expected_hex);
    std.debug.print("[{s}]\n  scalar:   {s}\n  u-coord:  {s}\n  expected: {s}\n  actual:   {s}\n  -> {s}\n\n", .{
        label, scalar_hex, u_hex, expected_hex, got_hex, if (ok) "PASS" else "FAIL",
    });
    return ok;
}

pub fn main() !void {
    var arena = std.heap.ArenaAllocator.init(std.heap.page_allocator);
    defer arena.deinit();
    const a = arena.allocator();

    std.debug.print("=== X25519 (RFC 7748 Section 5) test vectors ===\n\n", .{});

    // RFC 7748 Section 5.2, first X25519 test vector.
    const ok1 = try runVector(
        "RFC 7748 5.2 - X25519 test 1",
        a,
        "a546e36bf0527c9d3b16154b82465edd62144c0ac1fc5a18506a2244ba449ac4",
        "e6db6867583030db3594c1a424b15f7c726624ec26b3353b10a903a6d0ab1c4c",
        "c3da55379de9c6908e94ea4df28d084f32eccf03491c71f754b4075577a28552",
    );

    // RFC 7748 Section 5.2, second X25519 test vector.
    const ok2 = try runVector(
        "RFC 7748 5.2 - X25519 test 2",
        a,
        "4b66e9d4d1b4673c5ad22691957d6af5c11b6421e0ea01d42ca4169e7918ba0d",
        "e5210f12786811d3f4b7959d0538ae2c31dbe7106fc03c3efc4cd549c715a493",
        "95cbde9476e8907d7aade45cb4b873f88b595a68799fa152e6f8f7647aac7957",
    );

    std.debug.print("=== summary: test1={s} test2={s} ===\n", .{
        if (ok1) "PASS" else "FAIL",
        if (ok2) "PASS" else "FAIL",
    });

    std.debug.assert(ok1 and ok2);
}
