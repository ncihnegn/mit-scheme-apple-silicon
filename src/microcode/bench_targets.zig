//! Re-exports of microcode functions with direct Zig entry points, for
//! benchmarks (`zig build bench`). Mirrors smoke.zig, but for timing
//! rather than correctness smoke tests: the benchmark executable imports
//! this module to get at sources that cannot be reached by relative
//! imports from `tests/`.
pub const chacha = @import("crypto/chacha.zig");
pub const keccak = @import("crypto/keccak.zig");
pub const md5 = @import("crypto/md5.zig");
