// Derived from MIT/GNU Scheme C sources (`src/microcode/error.c`, `src/microcode/dstack.h`):
// Copyright (C) 1986-2022 Massachusetts Institute of Technology
// Licensed under the GNU General Public License (GPL v2 or later); see src/COPYING.

const std = @import("std");
const ptrvec = @import("ptrvec.zig");
const wind = @import("wind.zig");

extern "c" fn OS_malloc(size: usize) ?*anyopaque;

pub const ConditionType = extern struct {
    index: c_ulong,
    name: ?*anyopaque,
    generalizations: *ptrvec.Ptrvec,
    reporter: ?*const fn (*Condition) callconv(.c) void,
};

pub const Condition = extern struct {
    type: *ConditionType,
    irritants: *ptrvec.Ptrvec,
};

pub const ConditionRestart = extern struct {
    name: ?*anyopaque,
    type: *ConditionType,
    procedure: ?*const fn (?*anyopaque) callconv(.c) void,
};

const HandlerRecord = struct {
    next: ?*HandlerRecord,
    type: ?*ConditionType,
    handler: *const fn (*Condition) callconv(.c) void,
};

const RestartRecord = struct {
    next: ?*RestartRecord,
    contents: ConditionRestart,
};

comptime {
    if (@sizeOf(usize) == 8) {
        std.debug.assert(@sizeOf(ConditionType) == 32);
        std.debug.assert(@sizeOf(Condition) == 16);
        std.debug.assert(@sizeOf(ConditionRestart) == 24);
    }
}

var next_condition_type_index: c_ulong = 0;
var current_handler_record: ?*HandlerRecord = null;
var current_restart_record: ?*RestartRecord = null;

pub export fn initialize_condition_system() callconv(.c) void {
    next_condition_type_index = 0;
    current_handler_record = null;
    current_restart_record = null;
}

pub export fn condition_type_allocate(
    name: ?*anyopaque,
    generalizations: *ptrvec.Ptrvec,
    reporter: ?*const fn (*Condition) callconv(.c) void,
) callconv(.c) *ConditionType {
    const cond_type: *ConditionType = @ptrCast(@alignCast(OS_malloc(@sizeOf(ConditionType)).?));
    const g = generalizationsUnion(generalizations);
    ptrvec.ptrvec_adjoin(g, @ptrCast(cond_type));
    cond_type.index = next_condition_type_index;
    next_condition_type_index += 1;
    cond_type.name = name;
    cond_type.generalizations = g;
    cond_type.reporter = reporter;
    return cond_type;
}

pub export fn condition_type_deallocate(cond_type: *ConditionType) callconv(.c) void {
    ptrvec.ptrvec_deallocate(cond_type.generalizations);
    std.c.free(@ptrCast(cond_type));
}

pub export fn condition_allocate(cond_type: *ConditionType, irritants: *ptrvec.Ptrvec) callconv(.c) *Condition {
    const condition: *Condition = @ptrCast(@alignCast(OS_malloc(@sizeOf(Condition)).?));
    condition.type = cond_type;
    condition.irritants = irritants;
    return condition;
}

pub export fn condition_deallocate(condition: *Condition) callconv(.c) void {
    ptrvec.ptrvec_deallocate(condition.irritants);
    std.c.free(@ptrCast(condition));
}

fn generalizationsUnion2(x: *ptrvec.Ptrvec, y: *ptrvec.Ptrvec) *ptrvec.Ptrvec {
    const len_x: usize = @intCast(x.length);
    const len_y: usize = @intCast(y.length);
    const x_elems: [*]const *ConditionType = if (len_x > 0) @ptrCast(x.elements.?) else undefined;
    const y_elems: [*]const *ConditionType = if (len_y > 0) @ptrCast(y.elements.?) else undefined;

    var length: ptrvec.PtrvecLength = 0;
    var ix_pos: usize = 0;
    var iy_pos: usize = 0;
    while (true) {
        if (ix_pos == len_x) {
            length += @intCast(len_y - iy_pos);
            break;
        }
        if (iy_pos == len_y) {
            length += @intCast(len_x - ix_pos);
            break;
        }
        length += 1;
        const ix = x_elems[ix_pos].index;
        const iy = y_elems[iy_pos].index;
        if (ix <= iy) ix_pos += 1;
        if (iy <= ix) iy_pos += 1;
    }

    const result = ptrvec.ptrvec_allocate(length);
    if (length == 0) return result;
    const out: [*]*ConditionType = @ptrCast(result.elements.?);

    ix_pos = 0;
    iy_pos = 0;
    var out_pos: usize = 0;
    while (true) {
        if (ix_pos == len_x) {
            while (iy_pos < len_y) : (iy_pos += 1) {
                out[out_pos] = y_elems[iy_pos];
                out_pos += 1;
            }
            break;
        }
        if (iy_pos == len_y) {
            while (ix_pos < len_x) : (ix_pos += 1) {
                out[out_pos] = x_elems[ix_pos];
                out_pos += 1;
            }
            break;
        }
        const ix = x_elems[ix_pos].index;
        const iy = y_elems[iy_pos].index;
        if (ix == iy) {
            out[out_pos] = x_elems[ix_pos];
            ix_pos += 1;
            iy_pos += 1;
        } else if (ix < iy) {
            out[out_pos] = x_elems[ix_pos];
            ix_pos += 1;
        } else {
            out[out_pos] = y_elems[iy_pos];
            iy_pos += 1;
        }
        out_pos += 1;
    }
    return result;
}

pub export fn generalizations_union(generalizations: *ptrvec.Ptrvec) callconv(.c) *ptrvec.Ptrvec {
    return generalizationsUnion(generalizations);
}

fn generalizationsUnion(generalizations: *ptrvec.Ptrvec) *ptrvec.Ptrvec {
    const length: usize = @intCast(generalizations.length);
    if (length == 0) return ptrvec.ptrvec_allocate(0);
    const elems: [*]*ptrvec.Ptrvec = @ptrCast(generalizations.elements.?);
    if (length == 1) return ptrvec.ptrvec_copy(elems[0]);
    var result = generalizationsUnion2(elems[0], elems[1]);
    for (2..length) |i| {
        const next = generalizationsUnion2(result, elems[i]);
        ptrvec.ptrvec_deallocate(result);
        result = next;
    }
    return result;
}

pub export fn condition_handler_bind(
    cond_type: ?*ConditionType,
    handler: *const fn (*Condition) callconv(.c) void,
) callconv(.c) void {
    const record: *HandlerRecord = @ptrCast(@alignCast(wind.dstack_alloc(@sizeOf(HandlerRecord)).?));
    record.next = current_handler_record;
    record.type = cond_type;
    record.handler = handler;
    wind.dstack_bind(@ptrCast(&current_handler_record), @ptrCast(record));
}

pub export fn condition_signal(condition: *Condition) callconv(.c) void {
    const generalizations = condition.type.generalizations;
    var record = current_handler_record;
    while (record) |rec| {
        const cond_type = rec.type;
        if (cond_type == null or ptrvec.ptrvec_memq(generalizations, @ptrCast(cond_type.?)) != 0) {
            const position = wind.dstack_position;
            wind.dstack_bind(@ptrCast(&current_handler_record), @ptrCast(rec.next));
            rec.handler(condition);
            wind.dstack_set_position(position);
        }
        record = rec.next;
    }
}

pub export fn condition_restart_bind(
    name: ?*anyopaque,
    cond_type: *ConditionType,
    procedure: ?*const fn (?*anyopaque) callconv(.c) void,
) callconv(.c) void {
    const record: *RestartRecord = @ptrCast(@alignCast(wind.dstack_alloc(@sizeOf(RestartRecord)).?));
    record.next = current_restart_record;
    record.contents.name = name;
    record.contents.type = cond_type;
    record.contents.procedure = procedure;
    wind.dstack_bind(@ptrCast(&current_restart_record), @ptrCast(record));
}

pub export fn condition_restart_find(name: ?*anyopaque, condition: ?*Condition) callconv(.c) ?*ConditionRestart {
    var record = current_restart_record;
    if (condition) |cond| {
        const generalizations = cond.type.generalizations;
        while (record) |rec| {
            if (rec.contents.name == name and ptrvec.ptrvec_memq(generalizations, @ptrCast(rec.contents.type)) != 0) {
                return &rec.contents;
            }
            record = rec.next;
        }
    } else {
        while (record) |rec| {
            if (rec.contents.name == name) return &rec.contents;
            record = rec.next;
        }
    }
    return null;
}

pub export fn condition_restarts(condition: ?*Condition) callconv(.c) *ptrvec.Ptrvec {
    var record = current_restart_record;
    var length: ptrvec.PtrvecLength = 0;
    const generalizations: ?*ptrvec.Ptrvec = if (condition) |cond| cond.type.generalizations else null;

    while (record) |rec| {
        if (generalizations == null or ptrvec.ptrvec_memq(generalizations.?, @ptrCast(rec.contents.type)) != 0) {
            length += 1;
        }
        record = rec.next;
    }

    const result = ptrvec.ptrvec_allocate(length);
    if (length == 0) return result;
    const out = result.elements.?;
    var idx: usize = 0;
    record = current_restart_record;
    while (record) |rec| {
        if (generalizations == null or ptrvec.ptrvec_memq(generalizations.?, @ptrCast(rec.contents.type)) != 0) {
            out[idx] = @ptrCast(&rec.contents);
            idx += 1;
        }
        record = rec.next;
    }
    return result;
}

test "error condition types, generalization unions, handlers, and restarts" {
    wind.dstack_initialize();
    initialize_condition_system();

    const empty_gens = ptrvec.ptrvec_allocate(0);
    defer ptrvec.ptrvec_deallocate(empty_gens);

    const t_root = condition_type_allocate(@ptrFromInt(1), empty_gens, null);
    defer condition_type_deallocate(t_root);

    const t_left = condition_type_allocate(@ptrFromInt(2), empty_gens, null);
    defer condition_type_deallocate(t_left);

    const p1 = ptrvec.ptrvec_allocate(2);
    defer ptrvec.ptrvec_deallocate(p1);
    p1.elements.?[0] = @ptrCast(t_root.generalizations);
    p1.elements.?[1] = @ptrCast(t_left.generalizations);
    const t_child = condition_type_allocate(@ptrFromInt(3), p1, null);
    defer condition_type_deallocate(t_child);

    try std.testing.expectEqual(@as(ptrvec.PtrvecLength, 3), t_child.generalizations.length);
    try std.testing.expect(ptrvec.ptrvec_memq(t_child.generalizations, @ptrCast(t_root)) != 0);
    try std.testing.expect(ptrvec.ptrvec_memq(t_child.generalizations, @ptrCast(t_left)) != 0);
    try std.testing.expect(ptrvec.ptrvec_memq(t_child.generalizations, @ptrCast(t_child)) != 0);

    const State = struct {
        var calls: usize = 0;
        var seen_type: ?*ConditionType = null;
        fn onCond(c: *Condition) callconv(.c) void {
            calls += 1;
            seen_type = c.type;
        }
        fn onRestart(_: ?*anyopaque) callconv(.c) void {}
    };
    State.calls = 0;
    State.seen_type = null;

    const pos = wind.dstack_position;
    condition_handler_bind(t_root, &State.onCond);
    condition_restart_bind(@ptrFromInt(0x123), t_left, &State.onRestart);

    const irr = ptrvec.ptrvec_allocate(0);
    const cond = condition_allocate(t_child, irr);
    defer condition_deallocate(cond);

    condition_signal(cond);
    try std.testing.expectEqual(@as(usize, 1), State.calls);
    try std.testing.expectEqual(t_child, State.seen_type.?);

    try std.testing.expect(condition_restart_find(@ptrFromInt(0x123), cond) != null);
    const rvec = condition_restarts(cond);
    defer ptrvec.ptrvec_deallocate(rvec);
    try std.testing.expectEqual(@as(ptrvec.PtrvecLength, 1), rvec.length);

    wind.dstack_set_position(pos);
    try std.testing.expect(condition_restart_find(@ptrFromInt(0x123), cond) == null);
}
