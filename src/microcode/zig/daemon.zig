// Derived from MIT/GNU Scheme C sources (`src/microcode/daemon.c`):
// Copyright (C) 1986-2022 Massachusetts Institute of Technology
// Licensed under the GNU General Public License (GPL v2 or later); see src/COPYING.

const std = @import("std");
const obj = @import("scheme_obj.zig");
const abi = @import("prim_abi.zig");

// DEFINE_PRIMITIVE ("CLOSE-LOST-OPEN-FILES", Prim_close_lost_open_files, 1, 1, 0)
pub export fn Prim_close_lost_open_files() callconv(.c) obj.SchemeObject {
    abi.primitiveHeader();
    const file_list = abi.argRef(1);
    var smash = obj.pairCdrLoc(file_list);
    var cell = smash[0];
    while (!obj.emptyListP(cell)) {
        const weak_cell = obj.pairCar(cell);
        if (obj.pairCar(weak_cell) == obj.sharp_f) {
            abi.OS_channel_close_noerror(@intCast(obj.unsignedFixnumToLong(obj.pairCdr(weak_cell))));
            cell = obj.pairCdr(cell);
            smash[0] = cell;
        } else {
            smash = obj.pairCdrLoc(cell);
            cell = smash[0];
        }
    }
    return obj.unspecific;
}

// Called inside GC daemon with space guaranteed from preceding GC.
fn rehashPair(pair: obj.SchemeObject, hash_table: obj.SchemeObject, table_size: c_ulong) void {
    const datum = obj.objectDatum(obj.pairCar(pair));
    const hash_address: usize = 2 + @as(usize, @intCast(datum % table_size));
    const new_pair = abi.Free;
    abi.Free += 2;
    new_pair[0] = obj.objectNewType(obj.tc_list, pair);
    new_pair[1] = obj.memoryRef(hash_table, hash_address);
    obj.memorySet(hash_table, hash_address, obj.makePointerObject(obj.tc_list, new_pair));
}

fn rehashBucket(start_bucket: [*]obj.SchemeObject, hash_table: obj.SchemeObject, table_size: c_ulong) void {
    var bucket = start_bucket;
    while (!obj.emptyListP(bucket[0])) {
        const weak_pair = obj.pairCar(bucket[0]);
        if (obj.pairCar(weak_pair) != obj.gc_reclaimed) {
            rehashPair(weak_pair, hash_table, table_size);
        }
        bucket = obj.pairCdrLoc(bucket[0]);
    }
}

fn spliceAndRehashBucket(start_bucket: [*]obj.SchemeObject, hash_table: obj.SchemeObject, table_size: c_ulong) void {
    var bucket = start_bucket;
    while (!obj.emptyListP(bucket[0])) {
        const weak_pair = obj.pairCar(bucket[0]);
        if (obj.pairCar(weak_pair) != obj.gc_reclaimed) {
            rehashPair(weak_pair, hash_table, table_size);
            bucket = obj.pairCdrLoc(bucket[0]);
        } else {
            bucket[0] = obj.pairCdr(bucket[0]);
        }
    }
}

// DEFINE_PRIMITIVE ("REHASH", Prim_rehash, 2, 2, 0)
pub export fn Prim_rehash() callconv(.c) obj.SchemeObject {
    abi.primitiveHeader();
    const unhash_table = abi.argRef(1);
    const hash_table = abi.argRef(2);

    const table_size = obj.vectorLength(unhash_table);
    const ht_buckets = obj.memoryLoc(hash_table, 2);
    @memset(ht_buckets[0..@as(usize, @intCast(table_size))], obj.empty_list);

    const uh_buckets = obj.memoryLoc(unhash_table, 1);
    for (0..@as(usize, @intCast(table_size))) |i| {
        const entry = uh_buckets[i];
        if (obj.pairCar(entry) == obj.sharp_t) {
            spliceAndRehashBucket(obj.pairCdrLoc(entry), hash_table, table_size);
        } else {
            rehashBucket(obj.pairCdrLoc(entry), hash_table, table_size);
        }
    }
    return obj.unspecific;
}

test "daemon close-lost-open-files and rehash splicing" {
    const stubs = @import("test_stubs.zig");
    stubs.resetMockRuntime();

    // Test CLOSE-LOST-OPEN-FILES
    const live_weak = abi.system_pair_cons(@intCast(obj.tc_weak_cons), obj.sharp_t, obj.longToUnsignedFixnum(3));
    const dead_weak = abi.system_pair_cons(@intCast(obj.tc_weak_cons), obj.sharp_f, obj.longToUnsignedFixnum(7));
    const list_head = abi.cons(obj.sharp_f, abi.cons(dead_weak, abi.cons(live_weak, obj.empty_list)));
    stubs.setArgs(&.{list_head});
    try std.testing.expectEqual(obj.unspecific, Prim_close_lost_open_files());
    try std.testing.expectEqual(@as(?c_uint, 7), stubs.last_closed_channel);
    const first_kept = obj.pairCdr(list_head);
    try std.testing.expectEqual(live_weak, obj.pairCar(first_kept));
    try std.testing.expectEqual(obj.empty_list, obj.pairCdr(first_kept));

    // Test REHASH with 2 buckets: bucket 0 splicing (#t), bucket 1 non-splicing (#f)
    const key = abi.cons(obj.sharp_t, obj.sharp_f);
    const kept_w = abi.system_pair_cons(@intCast(obj.tc_weak_cons), key, obj.longToFixnum(1));
    const dead_w0 = abi.system_pair_cons(@intCast(obj.tc_weak_cons), obj.gc_reclaimed, obj.sharp_f);
    const dead_w1 = abi.system_pair_cons(@intCast(obj.tc_weak_cons), obj.gc_reclaimed, obj.sharp_f);

    const b0 = abi.cons(obj.sharp_t, abi.cons(dead_w0, abi.cons(kept_w, obj.empty_list)));
    const b1 = abi.cons(obj.sharp_f, abi.cons(dead_w1, obj.empty_list));
    const unhash_tbl = abi.make_vector(2, obj.sharp_f, true);
    obj.vectorSet(unhash_tbl, 0, b0);
    obj.vectorSet(unhash_tbl, 1, b1);

    const hash_tbl = abi.make_vector(3, obj.sharp_f, true);
    stubs.setArgs(&.{ unhash_tbl, hash_tbl });
    try std.testing.expectEqual(obj.unspecific, Prim_rehash());

    // Dead entry spliced out of bucket 0, left untouched in bucket 1
    try std.testing.expectEqual(kept_w, obj.pairCar(obj.pairCdr(b0)));
    try std.testing.expectEqual(dead_w1, obj.pairCar(obj.pairCdr(b1)));

    const target_slot: usize = 2 + @as(usize, @intCast(obj.objectDatum(key) % 2));
    const rehashed_list = obj.memoryRef(hash_tbl, target_slot);
    try std.testing.expect(obj.pairP(rehashed_list));
    try std.testing.expectEqual(obj.objectNewType(obj.tc_list, kept_w), obj.pairCar(rehashed_list));
}
