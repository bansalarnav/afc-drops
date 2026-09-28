//! TLS 1.3 integration for QUIC (RFC 9001).
//!
//! QUIC uses TLS 1.3 exclusively for the cryptographic handshake and key
//! derivation; TLS handshake messages are carried in CRYPTO frames rather
//! than being wrapped in TLS records. This module is the seam between the
//! QUIC state machine (`connection.zig`) and a TLS 1.3 implementation: it
//! owns handshake progression, secret derivation, and the resulting AEAD
//! packet-protection keys for each encryption level.
//!
//! Nothing here implements actual TLS 1.3 or QUIC key derivation (HKDF /
//! "quic key"/"quic iv"/"quic hp" labels from RFC 9001 Section 5) yet; this
//! is a placeholder for wiring in either a vendored TLS 1.3 stack or
//! `std.crypto` primitives directly.

const std = @import("std");

/// The four encryption levels QUIC uses over the course of a connection
/// (RFC 9001 Section 4).
pub const EncryptionLevel = enum {
    initial,
    zero_rtt,
    handshake,
    application,
};

/// Coarse handshake progress, mirroring what the QUIC connection state
/// machine needs to know to decide which packet types it may send/receive.
pub const HandshakeState = enum {
    initial,
    in_progress,
    complete,
    failed,
};

/// Directional traffic secrets and derived keys for a single encryption
/// level. Real fields (AEAD key/iv, header-protection key) are left as
/// fixed-size byte arrays sized for a placeholder cipher; the concrete
/// cipher suite selection happens once the handshake negotiates one.
pub const Keys = struct {
    aead_key: [32]u8 = std.mem.zeroes([32]u8),
    aead_iv: [12]u8 = std.mem.zeroes([12]u8),
    hp_key: [32]u8 = std.mem.zeroes([32]u8),
};

/// Per-level read/write key pair.
pub const KeyPair = struct {
    read: Keys = .{},
    write: Keys = .{},
};

/// Owns TLS 1.3 handshake state for one QUIC connection and produces packet
/// protection keys as the handshake progresses through encryption levels.
pub const Handshake = struct {
    state: HandshakeState = .initial,
    is_server: bool = false,

    pub fn initClient(allocator: std.mem.Allocator, server_name: []const u8) !Handshake {
        _ = allocator;
        _ = server_name;
        unreachable; // TODO: implement tls.Handshake.initClient
    }

    pub fn initServer(allocator: std.mem.Allocator) !Handshake {
        _ = allocator;
        unreachable; // TODO: implement tls.Handshake.initServer
    }

    pub fn deinit(self: *Handshake) void {
        _ = self;
        unreachable; // TODO: implement tls.Handshake.deinit
    }

    /// Feeds handshake bytes received via CRYPTO frames at `level` into the
    /// TLS state machine, returning any handshake bytes that should be sent
    /// back out (also via CRYPTO frames).
    pub fn advance(self: *Handshake, level: EncryptionLevel, in: []const u8, out: []u8) !usize {
        _ = self;
        _ = level;
        _ = in;
        _ = out;
        unreachable; // TODO: implement tls.Handshake.advance
    }

    /// Returns the current key pair for `level`, if it has been derived yet.
    pub fn keysFor(self: *const Handshake, level: EncryptionLevel) ?KeyPair {
        _ = self;
        _ = level;
        unreachable; // TODO: implement tls.Handshake.keysFor
    }
};

test "module compiles" {
    try std.testing.expect(true);
}
