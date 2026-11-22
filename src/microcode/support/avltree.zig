// Derived from MIT/GNU Scheme C sources (`src/microcode/avltree.h`, `src/microcode/avltree.c`):
// Copyright (C) 1986-2022 Massachusetts Institute of Technology
// Licensed under the GNU General Public License (GPL v2 or later); see src/COPYING.

const std = @import("std");
const primutl = @import("../runtime/primutl.zig");

pub const TreeNode = extern struct {
    height: c_int,
    left: ?*TreeNode,
    rite: ?*TreeNode,
    name: ?[*:0]const u8,
    value: usize,
};

comptime {
    if (@sizeOf(usize) == 8) {
        std.debug.assert(@sizeOf(TreeNode) == 40);
        std.debug.assert(@offsetOf(TreeNode, "height") == 0);
        std.debug.assert(@offsetOf(TreeNode, "left") == 8);
        std.debug.assert(@offsetOf(TreeNode, "rite") == 16);
        std.debug.assert(@offsetOf(TreeNode, "name") == 24);
        std.debug.assert(@offsetOf(TreeNode, "value") == 32);
    }
}

pub export var tree_error_message: ?[*:0]const u8 = null;
pub export var tree_error_noise: ?[*:0]const u8 = null;

var tree_build_bias: usize = 0;

fn treeError(message: [*:0]const u8, noise: ?[*:0]const u8) void {
    tree_error_message = message;
    tree_error_noise = noise;
}

inline fn branchHeight(tree: ?*const TreeNode) c_int {
    return if (tree) |node| node.height else 0;
}

fn updateHeight(node: *TreeNode) void {
    node.height = 1 + @max(branchHeight(node.left), branchHeight(node.rite));
}

fn leafMake(name: [*:0]const u8, value: usize) ?*TreeNode {
    const raw = std.c.malloc(@sizeOf(TreeNode)) orelse {
        treeError("leaf_make: malloc failed.\n", null);
        return null;
    };
    const leaf: *TreeNode = @ptrCast(@alignCast(raw));
    leaf.* = .{
        .name = name,
        .value = value,
        .height = 1,
        .left = null,
        .rite = null,
    };
    return leaf;
}

fn rotateLeft(tree: *TreeNode) *TreeNode {
    const rite = tree.rite.?;
    const beta = rite.left;
    tree.rite = beta;
    rite.left = tree;
    updateHeight(tree);
    updateHeight(rite);
    return rite;
}

fn rotateRite(tree: *TreeNode) *TreeNode {
    const left = tree.left.?;
    const beta = left.rite;
    tree.left = beta;
    left.rite = tree;
    updateHeight(tree);
    updateHeight(left);
    return left;
}

fn rebalanceLeft(tree: *TreeNode) *TreeNode {
    if (1 + branchHeight(tree.rite) >= branchHeight(tree.left)) {
        updateHeight(tree);
        return tree;
    }
    const q = tree.left.?;
    if (branchHeight(q.rite) > branchHeight(q.left)) {
        tree.left = rotateLeft(q);
    }
    return rotateRite(tree);
}

fn rebalanceRite(tree: *TreeNode) *TreeNode {
    if (1 + branchHeight(tree.left) >= branchHeight(tree.rite)) {
        updateHeight(tree);
        return tree;
    }
    const q = tree.rite.?;
    if (branchHeight(q.left) > branchHeight(q.rite)) {
        tree.rite = rotateRite(q);
    }
    return rotateLeft(tree);
}

pub export fn tree_insert(tree: ?*TreeNode, name: [*:0]const u8, value: usize) callconv(.c) ?*TreeNode {
    const node = tree orelse return leafMake(name, value);
    const cmp = primutl.strcmp_ci(name, node.name.?);
    if (cmp == 0) {
        treeError("tree_insert: Duplicate entry %s.\n", name);
        return node;
    } else if (cmp < 0) {
        node.left = tree_insert(node.left, name, value);
        return rebalanceLeft(node);
    } else {
        node.rite = tree_insert(node.rite, name, value);
        return rebalanceRite(node);
    }
}

pub export fn tree_lookup(tree: ?*TreeNode, name: [*:0]const u8) callconv(.c) ?*TreeNode {
    var cur = tree;
    while (cur) |node| {
        const cmp = primutl.strcmp_ci(name, node.name.?);
        if (cmp == 0) return node;
        cur = if (cmp < 0) node.left else node.rite;
    }
    return null;
}

pub export fn tree_build(
    high: usize,
    names: ?[*]const [*:0]const u8,
    value: usize,
) callconv(.c) ?*TreeNode {
    if (high == 0) return null;
    if (high == 1) return leafMake(names.?[0], value);

    const names_arr = names.?;
    var middle: usize = @intCast(high / 2);
    if ((high & 1) == 0) {
        middle -= tree_build_bias;
        tree_build_bias = 1 - tree_build_bias;
    }
    const next: usize = middle + 1;
    const tree = leafMake(names_arr[middle], value + @as(usize, @intCast(middle))) orelse return null;
    tree.left = tree_build(@intCast(middle), names_arr, value);
    tree.rite = tree_build(
        @intCast(@as(usize, @intCast(high)) - next),
        names_arr + next,
        value + @as(usize, @intCast(next)),
    );
    updateHeight(tree);
    return tree;
}

pub export fn tree_free(tree: ?*TreeNode) callconv(.c) void {
    const node = tree orelse return;
    tree_free(node.left);
    tree_free(node.rite);
    std.c.free(@ptrCast(node));
}

fn checkAvlInvariant(node: ?*const TreeNode) !c_int {
    const n = node orelse return 0;
    const lh = try checkAvlInvariant(n.left);
    const rh = try checkAvlInvariant(n.rite);
    const diff = if (lh > rh) lh - rh else rh - lh;
    try std.testing.expect(diff <= 1);
    const expected_h = 1 + @max(lh, rh);
    try std.testing.expectEqual(expected_h, n.height);
    return expected_h;
}

test "avltree build, rotations, case-insensitive lookup, duplicate error, and free" {
    _ = @import("../core/test_stubs.zig");

    tree_error_message = null;
    tree_error_noise = null;
    try std.testing.expectEqual(@as(?*TreeNode, null), tree_build(0, null, 0));

    const sorted = [_][*:0]const u8{
        "alpha", "bravo", "charlie", "delta", "echo", "foxtrot", "golf", "hotel",
    };
    const built = tree_build(sorted.len, &sorted, 100);
    defer tree_free(built);
    try std.testing.expect(tree_error_message == null);
    _ = try checkAvlInvariant(built);

    for (sorted, 0..) |k, idx| {
        const found = tree_lookup(built, k).?;
        try std.testing.expectEqual(@as(usize, 100 + idx), found.value);
    }
    try std.testing.expectEqual(@as(usize, 103), tree_lookup(built, "DELTA").?.value);
    try std.testing.expectEqual(@as(?*TreeNode, null), tree_lookup(built, "zulu"));

    // Duplicate insertion records error without corrupting tree.
    const after_dup = tree_insert(built, "ECHO", 999);
    try std.testing.expectEqual(built, after_dup);
    try std.testing.expect(tree_error_message != null);
    try std.testing.expectEqualStrings("ECHO", std.mem.span(tree_error_noise.?));

    // Exercise LL, RR, LR, RL rotations via ascending, descending, and zigzag insertions.
    const seqs = [_][]const [*:0]const u8{
        &.{ "a", "b", "c", "d", "e", "f", "g" }, // RR
        &.{ "g", "f", "e", "d", "c", "b", "a" }, // LL
        &.{ "m", "e", "t", "a", "i", "g", "k" }, // LR + balanced
        &.{ "a", "z", "m", "y", "n", "x", "o" }, // RL zigzag
    };

    for (seqs) |keys| {
        tree_error_message = null;
        var root: ?*TreeNode = null;
        defer tree_free(root);
        for (keys, 0..) |k, i| {
            root = tree_insert(root, k, @intCast(i));
            try std.testing.expect(tree_error_message == null);
            _ = try checkAvlInvariant(root);
        }
        for (keys, 0..) |k, i| {
            try std.testing.expectEqual(@as(usize, @intCast(i)), tree_lookup(root, k).?.value);
        }
    }
}
