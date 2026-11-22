// Derived from MIT/GNU Scheme C sources (`src/x11/x11color.c`):
// Copyright (C) 1986-2022 Massachusetts Institute of Technology
// Licensed under the GNU General Public License (GPL v2 or later); see src/COPYING.

const std = @import("std");
const x11 = @import("x11.zig");
const c = x11.c;
const base = x11.base;

// Visuals

pub export fn x_window_visual(xw: *c.struct_xwindow) callconv(.c) ?*c.struct_xvisual {
    var a: c.XWindowAttributes = undefined;
    if (c.XGetWindowAttributes(xw.xd.*.display, xw.window, &a) == 0) {
        return null;
    }
    return base.allocate_x_visual(a.visual.?);
}

pub export fn x_get_visual_info(
    xd: *c.struct_xdisplay,
    mask: c_long,
    info: ?*c.XVisualInfo,
    items_return: *?[*]c.XVisualInfo,
    nitems_return: *c_int,
) callconv(.c) void {
    items_return.* = c.XGetVisualInfo(xd.display, mask, info, nitems_return);
}

// Colormaps

pub export fn x_window_colormap(xw: *c.struct_xwindow) callconv(.c) ?*c.struct_xcolormap {
    var a: c.XWindowAttributes = undefined;
    if (c.XGetWindowAttributes(xw.xd.*.display, xw.window, &a) == 0) {
        return null;
    }
    return base.allocate_x_colormap(a.colormap, xw.xd.?);
}

pub export fn x_set_window_colormap(xw: *c.struct_xwindow, xcm: *c.struct_xcolormap) callconv(.c) void {
    _ = c.XSetWindowColormap(xw.xd.*.display, xw.window, xcm.colormap);
}

pub export fn x_create_colormap(
    xw: *c.struct_xwindow,
    visual: *c.struct_xvisual,
    writable_p: c_int,
) callconv(.c) ?*c.struct_xcolormap {
    const cmap = c.XCreateColormap(xw.xd.*.display, xw.window, visual.visual, writable_p);
    return base.allocate_x_colormap(cmap, xw.xd.?);
}

pub export fn x_free_colormap(xcm: *c.struct_xcolormap) callconv(.c) void {
    _ = c.XFreeColormap(xcm.xd.*.display, xcm.colormap);
    base.deallocate_x_colormap(xcm);
}

pub export fn x_allocate_color(
    xcm: *c.struct_xcolormap,
    red: c_uint,
    green: c_uint,
    blue: c_uint,
) callconv(.c) c_long {
    if (red >= 65536 or green >= 65536 or blue >= 65536) {
        return -1;
    }
    var col: c.XColor = std.mem.zeroes(c.XColor);
    col.red = @intCast(red);
    col.green = @intCast(green);
    col.blue = @intCast(blue);
    if (c.XAllocColor(xcm.xd.*.display, xcm.colormap, &col) != 0) {
        return @intCast(col.pixel);
    }
    return -1;
}

fn makeXColor(pixel: c_int, red: c_int, green: c_int, blue: c_int) c.XColor {
    var col: c.XColor = std.mem.zeroes(c.XColor);
    col.pixel = @intCast(@as(c_uint, @bitCast(pixel)));
    if (red != -1) {
        col.red = @intCast(red);
        col.flags |= c.DoRed;
    }
    if (green != -1) {
        col.green = @intCast(green);
        col.flags |= c.DoGreen;
    }
    if (blue != -1) {
        col.blue = @intCast(blue);
        col.flags |= c.DoBlue;
    }
    return col;
}

pub export fn x_store_color(
    xcm: *c.struct_xcolormap,
    pixel: c_int,
    red: c_int,
    green: c_int,
    blue: c_int,
) callconv(.c) void {
    var col = makeXColor(pixel, red, green, blue);
    _ = c.XStoreColor(xcm.xd.*.display, xcm.colormap, &col);
}

pub export fn x_store_colors(
    xcm: *c.struct_xcolormap,
    color_vector: [*]const c_int,
    n_colors: c_ulong,
) callconv(.c) void {
    const count: usize = @intCast(n_colors);
    if (count == 0) {
        _ = c.XStoreColors(xcm.xd.*.display, xcm.colormap, null, 0);
        return;
    }
    const colors = std.heap.c_allocator.alloc(c.XColor, count) catch return;
    defer std.heap.c_allocator.free(colors);

    for (colors, 0..) |*col, i| {
        const base_idx = i * 4;
        col.* = makeXColor(
            color_vector[base_idx],
            color_vector[base_idx + 1],
            color_vector[base_idx + 2],
            color_vector[base_idx + 3],
        );
    }
    _ = c.XStoreColors(xcm.xd.*.display, xcm.colormap, colors.ptr, @intCast(count));
}

pub export fn x_query_color(
    xcm: *c.struct_xcolormap,
    pixel: c_ulong,
    results: *[3]c_uint,
) callconv(.c) void {
    var col: c.XColor = std.mem.zeroes(c.XColor);
    col.pixel = pixel;
    _ = c.XQueryColor(xcm.xd.*.display, xcm.colormap, &col);
    results.* = .{ col.red, col.green, col.blue };
}
