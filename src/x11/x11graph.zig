// Derived from MIT/GNU Scheme C sources (`src/x11/x11graph.c`):
// Copyright (C) 1986-2022 Massachusetts Institute of Technology
// Licensed under the GNU General Public License (GPL v2 or later); see src/COPYING.

const std = @import("std");
const x11 = @import("x11.zig");
const c = x11.c;
const base = x11.base;

const RESOURCE_NAME: [*:0]const u8 = "schemeGraphics";
const RESOURCE_CLASS: [*:0]const u8 = "SchemeGraphics";
const DEFAULT_GEOMETRY: [*:0]const u8 = "512x384+0+0";
const FLT_MAX: f32 = std.math.floatMax(f32);

const GwExtra = extern struct {
    x_left: f32,
    x_right: f32,
    y_bottom: f32,
    y_top: f32,
    x_slope: f32,
    y_slope: f32,
    x_cursor: c_int,
    y_cursor: c_int,
};

const XWindowGraphics = extern struct {
    xw: c.struct_xwindow,
    extra: GwExtra,
};

inline fn xwExtra(xw: *c.struct_xwindow) *GwExtra {
    const wg: *XWindowGraphics = @ptrCast(@alignCast(xw));
    return &wg.extra;
}

inline fn roundFloat(flonum: f32) c_int {
    return @intFromFloat(if (flonum >= 0.0) flonum + 0.5 else flonum - 0.5);
}

inline fn xCoordinate(vx: f32, xw: *c.struct_xwindow, direction: c_int) c_int {
    const extra = xwExtra(xw);
    if (extra.x_slope == FLT_MAX) {
        return if (direction <= 0) 0 else @as(c_int, @intCast(xw.x_size)) - 1;
    }
    return roundFloat(extra.x_slope * (vx - extra.x_left));
}

inline fn yCoordinate(vy: f32, xw: *c.struct_xwindow, direction: c_int) c_int {
    const extra = xwExtra(xw);
    if (extra.y_slope == FLT_MAX) {
        return if (direction <= 0) @as(c_int, @intCast(xw.y_size)) - 1 else 0;
    }
    return (@as(c_int, @intCast(xw.y_size)) - 1) + roundFloat(extra.y_slope * (vy - extra.y_bottom));
}

inline fn xLength(vlen: f32, xw: *c.struct_xwindow) c_int {
    const extra = xwExtra(xw);
    if (extra.x_slope == 0.0) return 0;
    if (extra.x_slope == FLT_MAX) return @as(c_int, @intCast(xw.x_size)) - 1;
    return roundFloat(@abs(extra.x_slope) * vlen);
}

inline fn yLength(vlen: f32, xw: *c.struct_xwindow) c_int {
    const extra = xwExtra(xw);
    if (extra.y_slope == 0.0) return 0;
    if (extra.y_slope == FLT_MAX) return @as(c_int, @intCast(xw.y_size)) - 1;
    return roundFloat(@abs(extra.y_slope) * vlen);
}

inline fn borderCoord(border: c_uint, coord: c_int) c_int {
    return @as(c_int, @bitCast(border +% @as(c_uint, @bitCast(coord))));
}

fn xCoordinateMap(xw: ?*c.struct_xwindow, x: c_uint) callconv(.c) f32 {
    const w = xw.?;
    const extra = xwExtra(w);
    if (extra.x_slope == 0.0 or extra.x_slope == FLT_MAX) {
        return extra.x_left;
    }
    return (@as(f32, @floatFromInt(x)) / extra.x_slope) + extra.x_left;
}

fn yCoordinateMap(xw: ?*c.struct_xwindow, y: c_uint) callconv(.c) f32 {
    const w = xw.?;
    const extra = xwExtra(w);
    if (extra.y_slope == 0.0 or extra.y_slope == FLT_MAX) {
        return extra.y_bottom;
    }
    const y_max: f32 = @floatFromInt(@as(c_int, @intCast(w.y_size)) - 1);
    return ((@as(f32, @floatFromInt(y)) - y_max) / extra.y_slope) + extra.y_bottom;
}

fn setClipRectangle(
    xw: *c.struct_xwindow,
    x_left_in: c_int,
    y_bottom_in: c_int,
    x_right_in: c_int,
    y_top_in: c_int,
) void {
    var x_left = x_left_in;
    var y_bottom = y_bottom_in;
    var x_right = x_right_in;
    var y_top = y_top_in;

    const display = xw.xd.*.display;
    const ibw = xw.attributes.internal_border_width;

    if (x_left > x_right) {
        std.mem.swap(c_int, &x_left, &x_right);
    }
    if (y_top > y_bottom) {
        std.mem.swap(c_int, &y_top, &y_bottom);
    }

    const width: c_uint = @intCast((x_right + 1) - x_left);
    const height: c_uint = @intCast((y_bottom + 1) - y_top);
    xw.clip_x = @bitCast(x_left);
    xw.clip_y = @bitCast(y_top);
    xw.clip_width = width;
    xw.clip_height = height;

    var rectangles = [1]c.XRectangle{.{
        .x = @truncate(x_left),
        .y = @truncate(y_top),
        .width = @truncate(width),
        .height = @truncate(height),
    }};
    _ = c.XSetClipRectangles(display, xw.normal_gc, ibw, ibw, &rectangles, 1, c.Unsorted);
    _ = c.XSetClipRectangles(display, xw.reverse_gc, ibw, ibw, &rectangles, 1, c.Unsorted);
}

fn resetClipRectangle(xw: *c.struct_xwindow) void {
    setClipRectangle(
        xw,
        0,
        @as(c_int, @intCast(xw.y_size)) - 1,
        @as(c_int, @intCast(xw.x_size)) - 1,
        0,
    );
}

fn resetVirtualDeviceCoordinates(xw: *c.struct_xwindow) void {
    const extra = xwExtra(xw);
    extra.x_slope = if (extra.x_right == extra.x_left)
        FLT_MAX
    else if (xw.x_size <= 1)
        0.0
    else
        @as(f32, @floatFromInt(xw.x_size - 1)) / (extra.x_right - extra.x_left);

    extra.y_slope = if (extra.y_bottom == extra.y_top)
        FLT_MAX
    else if (xw.y_size <= 1)
        0.0
    else
        @as(f32, @floatFromInt(xw.y_size - 1)) / (extra.y_bottom - extra.y_top);

    resetClipRectangle(xw);
}

pub export fn x_graphics_set_vdc_extent(
    xw: *c.struct_xwindow,
    x_left: f32,
    y_bottom: f32,
    x_right: f32,
    y_top: f32,
) callconv(.c) void {
    const extra = xwExtra(xw);
    extra.x_left = x_left;
    extra.y_bottom = y_bottom;
    extra.x_right = x_right;
    extra.y_top = y_top;
    resetVirtualDeviceCoordinates(xw);
}

pub export fn x_graphics_vdc_extent(xw: *c.struct_xwindow, results: *[4]f32) callconv(.c) void {
    const extra = xwExtra(xw);
    results.* = .{ extra.x_left, extra.y_bottom, extra.x_right, extra.y_top };
}

pub export fn x_graphics_reset_clip_rectangle(xw: *c.struct_xwindow) callconv(.c) void {
    resetClipRectangle(xw);
}

pub export fn x_graphics_set_clip_rectangle(
    xw: *c.struct_xwindow,
    x_left: f32,
    y_bottom: f32,
    x_right: f32,
    y_top: f32,
) callconv(.c) void {
    setClipRectangle(
        xw,
        xCoordinate(x_left, xw, -1),
        yCoordinate(y_bottom, xw, -1),
        xCoordinate(x_right, xw, 1),
        yCoordinate(y_top, xw, 1),
    );
}

fn processEvent(xw: ?*c.struct_xwindow, event: [*c]c.XEvent) callconv(.c) void {
    _ = xw;
    _ = event;
}

pub export fn x_graphics_reconfigure(xw: *c.struct_xwindow, width: c_uint, height: c_uint) callconv(.c) void {
    const extra: c_uint = @intCast(2 * xw.attributes.internal_border_width);
    const x_size = if (width < extra) 0 else width - extra;
    const y_size = if (height < extra) 0 else height - extra;
    if (x_size != xw.x_size or y_size != xw.y_size) {
        xw.x_size = x_size;
        xw.y_size = y_size;
        resetVirtualDeviceCoordinates(xw);
        _ = c.XClearWindow(xw.xd.*.display, xw.window);
    }
}

fn wmSetSizeHint(xw: *c.struct_xwindow, geometry_mask: c_int, x: c_int, y: c_int) void {
    const extra: c_int = 2 * xw.attributes.internal_border_width;
    const size_hints = c.XAllocSizeHints() orelse {
        std.debug.print("\nXAllocSizeHints failed!\n", .{});
        return;
    };
    size_hints.*.flags = c.PResizeInc | c.PMinSize | c.PBaseSize |
        (if ((geometry_mask & c.XValue) != 0 and (geometry_mask & c.YValue) != 0) c.USPosition else c.PPosition) |
        (if ((geometry_mask & c.WidthValue) != 0 and (geometry_mask & c.HeightValue) != 0) c.USSize else c.PSize);
    size_hints.*.x = x;
    size_hints.*.y = y;
    size_hints.*.width = @as(c_int, @intCast(xw.x_size)) + extra;
    size_hints.*.height = @as(c_int, @intCast(xw.y_size)) + extra;
    size_hints.*.width_inc = 1;
    size_hints.*.height_inc = 1;
    size_hints.*.min_width = extra;
    size_hints.*.min_height = extra;
    size_hints.*.base_width = extra;
    size_hints.*.base_height = extra;
    c.XSetWMNormalHints(xw.xd.*.display, xw.window, size_hints);
    _ = c.XFree(@ptrCast(size_hints));
}

pub export fn x_graphics_open_window(
    xd: *c.struct_xdisplay,
    geometry: ?[*:0]const u8,
    resource_name_in: ?[*:0]const u8,
    resource_class_in: ?[*:0]const u8,
    map_p: c_int,
) callconv(.c) ?*c.struct_xwindow {
    const display = xd.display;
    const resource_name = resource_name_in orelse RESOURCE_NAME;
    const resource_class = resource_class_in orelse RESOURCE_CLASS;

    var attributes: c.struct_drawing_attributes = undefined;
    if (base.x_default_attributes(display, resource_name, resource_class, &attributes) != 0) {
        return null;
    }

    var wattributes: c.XSetWindowAttributes = std.mem.zeroes(c.XSetWindowAttributes);
    wattributes.background_pixel = attributes.background_pixel;
    wattributes.border_pixel = attributes.border_pixel;
    wattributes.backing_store = c.Always;

    var methods: c.struct_xwindow_methods = .{
        .deallocator = null,
        .event_processor = &processEvent,
        .x_coordinate_map = &xCoordinateMap,
        .y_coordinate_map = &yCoordinateMap,
        .update_normal_hints = null,
    };

    const extra: c_uint = @intCast(2 * attributes.internal_border_width);
    var x_pos: c_int = -1;
    var y_pos: c_int = -1;
    var x_size: c_int = 512;
    var y_size: c_int = 384;
    const geom_str = geometry orelse
        base.x_get_default(display, resource_name, resource_class, "geometry", "Geometry", null);

    const geometry_mask = c.XGeometry(
        display,
        x11.defaultScreen(display),
        geom_str,
        DEFAULT_GEOMETRY,
        @intCast(attributes.border_width),
        1,
        1,
        @intCast(extra),
        @intCast(extra),
        &x_pos,
        &y_pos,
        &x_size,
        &y_size,
    );

    const window = c.XCreateWindow(
        display,
        x11.rootWindow(display, x11.defaultScreen(display)),
        x_pos,
        y_pos,
        @intCast(@as(c_uint, @intCast(x_size)) + extra),
        @intCast(@as(c_uint, @intCast(y_size)) + extra),
        @intCast(attributes.border_width),
        c.CopyFromParent,
        c.CopyFromParent,
        null,
        c.CWBackPixel | c.CWBorderPixel | c.CWBackingStore,
        &wattributes,
    );
    if (window == 0) return null;

    const xw = base.x_make_window(
        xd,
        window,
        x_size,
        y_size,
        &attributes,
        &methods,
        @sizeOf(XWindowGraphics),
    ) orelse return null;

    const g_extra = xwExtra(xw);
    g_extra.x_left = -1.0;
    g_extra.x_right = 1.0;
    g_extra.y_bottom = -1.0;
    g_extra.y_top = 1.0;
    resetVirtualDeviceCoordinates(xw);
    g_extra.x_cursor = 0;
    g_extra.y_cursor = 0;
    wmSetSizeHint(xw, geometry_mask, x_pos, y_pos);

    if (base.xw_set_wm_input_hint(xw, 0) != 0 or
        base.xw_set_wm_name(xw, "scheme-graphics") != 0 or
        base.xw_set_wm_icon_name(xw, "scheme-graphics") != 0 or
        base.xw_make_window_map(xw, resource_name, resource_class, map_p) != 0)
    {
        base.x_close_window(xw);
        return null;
    }
    return xw;
}

pub export fn x_graphics_draw_line(
    xw: *c.struct_xwindow,
    x_start: f32,
    y_start: f32,
    x_end: f32,
    y_end: f32,
) callconv(.c) void {
    const extra = xwExtra(xw);
    const new_x_cursor = xCoordinate(x_end, xw, 0);
    const new_y_cursor = yCoordinate(y_end, xw, 0);
    const ibw: c_uint = @intCast(xw.attributes.internal_border_width);
    _ = c.XDrawLine(
        xw.xd.*.display,
        xw.window,
        xw.normal_gc,
        borderCoord(ibw, xCoordinate(x_start, xw, 0)),
        borderCoord(ibw, yCoordinate(y_start, xw, 0)),
        borderCoord(ibw, new_x_cursor),
        borderCoord(ibw, new_y_cursor),
    );
    extra.x_cursor = new_x_cursor;
    extra.y_cursor = new_y_cursor;
}

pub export fn x_graphics_move_cursor(xw: *c.struct_xwindow, x: f32, y: f32) callconv(.c) void {
    const extra = xwExtra(xw);
    extra.x_cursor = xCoordinate(x, xw, 0);
    extra.y_cursor = yCoordinate(y, xw, 0);
}

pub export fn x_graphics_drag_cursor(xw: *c.struct_xwindow, x: f32, y: f32) callconv(.c) void {
    const extra = xwExtra(xw);
    const new_x_cursor = xCoordinate(x, xw, 0);
    const new_y_cursor = yCoordinate(y, xw, 0);
    const ibw: c_uint = @intCast(xw.attributes.internal_border_width);
    _ = c.XDrawLine(
        xw.xd.*.display,
        xw.window,
        xw.normal_gc,
        borderCoord(ibw, extra.x_cursor),
        borderCoord(ibw, extra.y_cursor),
        borderCoord(ibw, new_x_cursor),
        borderCoord(ibw, new_y_cursor),
    );
    extra.x_cursor = new_x_cursor;
    extra.y_cursor = new_y_cursor;
}

pub export fn x_graphics_draw_point(xw: *c.struct_xwindow, x: f32, y: f32) callconv(.c) void {
    const ibw: c_uint = @intCast(xw.attributes.internal_border_width);
    _ = c.XDrawPoint(
        xw.xd.*.display,
        xw.window,
        xw.normal_gc,
        borderCoord(ibw, xCoordinate(x, xw, 0)),
        borderCoord(ibw, yCoordinate(y, xw, 0)),
    );
}

pub export fn x_graphics_draw_arc(
    xw: *c.struct_xwindow,
    virtual_device_x: f32,
    virtual_device_y: f32,
    radius_x: f32,
    radius_y: f32,
    angle_start: f32,
    angle_sweep: f32,
    fill_p: c_int,
) callconv(.c) void {
    const ibw: c_uint = @intCast(xw.attributes.internal_border_width);
    var x1 = xCoordinate(virtual_device_x - radius_x, xw, 0);
    var x2 = xCoordinate(virtual_device_x + radius_x, xw, 0);
    var y1 = yCoordinate(virtual_device_y + radius_y, xw, 0);
    var y2 = yCoordinate(virtual_device_y - radius_y, xw, 0);
    var angle1: c_int = @rem(@as(c_int, @intFromFloat(angle_start * 64.0)), 64 * 360);
    var angle2: c_int = @intFromFloat(angle_sweep * 64.0);
    if (angle1 < 0) angle1 = (64 * 360) + angle1;
    if (x2 < x1) {
        std.mem.swap(c_int, &x1, &x2);
        angle1 = if (angle1 < 64 * 180) 64 * 180 - angle1 else 64 * 540 - angle1;
        angle2 = -angle2;
    }
    if (y2 < y1) {
        std.mem.swap(c_int, &y1, &y2);
        angle1 = 64 * 360 - angle1;
        angle2 = -angle2;
    }
    const width: c_uint = @intCast(x2 - x1);
    const height: c_uint = @intCast(y2 - y1);
    const dpy = xw.xd.*.display;
    if (fill_p == 0) {
        _ = c.XDrawArc(dpy, xw.window, xw.normal_gc, borderCoord(ibw, x1), borderCoord(ibw, y1), width, height, angle1, angle2);
    } else {
        _ = c.XFillArc(dpy, xw.window, xw.normal_gc, borderCoord(ibw, x1), borderCoord(ibw, y1), width, height, angle1, angle2);
    }
}

pub export fn x_graphics_draw_string(
    xw: *c.struct_xwindow,
    x: f32,
    y: f32,
    string: [*:0]const u8,
) callconv(.c) void {
    const ibw: c_uint = @intCast(xw.attributes.internal_border_width);
    const len: c_int = @intCast(std.mem.len(string));
    _ = c.XDrawString(
        xw.xd.*.display,
        xw.window,
        xw.normal_gc,
        borderCoord(ibw, xCoordinate(x, xw, 0)),
        borderCoord(ibw, yCoordinate(y, xw, 0)),
        string,
        len,
    );
}

pub export fn x_graphics_draw_image_string(
    xw: *c.struct_xwindow,
    x: f32,
    y: f32,
    string: [*:0]const u8,
) callconv(.c) void {
    const ibw: c_uint = @intCast(xw.attributes.internal_border_width);
    const len: c_int = @intCast(std.mem.len(string));
    _ = c.XDrawImageString(
        xw.xd.*.display,
        xw.window,
        xw.normal_gc,
        borderCoord(ibw, xCoordinate(x, xw, 0)),
        borderCoord(ibw, yCoordinate(y, xw, 0)),
        string,
        len,
    );
}

pub export fn x_graphics_set_function(xw: *c.struct_xwindow, function: c_uint) callconv(.c) c_int {
    if (function >= 16) return 1;
    const dpy = xw.xd.*.display;
    const f: c_int = @intCast(function);
    _ = c.XSetFunction(dpy, xw.normal_gc, f);
    _ = c.XSetFunction(dpy, xw.reverse_gc, f);
    return 0;
}

fn transformPoints(
    xw: *c.struct_xwindow,
    x_vector: [*]const f64,
    y_vector: [*]const f64,
    n_points: c_uint,
    points: [*]c.XPoint,
) void {
    const border: c_uint = @intCast(xw.attributes.internal_border_width);
    for (0..n_points) |i| {
        const xv: f32 = @floatCast(x_vector[i]);
        const yv: f32 = @floatCast(y_vector[i]);
        // Match x11graph.c's exact transform_points coordinate calculation.
        points[i].x = @truncate(borderCoord(border, xCoordinate(xv, xw, 0)));
        points[i].y = @truncate(borderCoord(border, xCoordinate(yv, xw, 0)));
    }
}

pub export fn x_graphics_draw_points(
    xw: *c.struct_xwindow,
    x_vector: [*]const f64,
    y_vector: [*]const f64,
    n_points_in: c_uint,
    points_in: [*]c.XPoint,
) callconv(.c) void {
    transformPoints(xw, x_vector, y_vector, n_points_in, points_in);
    var n_points = n_points_in;
    var points = points_in;
    const dpy = xw.xd.*.display;
    while (n_points > 0) {
        const this_send = @min(n_points, 4093);
        n_points -= this_send;
        _ = c.XDrawPoints(dpy, xw.window, xw.normal_gc, points, @intCast(this_send), c.CoordModeOrigin);
        points += this_send;
    }
}

pub export fn x_graphics_draw_lines(
    xw: *c.struct_xwindow,
    x_vector: [*]const f64,
    y_vector: [*]const f64,
    n_points_in: c_uint,
    points_in: [*]c.XPoint,
) callconv(.c) void {
    transformPoints(xw, x_vector, y_vector, n_points_in, points_in);
    var n_points = n_points_in;
    var points = points_in;
    const dpy = xw.xd.*.display;
    while (n_points > 0) {
        const this_send = @min(n_points, 2047);
        n_points -= this_send;
        _ = c.XDrawLines(dpy, xw.window, xw.normal_gc, points, @intCast(this_send), c.CoordModeOrigin);
        points += this_send - 1;
    }
}

pub export fn x_graphics_set_fill_style(xw: *c.struct_xwindow, fill_style: c_uint) callconv(.c) c_int {
    if (fill_style >= 4) return 0;
    const dpy = xw.xd.*.display;
    const fs: c_int = @intCast(fill_style);
    _ = c.XSetFillStyle(dpy, xw.normal_gc, fs);
    _ = c.XSetFillStyle(dpy, xw.reverse_gc, fs);
    return 1;
}

pub export fn x_graphics_set_line_style(xw: *c.struct_xwindow, style: c_uint) callconv(.c) c_int {
    if (style >= 3) return 0;
    const dpy = xw.xd.*.display;
    const st: c_int = @intCast(style);
    _ = c.XSetLineAttributes(dpy, xw.normal_gc, 0, st, c.CapButt, c.JoinMiter);
    _ = c.XSetLineAttributes(dpy, xw.reverse_gc, 0, st, c.CapButt, c.JoinMiter);
    return 1;
}

pub export fn x_graphics_set_dashes(
    xw: *c.struct_xwindow,
    dash_offset: c_int,
    dash_list: [*]const u8,
    dash_list_length: c_int,
) callconv(.c) c_int {
    if (dash_offset >= dash_list_length) return 0;
    const dpy = xw.xd.*.display;
    _ = c.XSetDashes(dpy, xw.normal_gc, dash_offset, dash_list, dash_list_length);
    _ = c.XSetDashes(dpy, xw.reverse_gc, dash_offset, dash_list, dash_list_length);
    return 1;
}

pub export fn x_graphics_copy_area(
    source_xw: *c.struct_xwindow,
    destination_xw: *c.struct_xwindow,
    source_x: c_int,
    source_y: c_int,
    width: c_int,
    height: c_int,
    dest_x: c_int,
    dest_y: c_int,
) callconv(.c) c_int {
    const source_ibw: c_uint = @intCast(source_xw.attributes.internal_border_width);
    const dest_ibw: c_uint = @intCast(destination_xw.attributes.internal_border_width);
    const source_display = source_xw.xd.*.display;
    const dest_display = destination_xw.xd.*.display;
    if (source_display != dest_display) return 0;
    _ = c.XCopyArea(
        source_display,
        source_xw.window,
        destination_xw.window,
        source_xw.normal_gc,
        borderCoord(source_ibw, xCoordinate(@floatFromInt(source_x), source_xw, -1)),
        borderCoord(source_ibw, yCoordinate(@floatFromInt(source_y), source_xw, 1)),
        @intCast(xLength(@floatFromInt(width), source_xw)),
        @intCast(yLength(@floatFromInt(height), source_xw)),
        borderCoord(dest_ibw, xCoordinate(@floatFromInt(dest_x), destination_xw, -1)),
        borderCoord(dest_ibw, yCoordinate(@floatFromInt(dest_y), destination_xw, 1)),
    );
    return 1;
}

pub export fn transform_polygon_points(
    xw: *c.struct_xwindow,
    vector: [*]const f64,
    length: c_int,
    result: [*]c.XPoint,
) callconv(.c) void {
    const border: c_uint = @intCast(xw.attributes.internal_border_width);
    const count: usize = @intCast(@divTrunc(length, 2));
    for (0..count) |i| {
        const x_coord: f32 = @floatCast(vector[2 * i]);
        const y_coord: f32 = @floatCast(vector[2 * i + 1]);
        result[i].x = @truncate(borderCoord(border, xCoordinate(x_coord, xw, 0)));
        result[i].y = @truncate(borderCoord(border, yCoordinate(y_coord, xw, 0)));
    }
}

pub export fn x_graphics_fill_polygon(
    xw: *c.struct_xwindow,
    vector: [*]const f64,
    length: c_uint,
    points: [*]c.XPoint,
) callconv(.c) void {
    transform_polygon_points(xw, vector, @intCast(length), points);
    _ = c.XFillPolygon(
        xw.xd.*.display,
        xw.window,
        xw.normal_gc,
        points,
        @intCast(length / 2),
        c.Nonconvex,
        c.CoordModeOrigin,
    );
}

fn findPixmapFormat(dpy: ?*c.Display, depth: c_int, format: *c.XPixmapFormatValues) bool {
    var n_pixmap_formats: c_int = 0;
    const pixmap_formats = c.XListPixmapFormats(dpy, &n_pixmap_formats) orelse return false;
    defer _ = c.XFree(@ptrCast(pixmap_formats));
    const count: usize = @intCast(n_pixmap_formats);
    for (pixmap_formats[0..count]) |fmt| {
        if (fmt.depth == depth) {
            format.* = fmt;
            return true;
        }
    }
    return false;
}

pub export fn x_create_image(xw: *c.struct_xwindow, width: c_uint, height: c_uint) callconv(.c) ?*c.struct_ximage {
    const window = xw.window;
    const dpy = xw.xd.*.display;
    var attrs: c.XWindowAttributes = undefined;
    var pixmap_format: c.XPixmapFormatValues = undefined;

    _ = c.XGetWindowAttributes(dpy, window, &attrs);
    if (!findPixmapFormat(dpy, attrs.depth, &pixmap_format)) return null;

    var bits_per_line: c_uint = @as(c_uint, @intCast(pixmap_format.bits_per_pixel)) * width;
    const bitmap_pad: c_uint = @intCast(pixmap_format.scanline_pad);
    if ((bits_per_line % bitmap_pad) != 0) {
        bits_per_line += bitmap_pad - (bits_per_line % bitmap_pad);
    }
    const char_bit: c_uint = 8;
    const bytes_per_line: c_uint = (bits_per_line + (char_bit - 1)) / char_bit;
    const data: [*]u8 = @ptrCast(std.c.malloc(@as(usize, height) * @as(usize, bytes_per_line)) orelse return null);

    const img = c.XCreateImage(
        dpy,
        x11.defaultVisualOfScreen(attrs.screen),
        @intCast(attrs.depth),
        c.ZPixmap,
        0,
        data,
        width,
        height,
        @intCast(bitmap_pad),
        @intCast(bytes_per_line),
    );
    return base.allocate_x_image(img);
}

pub export fn x_image_width(ximage: *c.struct_ximage) callconv(.c) c_ulong {
    return @intCast(ximage.image.*.width);
}

pub export fn x_image_height(ximage: *c.struct_ximage) callconv(.c) c_ulong {
    return @intCast(ximage.image.*.height);
}

pub export fn x_bytes_into_image(vector: [*]const u8, length: c_int, ximage: *c.struct_ximage) callconv(.c) c_int {
    const image = ximage.image;
    const width: c_ulong = @intCast(image.*.width);
    const height: c_ulong = @intCast(image.*.height);
    if (@as(c_long, length) != @as(c_long, @intCast(width * height))) {
        return 1;
    }
    var idx: usize = 0;
    for (0..height) |y| {
        for (0..width) |x| {
            x11.imagePutPixel(@ptrCast(image), @intCast(x), @intCast(y), vector[idx]);
            idx += 1;
        }
    }
    return 0;
}

pub export fn x_get_pixel_from_image(xi: *c.struct_ximage, x: c_int, y: c_int) callconv(.c) c_long {
    const image = xi.image;
    if (x >= image.*.width or y >= image.*.height) return -1;
    return @bitCast(x11.imageGetPixel(@ptrCast(image), x, y));
}

pub export fn x_set_pixel_in_image(xi: *c.struct_ximage, x: c_int, y: c_int, pixel: c_ulong) callconv(.c) c_int {
    const image = xi.image;
    if (x >= image.*.width or y >= image.*.height) return 0;
    x11.imagePutPixel(@ptrCast(image), x, y, pixel);
    return 1;
}

pub export fn x_destroy_image(xi: *c.struct_ximage) callconv(.c) void {
    x11.imageDestroy(@ptrCast(xi.image));
    base.deallocate_x_image(xi);
}

pub export fn x_display_image(
    xi: *c.struct_ximage,
    x_offset: c_uint,
    y_offset: c_uint,
    xw: *c.struct_xwindow,
    window_xoff: c_uint,
    window_yoff: c_uint,
    width: c_uint,
    height: c_uint,
) callconv(.c) c_int {
    const image = xi.image;
    const image_width: c_uint = @intCast(image.*.width);
    const image_height: c_uint = @intCast(image.*.height);
    if (x_offset >= image_width or
        y_offset >= image_height or
        width >= ((image_width - x_offset) + 1) or
        height >= ((image_height - y_offset) + 1))
    {
        return 0;
    }
    _ = c.XPutImage(
        xw.xd.*.display,
        xw.window,
        xw.normal_gc,
        image,
        @intCast(x_offset),
        @intCast(y_offset),
        xCoordinate(@floatFromInt(window_xoff), xw, -1),
        yCoordinate(@floatFromInt(window_yoff), xw, 1),
        width,
        height,
    );
    return 1;
}

pub export fn x_read_image(
    xi: *c.struct_ximage,
    x_image_offset: c_long,
    y_image_offset: c_long,
    xw: *c.struct_xwindow,
    x_window_offset: c_long,
    y_window_offset: c_long,
    width: c_long,
    height: c_long,
) callconv(.c) void {
    _ = c.XGetSubImage(
        xw.xd.*.display,
        xw.window,
        @intCast(x_window_offset),
        @intCast(y_window_offset),
        @intCast(width),
        @intCast(height),
        ~@as(c_ulong, 0),
        c.ZPixmap,
        xi.image,
        @intCast(x_image_offset),
        @intCast(y_image_offset),
    );
}

pub export fn x_window_depth(xw: *c.struct_xwindow) callconv(.c) c_int {
    var attrs: c.XWindowAttributes = undefined;
    _ = c.XGetWindowAttributes(xw.xd.*.display, xw.window, &attrs);
    return attrs.depth;
}

pub export fn x_graphics_map_x_coordinate(xw: *c.struct_xwindow, signed_xp: c_int) callconv(.c) f32 {
    const xp: c_uint = if (signed_xp < 0) 0 else @intCast(signed_xp);
    const bx: c_int = @as(c_int, @intCast(xp)) - xw.attributes.internal_border_width;
    const clamped: c_uint = if (bx < 0)
        0
    else if (bx >= @as(c_int, @intCast(xw.x_size)))
        xw.x_size - 1
    else
        @intCast(bx);
    return xCoordinateMap(xw, clamped);
}

pub export fn x_graphics_map_y_coordinate(xw: *c.struct_xwindow, signed_yp: c_int) callconv(.c) f32 {
    const yp: c_uint = if (signed_yp < 0) 0 else @intCast(signed_yp);
    const by: c_int = @as(c_int, @intCast(yp)) - xw.attributes.internal_border_width;
    const clamped: c_uint = if (by < 0)
        0
    else if (by >= @as(c_int, @intCast(xw.y_size)))
        xw.y_size - 1
    else
        @intCast(by);
    return yCoordinateMap(xw, clamped);
}
