// Derived from MIT/GNU Scheme C sources (`src/x11/x11term.c`):
// Copyright (C) 1986-2022 Massachusetts Institute of Technology
// Licensed under the GNU General Public License (GPL v2 or later); see src/COPYING.

const std = @import("std");
const builtin = @import("builtin");
const x11 = @import("x11.zig");
const c = x11.c;
const base = x11.base;

const RESOURCE_NAME: [*:0]const u8 = "schemeTerminal";
const RESOURCE_CLASS: [*:0]const u8 = "SchemeTerminal";
const DEFAULT_GEOMETRY: [*:0]const u8 = "80x40+0+0";
const BLANK_CHAR: u8 = ' ';
const DEFAULT_HL: u8 = 0;

const XTermExtra = extern struct {
    x_size: c_uint,
    y_size: c_uint,
    cursor_x: c_uint,
    cursor_y: c_uint,
    character_map: [*c]u8,
    highlight_map: [*c]u8,
    cursor_visible_p: u8,
    cursor_enabled_p: u8,
};

const XWindowTerm = extern struct {
    xw: c.struct_xwindow,
    extra: XTermExtra,
};

inline fn xwExtra(xw: *c.struct_xwindow) *XTermExtra {
    const wt: *XWindowTerm = @ptrCast(@alignCast(xw));
    return &wt.extra;
}

inline fn charIndex(xw: *c.struct_xwindow, x: c_uint, y: c_uint) usize {
    return @as(usize, y) * @as(usize, xwExtra(xw).x_size) + @as(usize, x);
}

inline fn hlGc(xw: *c.struct_xwindow, hl: c_uint) c.GC {
    return if (hl != 0) xw.reverse_gc else xw.normal_gc;
}

inline fn xtermXPixel(xw: *c.struct_xwindow, x: c_uint) c_int {
    return @as(c_int, @intCast(x)) * x11.fontWidth(xw.attributes.font.?) + xw.attributes.internal_border_width;
}

inline fn xtermYPixel(xw: *c.struct_xwindow, y: c_uint) c_int {
    return @as(c_int, @intCast(y)) * x11.fontHeight(xw.attributes.font.?) + xw.attributes.internal_border_width;
}

inline fn drawChars(xw: *c.struct_xwindow, x: c_uint, y: c_uint, s: [*c]const u8, n: c_uint, gc: c.GC) void {
    const font = xw.attributes.font.?;
    _ = c.XDrawImageString(
        xw.xd.*.display,
        xw.window,
        gc,
        xtermXPixel(xw, x),
        xtermYPixel(xw, y) + x11.fontBase(font),
        s,
        @intCast(n),
    );
}

inline fn cursorInRectangle(
    xw: *c.struct_xwindow,
    x_start: c_uint,
    x_end: c_uint,
    y_start: c_uint,
    y_end: c_uint,
) bool {
    const extra = xwExtra(xw);
    return x_start <= extra.cursor_x and extra.cursor_x < x_end and
        y_start <= extra.cursor_y and extra.cursor_y < y_end;
}

pub export fn xterm_erase_cursor(xw: *c.struct_xwindow) callconv(.c) void {
    const extra = xwExtra(xw);
    if (extra.cursor_visible_p != 0) {
        const x = extra.cursor_x;
        const y = extra.cursor_y;
        const idx = charIndex(xw, x, y);
        drawChars(xw, x, y, extra.character_map + idx, 1, hlGc(xw, extra.highlight_map[idx]));
        extra.cursor_visible_p = 0;
    }
}

pub export fn xterm_draw_cursor(xw: *c.struct_xwindow) callconv(.c) void {
    const extra = xwExtra(xw);
    if (extra.cursor_enabled_p != 0 and extra.cursor_visible_p == 0) {
        const x = extra.cursor_x;
        const y = extra.cursor_y;
        const idx = charIndex(xw, x, y);
        const hl = extra.highlight_map[idx];
        const gc = if (hl != 0 and xw.attributes.foreground_pixel == xw.attributes.cursor_pixel)
            xw.normal_gc
        else
            xw.cursor_gc;
        drawChars(xw, x, y, extra.character_map + idx, 1, gc);
        extra.cursor_visible_p = 1;
    }
}

fn xtermProcessEvent(xw: ?*c.struct_xwindow, event: [*c]c.XEvent) callconv(.c) void {
    _ = xw;
    _ = event;
}

fn xtermMakeSizeHints(font: *const c.XFontStruct, extra: c_uint) ?*c.XSizeHints {
    const size_hints = c.XAllocSizeHints() orelse return null;
    size_hints.*.flags = c.PResizeInc | c.PMinSize | c.PBaseSize;
    size_hints.*.width_inc = x11.fontWidth(font);
    size_hints.*.height_inc = x11.fontHeight(font);
    size_hints.*.min_width = @intCast(extra);
    size_hints.*.min_height = @intCast(extra);
    size_hints.*.base_width = @intCast(extra);
    size_hints.*.base_height = @intCast(extra);
    return size_hints;
}

fn xtermSetWmNormalHints(xw: *c.struct_xwindow, size_hints: *c.XSizeHints) void {
    c.XSetWMNormalHints(xw.xd.*.display, xw.window, size_hints);
    _ = c.XFree(@ptrCast(size_hints));
}

fn xtermUpdateNormalHints(xw: ?*c.struct_xwindow) callconv(.c) void {
    const w = xw.?;
    const extra: c_uint = @intCast(2 * w.attributes.internal_border_width);
    const hints = xtermMakeSizeHints(w.attributes.font.?, extra) orelse return;
    xtermSetWmNormalHints(w, hints);
}

fn xtermDeallocate(xw: ?*c.struct_xwindow) callconv(.c) void {
    const extra = xwExtra(xw.?);
    std.c.free(extra.character_map);
    std.c.free(extra.highlight_map);
}

fn xtermXCoordinateMap(xw: ?*c.struct_xwindow, x: c_uint) callconv(.c) f32 {
    const fw: c_uint = @intCast(x11.fontWidth(xw.?.attributes.font.?));
    return @floatFromInt(x / fw);
}

fn xtermYCoordinateMap(xw: ?*c.struct_xwindow, y: c_uint) callconv(.c) f32 {
    const fh: c_uint = @intCast(x11.fontHeight(xw.?.attributes.font.?));
    return @floatFromInt(y / fh);
}

fn xtermCopyMapLine(
    xw: *c.struct_xwindow,
    x_start: c_uint,
    x_end: c_uint,
    y_from: c_uint,
    y_to: c_uint,
) void {
    const extra = xwExtra(xw);
    const count = x_end - x_start;
    const from_idx = charIndex(xw, x_start, y_from);
    const to_idx = charIndex(xw, x_start, y_to);
    @memcpy(extra.character_map[to_idx .. to_idx + count], extra.character_map[from_idx .. from_idx + count]);
    @memcpy(extra.highlight_map[to_idx .. to_idx + count], extra.highlight_map[from_idx .. from_idx + count]);
}

fn xtermDumpContents(
    xw: *c.struct_xwindow,
    x_start: c_uint,
    x_end: c_uint,
    y_start: c_uint,
    y_end: c_uint,
) void {
    const extra = xwExtra(xw);
    const char_map = extra.character_map;
    const hl_map = extra.highlight_map;
    if (x_start < x_end) {
        var yi = y_start;
        while (yi < y_end) : (yi += 1) {
            const row_idx = charIndex(xw, 0, yi);
            const line_char = char_map + row_idx;
            const line_hl = hl_map + row_idx;
            var xi = x_start;
            while (true) {
                const hl = line_hl[xi];
                var xj = xi + 1;
                while (xj < x_end and line_hl[xj] == hl) : (xj += 1) {}
                drawChars(xw, xi, yi, line_char + xi, xj - xi, hlGc(xw, hl));
                if (xj == x_end) break;
                xi = xj;
            }
        }
        if (cursorInRectangle(xw, x_start, x_end, y_start, y_end)) {
            extra.cursor_visible_p = 0;
            xterm_draw_cursor(xw);
        }
    }
}

pub export fn xterm_dump_rectangle(
    xw: *c.struct_xwindow,
    signed_x: c_int,
    signed_y: c_int,
    width_in: c_uint,
    height_in: c_uint,
) callconv(.c) void {
    const extra = xwExtra(xw);
    const font = xw.attributes.font.?;
    var x: c_uint = if (signed_x < 0) 0 else @intCast(signed_x);
    var y: c_uint = if (signed_y < 0) 0 else @intCast(signed_y);
    var width = width_in;
    var height = height_in;
    const fwidth: c_uint = @intCast(x11.fontWidth(font));
    const fheight: c_uint = @intCast(x11.fontHeight(font));
    const border: c_uint = @intCast(xw.attributes.internal_border_width);

    if (x < border) {
        width -|= border - x;
        x = 0;
    } else {
        x -= border;
    }
    if ((x + width) > xw.x_size) {
        width = xw.x_size -| x;
    }

    if (y < border) {
        height -|= border - y;
        y = 0;
    } else {
        y -= border;
    }
    if ((y + height) > xw.y_size) {
        height = xw.y_size -| y;
    }

    const x_start = x / fwidth;
    var x_end = (x + width + (fwidth - 1)) / fwidth;
    const y_start = y / fheight;
    var y_end = (y + height + (fheight - 1)) / fheight;
    if (x_end > extra.x_size) x_end = extra.x_size;
    if (y_end > extra.y_size) y_end = extra.y_size;
    xtermDumpContents(xw, x_start, x_end, y_start, y_end);
    _ = c.XFlush(xw.xd.*.display);
}

pub export fn xterm_reconfigure(
    xw: *c.struct_xwindow,
    x_csize: c_uint,
    y_csize: c_uint,
) callconv(.c) c_int {
    const extra = xwExtra(xw);
    if (x_csize != extra.x_size or y_csize != extra.y_size) {
        const map_size = @as(usize, x_csize) * @as(usize, y_csize);
        const raw_char = std.c.malloc(map_size) orelse return 1;
        const new_char_map: [*]u8 = @ptrCast(raw_char);
        const raw_hl = std.c.malloc(map_size) orelse {
            std.c.free(raw_char);
            return 1;
        };
        const new_hl_map: [*]u8 = @ptrCast(raw_hl);

        const old_x_csize = extra.x_size;
        const min_x_csize = @min(x_csize, old_x_csize);
        const min_y_csize = @min(y_csize, extra.y_size);
        const x_clipped: i64 = @as(i64, old_x_csize) - @as(i64, x_csize);

        var new_idx: usize = 0;
        var old_idx: usize = 0;
        var new_y: c_uint = 0;
        while (new_y < min_y_csize) : (new_y += 1) {
            @memcpy(new_char_map[new_idx .. new_idx + min_x_csize], extra.character_map[old_idx .. old_idx + min_x_csize]);
            @memcpy(new_hl_map[new_idx .. new_idx + min_x_csize], extra.highlight_map[old_idx .. old_idx + min_x_csize]);
            new_idx += min_x_csize;
            old_idx += min_x_csize;
            if (x_clipped < 0) {
                const pad: usize = @intCast(-x_clipped);
                @memset(new_char_map[new_idx .. new_idx + pad], BLANK_CHAR);
                @memset(new_hl_map[new_idx .. new_idx + pad], DEFAULT_HL);
                new_idx += pad;
            } else if (x_clipped > 0) {
                old_idx += @intCast(x_clipped);
            }
        }
        while (new_y < y_csize) : (new_y += 1) {
            @memset(new_char_map[new_idx .. new_idx + x_csize], BLANK_CHAR);
            @memset(new_hl_map[new_idx .. new_idx + x_csize], DEFAULT_HL);
            new_idx += x_csize;
        }

        std.c.free(extra.character_map);
        std.c.free(extra.highlight_map);

        const x_size: c_uint = @intCast(xtermXPixel(xw, x_csize));
        const y_size: c_uint = @intCast(xtermYPixel(xw, y_csize));
        xw.x_size = x_size;
        xw.y_size = y_size;
        xw.clip_x = 0;
        xw.clip_y = 0;
        xw.clip_width = x_size;
        xw.clip_height = y_size;

        extra.x_size = x_csize;
        extra.y_size = y_csize;
        extra.character_map = new_char_map;
        extra.highlight_map = new_hl_map;
        _ = c.XClearWindow(xw.xd.*.display, xw.window);
        xtermDumpContents(xw, 0, 0, x_csize, y_csize);
        xtermUpdateNormalHints(xw);
        _ = c.XFlush(xw.xd.*.display);
    }
    return 0;
}

pub export fn xterm_map_x_coordinate(xw: *c.struct_xwindow, signed_xp: c_int) callconv(.c) c_long {
    const xp: c_uint = if (signed_xp < 0) 0 else @intCast(signed_xp);
    const bx: c_int = @as(c_int, @intCast(xp)) - xw.attributes.internal_border_width;
    const clamped: c_int = if (bx < 0)
        0
    else if (bx >= @as(c_int, @intCast(xw.x_size)))
        @as(c_int, @intCast(xw.x_size)) - 1
    else
        bx;
    return @divTrunc(clamped, x11.fontWidth(xw.attributes.font.?));
}

pub export fn xterm_map_y_coordinate(xw: *c.struct_xwindow, signed_yp: c_int) callconv(.c) c_long {
    const yp: c_uint = if (signed_yp < 0) 0 else @intCast(signed_yp);
    const by: c_int = @as(c_int, @intCast(yp)) - xw.attributes.internal_border_width;
    const clamped: c_int = if (by < 0)
        0
    else if (by >= @as(c_int, @intCast(xw.y_size)))
        @as(c_int, @intCast(xw.y_size)) - 1
    else
        by;
    return @divTrunc(clamped, x11.fontHeight(xw.attributes.font.?));
}

pub export fn xterm_map_x_size(xw: *c.struct_xwindow, width: c_uint) callconv(.c) c_ulong {
    const w: c_int = @as(c_int, @intCast(width)) - 2 * xw.attributes.internal_border_width;
    return if (w < 0) 0 else @intCast(@divTrunc(w, x11.fontWidth(xw.attributes.font.?)));
}

pub export fn xterm_map_y_size(xw: *c.struct_xwindow, height: c_uint) callconv(.c) c_ulong {
    const h: c_int = @as(c_int, @intCast(height)) - 2 * xw.attributes.internal_border_width;
    return if (h < 0) 0 else @intCast(@divTrunc(h, x11.fontHeight(xw.attributes.font.?)));
}

pub export fn xterm_open_window(
    xd: *c.struct_xdisplay,
    geometry: [*c]u8,
    resource_name_in: [*c]const u8,
    resource_class_in: [*c]const u8,
    map_p: c_int,
) callconv(.c) ?*c.struct_xwindow {
    const display = xd.display;
    const resource_name = if (resource_name_in != null) resource_name_in else RESOURCE_NAME;
    const resource_class = if (resource_class_in != null) resource_class_in else RESOURCE_CLASS;

    var attributes: c.struct_drawing_attributes = undefined;
    if (base.x_default_attributes(display, resource_name, resource_class, &attributes) != 0) {
        return null;
    }

    var methods: c.struct_xwindow_methods = .{
        .deallocator = &xtermDeallocate,
        .event_processor = &xtermProcessEvent,
        .x_coordinate_map = &xtermXCoordinateMap,
        .y_coordinate_map = &xtermYCoordinateMap,
        .update_normal_hints = &xtermUpdateNormalHints,
    };

    const size_hints = xtermMakeSizeHints(
        attributes.font.?,
        @intCast(2 * attributes.internal_border_width),
    ) orelse return null;

    var x_pos: c_int = 0;
    var y_pos: c_int = 0;
    var x_size: c_int = 0;
    var y_size: c_int = 0;
    const geom_str: [*c]const u8 = if (geometry != null)
        geometry
    else
        base.x_get_default(display, resource_name, resource_class, "geometry", "Geometry", null);

    _ = c.XWMGeometry(
        display,
        x11.defaultScreen(display),
        geom_str,
        DEFAULT_GEOMETRY,
        @intCast(attributes.border_width),
        size_hints,
        &x_pos,
        &y_pos,
        &x_size,
        &y_size,
        &size_hints.*.win_gravity,
    );

    const x_csize: c_uint = @intCast(@divTrunc(x_size - size_hints.*.base_width, size_hints.*.width_inc));
    const y_csize: c_uint = @intCast(@divTrunc(y_size - size_hints.*.base_height, size_hints.*.height_inc));
    const map_size: usize = @as(usize, x_csize) * @as(usize, y_csize);

    const raw_char = std.c.malloc(map_size) orelse return null;
    const charmap: [*]u8 = @ptrCast(raw_char);
    const raw_hl = std.c.malloc(map_size) orelse {
        std.c.free(raw_char);
        return null;
    };
    const hlmap: [*]u8 = @ptrCast(raw_hl);

    const window = c.XCreateSimpleWindow(
        display,
        x11.rootWindow(display, x11.defaultScreen(display)),
        x_pos,
        y_pos,
        @intCast(x_size),
        @intCast(y_size),
        @intCast(attributes.border_width),
        attributes.border_pixel,
        attributes.background_pixel,
    );
    if (window == 0) {
        std.c.free(raw_char);
        std.c.free(raw_hl);
        return null;
    }

    const xw = base.x_make_window(
        xd,
        window,
        x_size - size_hints.*.base_width,
        y_size - size_hints.*.base_height,
        &attributes,
        &methods,
        @sizeOf(XWindowTerm),
    ) orelse {
        std.c.free(raw_char);
        std.c.free(raw_hl);
        return null;
    };

    const extra = xwExtra(xw);
    extra.x_size = x_csize;
    extra.y_size = y_csize;
    extra.cursor_x = 0;
    extra.cursor_y = 0;
    extra.cursor_visible_p = 0;
    extra.cursor_enabled_p = 1;

    @memset(charmap[0..map_size], BLANK_CHAR);
    extra.character_map = charmap;
    @memset(hlmap[0..map_size], DEFAULT_HL);
    extra.highlight_map = hlmap;

    size_hints.*.flags |= c.PWinGravity;
    xtermSetWmNormalHints(xw, size_hints);

    if (base.xw_set_wm_input_hint(xw, 1) != 0 or
        base.xw_set_wm_name(xw, "scheme-terminal") != 0 or
        base.xw_set_wm_icon_name(xw, "scheme-terminal") != 0 or
        base.xw_make_window_map(xw, resource_name, resource_class, map_p) != 0)
    {
        base.x_close_window(xw);
        return null;
    }
    return xw;
}

pub export fn xterm_x_size(xw: *c.struct_xwindow) callconv(.c) c_uint {
    return xwExtra(xw).x_size;
}

pub export fn xterm_y_size(xw: *c.struct_xwindow) callconv(.c) c_uint {
    return xwExtra(xw).y_size;
}

pub export fn xterm_set_size(xw: *c.struct_xwindow, width: c_uint, height: c_uint) callconv(.c) void {
    var extra: c_int = 2 * xw.attributes.internal_border_width;
    if (builtin.os.tag.isDarwin()) {
        extra += 1;
    }
    const font = xw.attributes.font.?;
    _ = c.XResizeWindow(
        xw.xd.*.display,
        xw.window,
        @intCast(@as(c_int, @intCast(width)) * x11.fontWidth(font) + extra),
        @intCast(@as(c_int, @intCast(height)) * x11.fontHeight(font) + extra),
    );
}

pub export fn xterm_enable_cursor(xw: *c.struct_xwindow, enable_p: c_int) callconv(.c) void {
    xwExtra(xw).cursor_enabled_p = @intCast(enable_p);
}

pub export fn xterm_write_cursor(xw: *c.struct_xwindow, x: c_uint, y: c_uint) callconv(.c) c_int {
    const extra = xwExtra(xw);
    if (x >= extra.x_size) return 1;
    if (y >= extra.y_size) return 2;
    if (x != extra.cursor_x or y != extra.cursor_y) {
        xterm_erase_cursor(xw);
        extra.cursor_x = x;
        extra.cursor_y = y;
    }
    xterm_draw_cursor(xw);
    return 0;
}

pub export fn xterm_write_char(
    xw: *c.struct_xwindow,
    x: c_uint,
    y: c_uint,
    ch: c_int,
    hl: c_uint,
) callconv(.c) c_int {
    const extra = xwExtra(xw);
    if (x >= extra.x_size) return 1;
    if (y >= extra.y_size) return 2;
    if (hl >= 2) return 3;
    const idx = charIndex(xw, x, y);
    const map_ptr = extra.character_map + idx;
    map_ptr.* = @truncate(@as(c_uint, @bitCast(ch)));
    extra.highlight_map[idx] = @truncate(hl);
    drawChars(xw, x, y, map_ptr, 1, hlGc(xw, hl));
    if (extra.cursor_x == x and extra.cursor_y == y) {
        extra.cursor_visible_p = 0;
        xterm_draw_cursor(xw);
    }
    return 0;
}

pub export fn xterm_write_substring(
    xw: *c.struct_xwindow,
    x: c_uint,
    y: c_uint,
    string: [*c]u8,
    start: c_uint,
    end: c_uint,
    hl: c_uint,
) callconv(.c) c_int {
    const extra = xwExtra(xw);
    if (x >= extra.x_size) return 1;
    if (y >= extra.y_size) return 2;
    if (start > end) return 3;
    if (hl >= 2) return 4;

    const length = end - start;
    if ((x + length) > extra.x_size) return 5;
    const idx = charIndex(xw, x, y);
    @memcpy(extra.character_map[idx .. idx + length], string[start..end]);
    @memset(extra.highlight_map[idx .. idx + length], @truncate(hl));
    drawChars(xw, x, y, extra.character_map + idx, length, hlGc(xw, hl));
    if (extra.cursor_x >= x and extra.cursor_x < (x + length) and extra.cursor_y == y) {
        extra.cursor_visible_p = 0;
        xterm_draw_cursor(xw);
    }
    return 0;
}

fn clearRectangle(
    xw: *c.struct_xwindow,
    x_start: c_uint,
    x_end: c_uint,
    y_start: c_uint,
    y_end: c_uint,
    hl: c_uint,
) void {
    const extra = xwExtra(xw);
    const x_length = x_end - x_start;
    var y = y_start;
    while (y < y_end) : (y += 1) {
        const idx = charIndex(xw, x_start, y);
        @memset(extra.character_map[idx .. idx + x_length], BLANK_CHAR);
        @memset(extra.highlight_map[idx .. idx + x_length], @truncate(hl));
    }
    if (hl != 0) {
        const hl_gc = hlGc(xw, hl);
        y = y_start;
        while (y < y_end) : (y += 1) {
            const idx = charIndex(xw, x_start, y);
            drawChars(xw, x_start, y, extra.character_map + idx, x_length, hl_gc);
        }
    } else if (x_start == 0 and y_start == 0 and x_end == extra.x_size and y_end == extra.y_size) {
        _ = c.XClearWindow(xw.xd.*.display, xw.window);
    } else {
        const font = xw.attributes.font.?;
        _ = c.XClearArea(
            xw.xd.*.display,
            xw.window,
            xtermXPixel(xw, x_start),
            xtermYPixel(xw, y_start),
            @intCast(@as(c_int, @intCast(x_length)) * x11.fontWidth(font)),
            @intCast(@as(c_int, @intCast(y_end - y_start)) * x11.fontHeight(font)),
            c.False,
        );
    }
}

pub export fn xterm_clear_rectangle(
    xw: *c.struct_xwindow,
    x_start: c_uint,
    x_end: c_uint,
    y_start: c_uint,
    y_end: c_uint,
    hl: c_uint,
) callconv(.c) c_int {
    const extra = xwExtra(xw);
    if (x_end > extra.x_size) return 1;
    if (y_end > extra.y_size) return 2;
    if (x_start > x_end) return 3;
    if (y_start > y_end) return 4;
    if (hl >= 2) return 5;
    if (x_start < x_end and y_start < y_end) {
        clearRectangle(xw, x_start, x_end, y_start, y_end, hl);
        if (cursorInRectangle(xw, x_start, x_end, y_start, y_end)) {
            extra.cursor_visible_p = 0;
            xterm_draw_cursor(xw);
        }
    }
    return 0;
}

fn scrollLinesUp(
    xw: *c.struct_xwindow,
    x_start: c_uint,
    x_end: c_uint,
    y_start: c_uint,
    y_end: c_uint,
    lines: c_uint,
) void {
    var y_to = y_start;
    var y_from = y_to + lines;
    while (y_from < y_end) : ({
        y_from += 1;
        y_to += 1;
    }) {
        xtermCopyMapLine(xw, x_start, x_end, y_from, y_to);
    }
    const font = xw.attributes.font.?;
    _ = c.XCopyArea(
        xw.xd.*.display,
        xw.window,
        xw.window,
        xw.normal_gc,
        xtermXPixel(xw, x_start),
        xtermYPixel(xw, y_start + lines),
        @intCast(@as(c_int, @intCast(x_end - x_start)) * x11.fontWidth(font)),
        @intCast(@as(c_int, @intCast((y_end - y_start) - lines)) * x11.fontHeight(font)),
        xtermXPixel(xw, x_start),
        xtermYPixel(xw, y_start),
    );
}

pub export fn xterm_scroll_lines_up(
    xw: *c.struct_xwindow,
    x_start: c_uint,
    x_end: c_uint,
    y_start: c_uint,
    y_end: c_uint,
    lines: c_uint,
) callconv(.c) c_int {
    const extra = xwExtra(xw);
    if (x_end > extra.x_size) return 1;
    if (y_end > extra.y_size) return 2;
    if (x_start > x_end) return 3;
    if (y_start > y_end) return 4;
    if (lines >= (y_end - y_start)) return 5;
    if (lines > 0 and x_start < x_end and y_start < y_end) {
        if (cursorInRectangle(xw, x_start, x_end, y_start + lines, y_end)) {
            xterm_erase_cursor(xw);
            scrollLinesUp(xw, x_start, x_end, y_start, y_end, lines);
            xterm_draw_cursor(xw);
        } else {
            scrollLinesUp(xw, x_start, x_end, y_start, y_end, lines);
            if (cursorInRectangle(xw, x_start, x_end, y_start, y_end - lines)) {
                extra.cursor_visible_p = 0;
                xterm_draw_cursor(xw);
            }
        }
    }
    return 0;
}

fn scrollLinesDown(
    xw: *c.struct_xwindow,
    x_start: c_uint,
    x_end: c_uint,
    y_start: c_uint,
    y_end: c_uint,
    lines: c_uint,
) void {
    var y_to = y_end;
    var y_from = y_to - lines;
    while (y_from > y_start) {
        y_from -= 1;
        y_to -= 1;
        xtermCopyMapLine(xw, x_start, x_end, y_from, y_to);
    }
    const font = xw.attributes.font.?;
    _ = c.XCopyArea(
        xw.xd.*.display,
        xw.window,
        xw.window,
        xw.normal_gc,
        xtermXPixel(xw, x_start),
        xtermYPixel(xw, y_start),
        @intCast(@as(c_int, @intCast(x_end - x_start)) * x11.fontWidth(font)),
        @intCast(@as(c_int, @intCast((y_end - y_start) - lines)) * x11.fontHeight(font)),
        xtermXPixel(xw, x_start),
        xtermYPixel(xw, y_start + lines),
    );
}

pub export fn xterm_scroll_lines_down(
    xw: *c.struct_xwindow,
    x_start: c_uint,
    x_end: c_uint,
    y_start: c_uint,
    y_end: c_uint,
    lines: c_uint,
) callconv(.c) c_int {
    const extra = xwExtra(xw);
    if (x_end > extra.x_size) return 1;
    if (y_end > extra.y_size) return 2;
    if (x_start > x_end) return 3;
    if (y_start > y_end) return 4;
    if (lines >= (y_end - y_start)) return 5;
    if (lines > 0 and x_start < x_end and y_start < y_end) {
        if (cursorInRectangle(xw, x_start, x_end, y_start, y_end - lines)) {
            xterm_erase_cursor(xw);
            scrollLinesDown(xw, x_start, x_end, y_start, y_end, lines);
            xterm_draw_cursor(xw);
        } else {
            scrollLinesDown(xw, x_start, x_end, y_start, y_end, lines);
            if (cursorInRectangle(xw, x_start, x_end, y_start + lines, y_end)) {
                extra.cursor_visible_p = 0;
                xterm_draw_cursor(xw);
            }
        }
    }
    return 0;
}

pub export fn xterm_save_contents(
    xw: *c.struct_xwindow,
    x_start: c_uint,
    x_end: c_uint,
    y_start: c_uint,
    y_end: c_uint,
    contents: [*c]u8,
) callconv(.c) c_int {
    const extra = xwExtra(xw);
    if (x_end > extra.x_size) return 1;
    if (y_end > extra.y_size) return 2;
    if (x_start > x_end) return 3;
    if (y_start > y_end) return 4;

    const x_length = x_end - x_start;
    var out_idx: usize = 0;
    var y = y_start;
    while (y < y_end) : (y += 1) {
        const idx = charIndex(xw, x_start, y);
        for (0..x_length) |dx| {
            contents[out_idx] = extra.character_map[idx + dx];
            contents[out_idx + 1] = extra.highlight_map[idx + dx];
            out_idx += 2;
        }
    }
    return 0;
}

pub export fn xterm_restore_contents(
    xw: *c.struct_xwindow,
    x_start: c_uint,
    x_end: c_uint,
    y_start: c_uint,
    y_end: c_uint,
    contents: [*c]u8,
) callconv(.c) c_int {
    const extra = xwExtra(xw);
    if (x_end > extra.x_size) return 1;
    if (y_end > extra.y_size) return 2;
    if (x_start > x_end) return 3;
    if (y_start > y_end) return 4;

    const x_length = x_end - x_start;
    const string_length = 2 * x_length * (y_end - y_start);
    if (string_length > 0) {
        var in_idx: usize = 0;
        var y = y_start;
        while (y < y_end) : (y += 1) {
            const idx = charIndex(xw, x_start, y);
            for (0..x_length) |dx| {
                extra.character_map[idx + dx] = contents[in_idx];
                extra.highlight_map[idx + dx] = contents[in_idx + 1];
                in_idx += 2;
            }
        }
        xtermDumpContents(xw, x_start, x_end, y_start, y_end);
    }
    return 0;
}
