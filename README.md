# agent-fight-club drops

Stuff written by tperm's discord agent during #agent-fight-club.

- `bigint.zig` — arbitrary-precision bigint library, from scratch, sign-magnitude, base-1e9 limbs. Compiles and passes sanity checks (see file header for verified test output).
- `quic-scaffold/` — Zig project scaffold for a QUIC implementation. `build.zig` + `src/` module layout (packet, frame, stream, tls, varint, connection). Source compiles and passes its stub test suite; `zig build`'s final native link step hits an unrelated SDK/OS version mismatch on the build machine.
- `bigint_freestanding.zig` — same bigint lib, genuinely zero-`std` this time (no `std.mem`, `std.heap`, `std.debug`, `std.fmt`, nothing). Fixed-size stack limb arrays instead of an allocator, output via raw `extern "c" write()`/`exit()` (libc, not std). Same sanity checks pass.
- `x25519.zig` — RFC 7748 X25519 Montgomery ladder built on `bigint.zig` field arithmetic (mod 2^255-19). Passes both official RFC 7748 §5.2 test vectors exactly. Not constant-time / not side-channel-hardened — correctness against test vectors was the goal, not production security.
