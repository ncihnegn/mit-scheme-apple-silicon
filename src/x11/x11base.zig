// Derived from MIT/GNU Scheme C sources (`src/x11/x11base.c`):
// Copyright (C) 1986-2022 Massachusetts Institute of Technology
// Licensed under the GNU General Public License (GPL v2 or later); see src/COPYING.

const std = @import("std");
const x11 = @import("x11.zig");
const c = x11.c;

extern "c" fn block_signals() void;
extern "c" fn unblock_signals() void;

extern "c" fn scm_setjmp_try(
    env_slot: *?*anyopaque,
    body: *const fn (?*anyopaque) callconv(.c) void,
    ctx: ?*anyopaque,
) c_int;
extern "c" fn scm_longjmp(env: ?*anyopaque, code: c_int) callconv(.c) noreturn;

const X_DEFAULT_FONT: [*:0]const u8 = "fixed";

pub export var x_debug: c_int = 0;
var initialization_done: bool = false;
var x_default_font: ?[*:0]u8 = null;

// Allocation Tables

const AllocationTable = struct {
    items: ?[*]?*anyopaque = null,
    length: c_int = 0,
};

var x_display_table: AllocationTable = .{};
var x_window_table: AllocationTable = .{};
var x_image_table: AllocationTable = .{};
var x_visual_table: AllocationTable = .{};
var x_colormap_table: AllocationTable = .{};

fn allocationTableInitialize(table: *AllocationTable) void {
    table.length = 0;
}

fn allocateTableIndex(table: *AllocationTable, item: *anyopaque) c_uint {
    const length: usize = @intCast(table.length);
    var new_length: usize = 0;
    var new_items: [*]?*anyopaque = undefined;

    if (length == 0) {
        new_length = 4;
        const raw = std.c.malloc(@sizeOf(?*anyopaque) * new_length) orelse @panic("x11: out of memory");
        new_items = @ptrCast(@alignCast(raw));
    } else {
        const items = table.items.?;
        for (0..length) |i| {
            if (items[i] == null) {
                items[i] = item;
                return @intCast(i);
            }
        }
        new_length = length * 2;
        const raw = std.c.realloc(@ptrCast(items), @sizeOf(?*anyopaque) * new_length) orelse @panic("x11: out of memory");
        new_items = @ptrCast(@alignCast(raw));
    }

    new_items[length] = item;
    for ((length + 1)..new_length) |i| {
        new_items[i] = null;
    }
    table.items = new_items;
    table.length = @intCast(new_length);
    return @intCast(length);
}

fn xWindowToXw(display: ?*c.Display, window: c.Window) ?*c.struct_xwindow {
    const len: usize = @intCast(x_window_table.length);
    if (len == 0) return null;
    const items = x_window_table.items orelse return null;
    for (0..len) |i| {
        if (items[i]) |ptr| {
            const xw: *c.struct_xwindow = @ptrCast(@alignCast(ptr));
            if (xw.xd.*.display == display and xw.window == window) {
                return xw;
            }
        }
    }
    return null;
}

pub export fn allocate_x_image(image: ?*c.XImage) callconv(.c) ?*c.struct_ximage {
    const raw = std.c.malloc(@sizeOf(c.struct_ximage)) orelse return null;
    const xi: *c.struct_ximage = @ptrCast(@alignCast(raw));
    xi.allocation_index = allocateTableIndex(&x_image_table, xi);
    xi.image = image;
    return xi;
}

pub export fn deallocate_x_image(xi: *c.struct_ximage) callconv(.c) void {
    if (x_image_table.items) |items| {
        items[xi.allocation_index] = null;
    }
    std.c.free(xi);
}

pub export fn allocate_x_visual(visual: ?*c.Visual) callconv(.c) ?*c.struct_xvisual {
    const raw = std.c.malloc(@sizeOf(c.struct_xvisual)) orelse return null;
    const xv: *c.struct_xvisual = @ptrCast(@alignCast(raw));
    xv.allocation_index = allocateTableIndex(&x_visual_table, xv);
    xv.visual = visual;
    return xv;
}

pub export fn x_visual_deallocate(xv: *c.struct_xvisual) callconv(.c) void {
    if (x_visual_table.items) |items| {
        items[xv.allocation_index] = null;
    }
    std.c.free(xv);
}

pub export fn allocate_x_colormap(colormap: c.Colormap, xd: *c.struct_xdisplay) callconv(.c) ?*c.struct_xcolormap {
    const raw = std.c.malloc(@sizeOf(c.struct_xcolormap)) orelse return null;
    const xcm: *c.struct_xcolormap = @ptrCast(@alignCast(raw));
    xcm.allocation_index = allocateTableIndex(&x_colormap_table, xcm);
    xcm.colormap = colormap;
    xcm.xd = xd;
    return xcm;
}

pub export fn deallocate_x_colormap(xcm: *c.struct_xcolormap) callconv(.c) void {
    if (x_colormap_table.items) |items| {
        items[xcm.allocation_index] = null;
    }
    std.c.free(xcm);
}

// Error Handlers

fn xIoErrorHandler(display: ?*c.Display) callconv(.c) c_int {
    _ = display;
    std.debug.print("\nX IO Error\n", .{});
    return 0;
}

const XErrorInfo = struct {
    message: [2048]u8 = @splat(0),
    terminate_p: u8 = 0,
    code: u8 = 0,
};

var x_error_info: XErrorInfo = .{};

fn xErrorHandler(display: ?*c.Display, error_event: [*c]c.XErrorEvent) callconv(.c) c_int {
    x_error_info.code = error_event.*.error_code;
    _ = c.XGetErrorText(
        display,
        error_event.*.error_code,
        &x_error_info.message,
        @intCast(x_error_info.message.len),
    );
    if (x_error_info.terminate_p != 0) {
        const msg_ptr: [*:0]const u8 = @ptrCast(&x_error_info.message);
        std.debug.print("\nX Error: {s}\n", .{std.mem.span(msg_ptr)});
        std.debug.print("         Request code: {d}\n", .{error_event.*.request_code});
        std.debug.print("         Error serial: {x}\n", .{error_event.*.serial});
    }
    return 0;
}

fn xErrorCode(display: ?*c.Display) u8 {
    _ = c.XSync(display, c.False);
    return x_error_info.code;
}

fn anyXErrorsP(display: ?*c.Display) bool {
    return xErrorCode(display) != 0;
}

// Defaults and Attributes

fn xDecodeColor(
    display: ?*c.Display,
    color_map: c.Colormap,
    color_name: [*c]const u8,
    color_return: *c_ulong,
) bool {
    var cdef: c.XColor = std.mem.zeroes(c.XColor);
    if (c.XParseColor(display, color_map, color_name, &cdef) != 0 and
        c.XAllocColor(display, color_map, &cdef) != 0)
    {
        color_return.* = cdef.pixel;
        return true;
    }
    return false;
}

fn xwColormap(xw: *c.struct_xwindow, cm: *c.Colormap) bool {
    var a: c.XWindowAttributes = undefined;
    if (c.XGetWindowAttributes(xw.xd.*.display, xw.window, &a) == 0) {
        return false;
    }
    cm.* = a.colormap;
    return true;
}

fn colorPixel(
    color: [*c]const u8,
    display: ?*c.Display,
    xw: *c.struct_xwindow,
    result: *c_ulong,
) bool {
    var cm: c.Colormap = 0;
    if (!xwColormap(xw, &cm)) return false;
    return xDecodeColor(display, cm, color, result);
}

fn xSetMouseColors(
    display: ?*c.Display,
    color_map: c.Colormap,
    mouse_cursor: c.Cursor,
    mouse_pixel: c_ulong,
    background_pixel: c_ulong,
) void {
    var mouse_color: c.XColor = std.mem.zeroes(c.XColor);
    var background_color: c.XColor = std.mem.zeroes(c.XColor);
    mouse_color.pixel = mouse_pixel;
    _ = c.XQueryColor(display, color_map, &mouse_color);
    background_color.pixel = background_pixel;
    _ = c.XQueryColor(display, color_map, &background_color);
    _ = c.XRecolorCursor(display, mouse_cursor, &mouse_color, &background_color);
}

pub export fn x_get_default(
    display: ?*c.Display,
    resource_name: [*c]const u8,
    resource_class: [*c]const u8,
    property_name: [*c]const u8,
    property_class: [*c]const u8,
    sdefault: [*c]const u8,
) callconv(.c) [*c]const u8 {
    if (c.XGetDefault(display, resource_name, property_name)) |r| return r;
    if (c.XGetDefault(display, resource_class, property_name)) |r| return r;
    if (c.XGetDefault(display, resource_name, property_class)) |r| return r;
    if (c.XGetDefault(display, resource_class, property_class)) |r| return r;
    return sdefault;
}

fn xDefaultColor(
    display: ?*c.Display,
    resource_name: [*c]const u8,
    resource_class: [*c]const u8,
    property_name: [*c]const u8,
    property_class: [*c]const u8,
    default_color: c_ulong,
) c_ulong {
    const color_name = x_get_default(display, resource_name, resource_class, property_name, property_class, null);
    var result: c_ulong = 0;
    if (color_name != null and
        xDecodeColor(display, x11.defaultColormap(display, x11.defaultScreen(display)), color_name, &result))
    {
        return result;
    }
    return default_color;
}

pub export fn x_default_attributes(
    display: ?*c.Display,
    resource_name: [*c]const u8,
    resource_class: [*c]const u8,
    attributes: *c.struct_drawing_attributes,
) callconv(.c) c_int {
    const screen_number = x11.defaultScreen(display);
    const font_name: [*c]const u8 = if (x_default_font) |df|
        df
    else
        x_get_default(display, resource_name, resource_class, "font", "Font", X_DEFAULT_FONT);

    attributes.font = c.XLoadQueryFont(display, font_name);
    if (attributes.font == null) {
        return 1;
    }

    if (x_get_default(display, resource_name, resource_class, "borderWidth", "BorderWidth", null)) |s| {
        attributes.border_width = c.atoi(s);
    } else {
        attributes.border_width = 0;
    }

    if (x_get_default(display, resource_name, resource_class, "internalBorder", "BorderWidth", null)) |s| {
        attributes.internal_border_width = c.atoi(s);
    } else {
        attributes.internal_border_width = attributes.border_width;
    }

    const white_pixel = x11.whitePixel(display, screen_number);
    const black_pixel = x11.blackPixel(display, screen_number);
    attributes.background_pixel = xDefaultColor(display, resource_name, resource_class, "background", "Background", white_pixel);
    const foreground_pixel = xDefaultColor(display, resource_name, resource_class, "foreground", "Foreground", black_pixel);
    attributes.foreground_pixel = foreground_pixel;
    attributes.border_pixel = xDefaultColor(display, resource_name, resource_class, "borderColor", "BorderColor", foreground_pixel);
    attributes.cursor_pixel = xDefaultColor(display, resource_name, resource_class, "cursorColor", "Foreground", foreground_pixel);
    attributes.mouse_pixel = xDefaultColor(display, resource_name, resource_class, "pointerColor", "Foreground", foreground_pixel);
    return 0;
}

fn getWmDecorGeometry(xw: *c.struct_xwindow) c_int {
    const display = xw.xd.*.display;
    var decor = xw.window;
    var root: c.Window = 0;
    var depth: c_uint = 0;

    while (true) {
        var parent: c.Window = 0;
        var children: [*c]c.Window = null;
        var n_children: c_uint = 0;
        if (c.XQueryTree(display, decor, &root, &parent, &children, &n_children) == 0 or anyXErrorsP(display)) {
            std.debug.print("\nXQueryTree failed!\n", .{});
            return 0;
        }
        if (children != null) {
            _ = c.XFree(@ptrCast(children));
        }
        if (parent == root) break;
        decor = parent;
    }

    if (c.XGetGeometry(
        display,
        decor,
        &root,
        &xw.wm_decor_x,
        &xw.wm_decor_y,
        &xw.wm_decor_pixel_width,
        &xw.wm_decor_pixel_height,
        &xw.wm_decor_border_width,
        &depth,
    ) == 0 or anyXErrorsP(display)) {
        std.debug.print("\nXGetGeometry failed!\n", .{});
        return 0;
    }
    return if (decor != xw.window) 1 else 0;
}

// Open/Close Windows

fn makeGc(display: ?*c.Display, window: c.Window, fid: c.Font, fore: c_ulong, back: c_ulong) c.GC {
    var gcv: c.XGCValues = std.mem.zeroes(c.XGCValues);
    gcv.font = fid;
    gcv.foreground = fore;
    gcv.background = back;
    return c.XCreateGC(display, window, c.GCFont | c.GCForeground | c.GCBackground, &gcv);
}

pub export fn x_make_window(
    xd: *c.struct_xdisplay,
    window: c.Window,
    x_size: c_int,
    y_size: c_int,
    attributes: *c.struct_drawing_attributes,
    methods: *c.struct_xwindow_methods,
    size: c_uint,
) callconv(.c) ?*c.struct_xwindow {
    const display = xd.display;
    const fid = attributes.font.*.fid;
    const foreground_pixel = attributes.foreground_pixel;
    const background_pixel = attributes.background_pixel;
    const mouse_cursor = c.XCreateFontCursor(display, c.XC_left_ptr);
    const normal_gc = makeGc(display, window, fid, foreground_pixel, background_pixel);
    const reverse_gc = makeGc(display, window, fid, background_pixel, foreground_pixel);
    const cursor_gc = makeGc(display, window, fid, background_pixel, attributes.cursor_pixel);
    xSetMouseColors(
        display,
        x11.defaultColormap(display, x11.defaultScreen(display)),
        mouse_cursor,
        attributes.mouse_pixel,
        background_pixel,
    );
    _ = c.XDefineCursor(display, window, mouse_cursor);
    _ = c.XSelectInput(display, window, 0);

    if (size < @sizeOf(c.struct_xwindow)) {
        return null;
    }
    const raw = std.c.malloc(size) orelse return null;
    const xw: *c.struct_xwindow = @ptrCast(@alignCast(raw));
    xw.* = std.mem.zeroes(c.struct_xwindow);
    xw.allocation_index = allocateTableIndex(&x_window_table, xw);
    xw.xd = xd;
    xw.window = window;
    xw.x_size = @intCast(x_size);
    xw.y_size = @intCast(y_size);
    xw.clip_x = 0;
    xw.clip_y = 0;
    xw.clip_width = @intCast(x_size);
    xw.clip_height = @intCast(y_size);
    xw.attributes = attributes.*;
    xw.methods = methods.*;
    xw.normal_gc = normal_gc;
    xw.reverse_gc = reverse_gc;
    xw.cursor_gc = cursor_gc;
    xw.mouse_cursor = mouse_cursor;
    xw.event_mask = 0;
    xw.check_expected_move_p = 0;
    xw.move_offset_x = 0;
    xw.move_offset_y = 0;
    return xw;
}

var x_close_window_jmp_buf: ?*anyopaque = null;

fn xCloseWindowIoError(display: ?*c.Display) callconv(.c) c_int {
    _ = display;
    scm_longjmp(x_close_window_jmp_buf, 1);
}

fn closeWindowBody(ctx: ?*anyopaque) callconv(.c) void {
    const xw: *c.struct_xwindow = @ptrCast(@alignCast(ctx.?));
    const display = xw.xd.*.display;
    _ = c.XSetIOErrorHandler(&xCloseWindowIoError);
    if (xw.methods.deallocator) |deallocator| {
        deallocator(xw);
    }
    if (xw.attributes.font) |font| {
        _ = c.XFreeFont(display, font);
    }
    _ = c.XDestroyWindow(display, xw.window);
    // Guarantee that the IO error occurs while the IO error handler is rebound, if at all.
    _ = c.XFlush(display);
}

pub export fn x_close_window_internal(xw: *c.struct_xwindow) callconv(.c) void {
    if (x_window_table.items) |items| {
        items[xw.allocation_index] = null;
    }
    _ = scm_setjmp_try(&x_close_window_jmp_buf, &closeWindowBody, xw);
    _ = c.XSetIOErrorHandler(&xIoErrorHandler);
    std.c.free(xw);
}

// Initialize/Close Displays

fn xInitializeDisplayModifierMasks(xd: *c.struct_xdisplay) void {
    var min_keycode: c_int = 0;
    var max_keycode: c_int = 0;
    var keysyms_per_keycode: c_int = 0;

    xd.modifier_mask_meta = 0;
    xd.modifier_mask_super = 0;
    xd.modifier_mask_hyper = 0;

    const modifier_keymap = c.XGetModifierMapping(xd.display).?;
    const modifier_to_keycodes_table = modifier_keymap.*.modifiermap;
    const keycodes_per_modifier: usize = @intCast(modifier_keymap.*.max_keypermod);

    _ = c.XDisplayKeycodes(xd.display, &min_keycode, &max_keycode);
    const keycode_to_keysyms_table = c.XGetKeyboardMapping(
        xd.display,
        @intCast(min_keycode),
        max_keycode - min_keycode + 1,
        &keysyms_per_keycode,
    );

    const ksym_stride: usize = @intCast(keysyms_per_keycode);
    next_modifier: for (3..8) |modifier_index| {
        const modifier_mask: c_int = @as(c_int, 1) << @intCast(modifier_index);
        const keycodes = modifier_to_keycodes_table + modifier_index * keycodes_per_modifier;
        var modifier_is_meta_p = false;

        for (0..keycodes_per_modifier) |keycode_index| {
            const keycode = keycodes[keycode_index];
            if (keycode == 0) continue;

            const offset: usize = @intCast((@as(c_int, keycode) - min_keycode) * @as(c_int, @intCast(ksym_stride)));
            const keysyms = keycode_to_keysyms_table + offset;

            for (0..ksym_stride) |keysym_index| {
                switch (keysyms[keysym_index]) {
                    c.XK_Meta_L, c.XK_Meta_R, c.XK_Alt_L, c.XK_Alt_R => {
                        modifier_is_meta_p = true;
                        xd.modifier_mask_meta |= modifier_mask;
                    },
                    c.XK_Hyper_L, c.XK_Hyper_R => {
                        if (!modifier_is_meta_p) {
                            xd.modifier_mask_hyper |= modifier_mask;
                        }
                        continue :next_modifier;
                    },
                    c.XK_Super_L, c.XK_Super_R => {
                        if (!modifier_is_meta_p) {
                            xd.modifier_mask_super |= modifier_mask;
                        }
                        continue :next_modifier;
                    },
                    else => {},
                }
            }
        }
    }

    _ = c.XFree(@ptrCast(keycode_to_keysyms_table));
    _ = c.XFreeModifiermap(modifier_keymap);
}

pub export fn x_close_display(xd: *c.struct_xdisplay) callconv(.c) void {
    const len: usize = @intCast(x_window_table.length);
    if (len > 0) {
        if (x_window_table.items) |items| {
            for (0..len) |i| {
                if (items[i]) |ptr| {
                    const xw: *c.struct_xwindow = @ptrCast(@alignCast(ptr));
                    if (xw.xd == xd) {
                        x_close_window_internal(xw);
                    }
                }
            }
        }
    }
    if (x_display_table.items) |items| {
        items[xd.allocation_index] = null;
    }
    _ = c.XCloseDisplay(xd.display);
}

pub export fn x_close_all_displays() callconv(.c) void {
    const len: usize = @intCast(x_display_table.length);
    if (len == 0) return;
    const items = x_display_table.items orelse return;
    for (0..len) |i| {
        if (items[i]) |ptr| {
            const xd: *c.struct_xdisplay = @ptrCast(@alignCast(ptr));
            x_close_display(xd);
        }
    }
}

// Window Manager Properties

fn xwSetClassHint(xw: *c.struct_xwindow, name: [*c]const u8, class_name: [*c]const u8) c_int {
    const class_hint = c.XAllocClassHint() orelse return 1;
    class_hint.*.res_name = @constCast(name);
    class_hint.*.res_class = @constCast(class_name);
    _ = c.XSetClassHint(xw.xd.*.display, xw.window, class_hint);
    _ = c.XFree(@ptrCast(class_hint));
    return 0;
}

pub export fn xw_set_wm_input_hint(xw: *c.struct_xwindow, input_hint: c_int) callconv(.c) c_int {
    const hints = c.XAllocWMHints() orelse return 1;
    hints.*.flags = c.InputHint;
    hints.*.input = if (input_hint != 0) 1 else 0;
    _ = c.XSetWMHints(xw.xd.*.display, xw.window, hints);
    _ = c.XFree(@ptrCast(hints));
    return 0;
}

pub export fn xw_set_wm_name(xw: *c.struct_xwindow, name: [*c]const u8) callconv(.c) c_int {
    var property: c.XTextProperty = undefined;
    var name_mut: [*c]u8 = @constCast(name);
    if (c.XStringListToTextProperty(&name_mut, 1, &property) == 0) return 1;
    c.XSetWMName(xw.xd.*.display, xw.window, &property);
    return 0;
}

pub export fn xw_set_wm_icon_name(xw: *c.struct_xwindow, name: [*c]const u8) callconv(.c) c_int {
    var property: c.XTextProperty = undefined;
    var name_mut: [*c]u8 = @constCast(name);
    if (c.XStringListToTextProperty(&name_mut, 1, &property) == 0) return 1;
    c.XSetWMIconName(xw.xd.*.display, xw.window, &property);
    return 0;
}

pub export fn x_window_set_input_hint(xw: *c.struct_xwindow, input_hint: c_int) callconv(.c) c_int {
    return xw_set_wm_input_hint(xw, input_hint);
}

pub export fn x_window_set_name(xw: *c.struct_xwindow, name: [*c]const u8) callconv(.c) c_int {
    return xw_set_wm_name(xw, name);
}

pub export fn x_window_set_icon_name(xw: *c.struct_xwindow, name: [*c]const u8) callconv(.c) c_int {
    return xw_set_wm_icon_name(xw, name);
}

pub export fn xw_make_window_map(
    xw: *c.struct_xwindow,
    resource_name: [*c]const u8,
    resource_class: [*c]const u8,
    map_p: c_int,
) callconv(.c) c_int {
    const code = xwSetClassHint(xw, resource_name, resource_class);
    if (code != 0) return code;
    if (map_p != 0) {
        const dpy = xw.xd.*.display;
        _ = c.XMapWindow(dpy, xw.window);
        _ = c.XFlush(dpy);
    }
    return 0;
}

// Event Processing

inline fn eventEnabled(xw: *const c.struct_xwindow, comptime event_type: c_uint) bool {
    return (xw.event_mask & (@as(c_ulong, 1) << @intCast(event_type))) != 0;
}

fn xwProcessEvent(xw: ?*c.struct_xwindow, event: *c.XEvent) c_int {
    var ignore_p: c_int = 0;

    if (x_debug > 0) {
        std.debug.print("\nX event on 0x{x}: ", .{event.xany.window});
        var type_name: ?[]const u8 = null;
        var debug_done = false;
        switch (event.type) {
            c.ButtonPress => type_name = "ButtonPress",
            c.ButtonRelease => type_name = "ButtonRelease",
            c.CirculateNotify => type_name = "CirculateNotify",
            c.CreateNotify => type_name = "CreateNotify",
            c.DestroyNotify => type_name = "DestroyNotify",
            c.EnterNotify => type_name = "EnterNotify",
            c.Expose => type_name = "Expose",
            c.FocusIn => type_name = "FocusIn",
            c.FocusOut => type_name = "FocusOut",
            c.GraphicsExpose => type_name = "GraphicsExpose",
            c.GravityNotify => type_name = "GravityNotify",
            c.KeyPress => type_name = "KeyPress",
            c.KeyRelease => type_name = "KeyRelease",
            c.LeaveNotify => type_name = "LeaveNotify",
            c.MapNotify => type_name = "MapNotify",
            c.MappingNotify => type_name = "MappingNotify",
            c.MotionNotify => type_name = "MotionNotify",
            c.NoExpose => type_name = "NoExpose",
            c.ReparentNotify => type_name = "ReparentNotify",
            c.SelectionClear => type_name = "SelectionClear",
            c.SelectionRequest => type_name = "SelectionRequest",
            c.UnmapNotify => type_name = "UnmapNotify",
            c.VisibilityNotify => {
                std.debug.print("VisibilityNotify; state=", .{});
                switch (event.xvisibility.state) {
                    c.VisibilityUnobscured => std.debug.print("unobscured", .{}),
                    c.VisibilityPartiallyObscured => std.debug.print("partially-obscured", .{}),
                    c.VisibilityFullyObscured => std.debug.print("fully-obscured", .{}),
                    else => std.debug.print("{d}", .{event.xvisibility.state}),
                }
                debug_done = true;
            },
            c.ConfigureNotify => {
                std.debug.print("ConfigureNotify; x={d} y={d} width={d} height={d}", .{
                    event.xconfigure.x,
                    event.xconfigure.y,
                    event.xconfigure.width,
                    event.xconfigure.height,
                });
                debug_done = true;
            },
            c.ClientMessage => {
                const xd = xw.?.xd;
                if (event.xclient.message_type == xd.*.wm_protocols and event.xclient.format == 32) {
                    const atom0: c.Atom = @bitCast(event.xclient.data.l[0]);
                    if (atom0 == xd.*.wm_delete_window) {
                        type_name = "WM_DELETE_WINDOW";
                    } else if (atom0 == xd.*.wm_take_focus) {
                        type_name = "WM_TAKE_FOCUS";
                    } else {
                        type_name = "WM_PROTOCOLS";
                    }
                } else {
                    std.debug.print("ClientMessage; message_type=0x{x} format={d}", .{
                        @as(c_uint, @truncate(event.xclient.message_type)),
                        event.xclient.format,
                    });
                    debug_done = true;
                }
            },
            c.PropertyNotify => {
                std.debug.print("PropertyNotify; atom={d} time={d} state={d}", .{
                    event.xproperty.atom,
                    event.xproperty.time,
                    event.xproperty.state,
                });
                debug_done = true;
            },
            c.SelectionNotify => {
                std.debug.print("SelectionNotify; sel={d} targ={d} prop={d} t={d}", .{
                    event.xselection.selection,
                    event.xselection.target,
                    event.xselection.property,
                    event.xselection.time,
                });
                debug_done = true;
            },
            else => {},
        }
        if (!debug_done) {
            if (type_name) |tn| {
                std.debug.print("{s}", .{tn});
            } else {
                std.debug.print("{d}", .{event.type});
            }
        }
        const synth = if (event.xany.send_event != 0) "; synthetic" else "";
        std.debug.print("{s}\n", .{synth});
    }

    if (event.type == c.MappingNotify) {
        switch (event.xmapping.request) {
            c.MappingModifier => {
                xInitializeDisplayModifierMasks(xw.?.xd.?);
                _ = c.XRefreshKeyboardMapping(&event.xmapping);
            },
            c.MappingKeyboard => {
                _ = c.XRefreshKeyboardMapping(&event.xmapping);
            },
            else => {},
        }
    }

    if (xw) |w| {
        switch (event.type) {
            c.ReparentNotify => {
                _ = getWmDecorGeometry(w);
                w.xd.*.wm_type = c.X_WMTYPE_UNKNOWN;
                ignore_p = 1;
            },
            c.ConfigureNotify => {
                if (w.check_expected_move_p != 0 and
                    !(getWmDecorGeometry(w) != 0 and event.xconfigure.send_event == 0))
                {
                    checkExpectedMove(w);
                }
            },
            c.ClientMessage => {
                const xd = w.xd;
                if (event.xclient.message_type == xd.*.wm_protocols and event.xclient.format == 32) {
                    const atom0: c.Atom = @bitCast(event.xclient.data.l[0]);
                    if (atom0 == xd.*.wm_delete_window) {
                        if (!eventEnabled(w, c.event_type_delete_window)) {
                            ignore_p = 1;
                        }
                    } else if (atom0 == xd.*.wm_take_focus) {
                        if (!eventEnabled(w, c.event_type_take_focus)) {
                            ignore_p = 1;
                        }
                    }
                }
            },
            else => {},
        }
        if (w.methods.event_processor) |proc| {
            proc(w, event);
        }
    }
    return ignore_p;
}

pub export fn x_event_delete_window_p(xw: *c.struct_xwindow, event: *c.XEvent) callconv(.c) c_int {
    const xd = xw.xd;
    const atom0: c.Atom = @bitCast(event.xclient.data.l[0]);
    return if (event.xclient.message_type == xd.*.wm_protocols and
        event.xclient.format == 32 and
        atom0 == xd.*.wm_delete_window) 1 else 0;
}

pub export fn x_event_take_focus_p(xw: *c.struct_xwindow, event: *c.XEvent) callconv(.c) c_int {
    const xd = xw.xd;
    const atom0: c.Atom = @bitCast(event.xclient.data.l[0]);
    return if (event.xclient.message_type == xd.*.wm_protocols and
        event.xclient.format == 32 and
        atom0 == xd.*.wm_take_focus) 1 else 0;
}

pub export fn x_event_take_focus_time(event: *c.XEvent) callconv(.c) c.Time {
    return @bitCast(event.xclient.data.l[1]);
}

// Modifier masks matching MIT/GNU Scheme microcode characters
const CHAR_BITS_META: c_ulong = 0x1;
const CHAR_BITS_CONTROL: c_ulong = 0x2;
const CHAR_BITS_SUPER: c_ulong = 0x4;
const CHAR_BITS_HYPER: c_ulong = 0x8;

pub export fn x_modifier_mask_to_bucky_bits(mask: c_uint, xw: *c.struct_xwindow) callconv(.c) c_ulong {
    const xd = xw.xd;
    var bucky: c_ulong = 0;
    if ((mask & @as(c_uint, @bitCast(c.ControlMask))) != 0) bucky |= CHAR_BITS_CONTROL;
    if ((mask & @as(c_uint, @bitCast(xd.*.modifier_mask_meta))) != 0) bucky |= CHAR_BITS_META;
    if ((mask & @as(c_uint, @bitCast(xd.*.modifier_mask_super))) != 0) bucky |= CHAR_BITS_SUPER;
    if ((mask & @as(c_uint, @bitCast(xd.*.modifier_mask_hyper))) != 0) bucky |= CHAR_BITS_HYPER;
    return bucky;
}

var compose_status: c.XComposeStatus = std.mem.zeroes(c.XComposeStatus);

pub export fn x_lookup_string(
    event: [*c]c.XKeyEvent,
    buffer_return: [*c]u8,
    bytes_buffer: c_int,
    keysym_return: [*c]c.KeySym,
) callconv(.c) c_int {
    return c.XLookupString(event, buffer_return, bytes_buffer, keysym_return, &compose_status);
}

fn updateInputMask(xw: *c.struct_xwindow) void {
    const dpy = xw.xd.*.display;
    var event_mask: c_long = 0;
    if (eventEnabled(xw, c.event_type_expose)) event_mask |= c.ExposureMask;
    if (eventEnabled(xw, c.event_type_configure) or
        eventEnabled(xw, c.event_type_map) or
        eventEnabled(xw, c.event_type_unmap))
    {
        event_mask |= c.StructureNotifyMask;
    }
    if (eventEnabled(xw, c.event_type_button_down)) event_mask |= c.ButtonPressMask;
    if (eventEnabled(xw, c.event_type_button_up)) event_mask |= c.ButtonReleaseMask;
    if (eventEnabled(xw, c.event_type_key_press)) event_mask |= c.KeyPressMask;
    if (eventEnabled(xw, c.event_type_enter)) event_mask |= c.EnterWindowMask;
    if (eventEnabled(xw, c.event_type_leave)) event_mask |= c.LeaveWindowMask;
    if (eventEnabled(xw, c.event_type_focus_in) or eventEnabled(xw, c.event_type_focus_out)) {
        event_mask |= c.FocusChangeMask;
    }
    if (eventEnabled(xw, c.event_type_motion)) {
        event_mask |= c.PointerMotionMask | c.PointerMotionHintMask;
    }
    if (eventEnabled(xw, c.event_type_visibility)) event_mask |= c.VisibilityChangeMask;
    if (eventEnabled(xw, c.event_type_property_notify)) event_mask |= c.PropertyChangeMask;
    _ = c.XSelectInput(dpy, xw.window, event_mask);

    const xd = xw.xd;
    var protocols: [2]c.Atom = undefined;
    var n_protocols: usize = 0;
    if (eventEnabled(xw, c.event_type_delete_window)) {
        protocols[n_protocols] = xd.*.wm_delete_window;
        n_protocols += 1;
    }
    if (eventEnabled(xw, c.event_type_take_focus)) {
        protocols[n_protocols] = xd.*.wm_take_focus;
        n_protocols += 1;
    }
    if (n_protocols > 0) {
        _ = c.XSetWMProtocols(dpy, xw.window, &protocols, @intCast(n_protocols));
    }
}

fn pingServer(xd: *c.struct_xdisplay) void {
    xd.server_ping_timer += 1;
    if (xd.server_ping_timer >= 100) {
        xd.server_ping_timer = 0;
        _ = c.XNoOp(xd.display);
        _ = c.XFlush(xd.display);
    }
}

fn xdProcessEvents(
    xd: *c.struct_xdisplay,
    result: *c.XEvent,
    xw_ret: *?*c.struct_xwindow,
) c_int {
    const display = xd.display;
    var event: c.XEvent = undefined;
    var xw: ?*c.struct_xwindow = null;
    var done_p: c_int = 1;

    if (x_debug > 1) {
        std.debug.print("Enter xd_process_events\n", .{});
    }
    pingServer(xd);
    var events_queued = c.XEventsQueued(display, c.QueuedAfterReading);
    while (events_queued > 0) {
        events_queued -= 1;
        _ = c.XNextEvent(display, &event);
        if (event.type == c.KeymapNotify) continue;
        xw = xWindowToXw(display, event.xany.window);
        if (xw == null and !(event.type == c.PropertyNotify or
            event.type == c.SelectionClear or
            event.type == c.SelectionNotify or
            event.type == c.SelectionRequest))
        {
            continue;
        }
        if (xwProcessEvent(xw, &event) != 0) continue;
        result.* = event;
        xw_ret.* = xw;
        done_p = 0;
        break;
    }
    if (x_debug > 1) {
        std.debug.print("Return from xd_process_events: {d} 0x{x}\n", .{ done_p, @intFromPtr(xw) });
    }
    return done_p;
}

// Open/Close Primitives

fn initializeOnce() void {
    allocationTableInitialize(&x_display_table);
    allocationTableInitialize(&x_window_table);
    allocationTableInitialize(&x_image_table);
    x_error_info.message[0] = 0;
    x_error_info.terminate_p = 1;
    x_error_info.code = 0;
    _ = c.XSetErrorHandler(&xErrorHandler);
    _ = c.XSetIOErrorHandler(&xIoErrorHandler);
    initialization_done = true;
}

pub export fn x_set_debug(value: c_int) callconv(.c) void {
    x_debug = value;
}

pub export fn x_open_display(display_name: [*c]u8) callconv(.c) ?*c.struct_xdisplay {
    if (!initialization_done) initializeOnce();

    const raw = std.c.malloc(@sizeOf(c.struct_xdisplay)) orelse return null;
    const xd: *c.struct_xdisplay = @ptrCast(@alignCast(raw));
    xd.* = std.mem.zeroes(c.struct_xdisplay);

    // Avoid interrupt during potentially slow XOpenDisplay over network.
    block_signals();
    xd.display = c.XOpenDisplay(display_name);
    unblock_signals();
    if (xd.display == null) {
        std.c.free(xd);
        return null;
    }
    xd.allocation_index = allocateTableIndex(&x_display_table, xd);
    xd.server_ping_timer = 0;
    xd.wm_protocols = c.XInternAtom(xd.display, "WM_PROTOCOLS", c.False);
    xd.wm_delete_window = c.XInternAtom(xd.display, "WM_DELETE_WINDOW", c.False);
    xd.wm_take_focus = c.XInternAtom(xd.display, "WM_TAKE_FOCUS", c.False);
    xInitializeDisplayModifierMasks(xd);
    _ = c.XRebindKeysym(xd.display, c.XK_BackSpace, null, 0, @constCast("\x7f"), 1);
    return xd;
}

pub export fn x_display_get_size(xd: *c.struct_xdisplay, screen: c_long, results: [*c]c_int) callconv(.c) void {
    const display = xd.display;
    const scr: c_int = @intCast(screen);
    results[0] = x11.displayWidth(display, scr);
    results[1] = x11.displayHeight(display, scr);
}

pub export fn x_close_window(xw: *c.struct_xwindow) callconv(.c) void {
    const display = xw.xd.*.display;
    x_close_window_internal(xw);
    _ = c.XFlush(display);
}

pub export fn x_set_default_font(xd: *c.struct_xdisplay, name: [*c]const u8) callconv(.c) c_int {
    const display = xd.display;
    const font = c.XLoadQueryFont(display, name) orelse return 1;
    _ = c.XFreeFont(display, font);
    if (x_default_font) |prev| {
        std.c.free(prev);
    }
    const len = std.mem.len(@as([*:0]const u8, @ptrCast(name)));
    const raw = std.c.malloc(len + 1) orelse return 1;
    const copy: [*]u8 = @ptrCast(raw);
    @memcpy(copy[0 .. len + 1], @as([*]const u8, @ptrCast(name))[0 .. len + 1]);
    x_default_font = @ptrCast(copy);
    return 0;
}

// Event Processing Primitives

pub export fn x_display_descriptor(xd: *c.struct_xdisplay) callconv(.c) c_int {
    return x11.connectionNumber(xd.display);
}

pub export fn x_max_request_size(xd: *c.struct_xdisplay) callconv(.c) c_long {
    return c.XMaxRequestSize(xd.display);
}

pub export fn x_display_process_events(
    xd: *c.struct_xdisplay,
    event: *c.XEvent,
    xw_ret: *?*c.struct_xwindow,
) callconv(.c) c_int {
    return xdProcessEvents(xd, event, xw_ret);
}

pub export fn x_select_input(xd: *c.struct_xdisplay, window: c.Window, mask: c_long) callconv(.c) void {
    _ = c.XSelectInput(xd.display, window, mask);
}

pub export fn x_window_event_mask(xw: *c.struct_xwindow) callconv(.c) c_long {
    return @bitCast(xw.event_mask);
}

pub export fn x_window_set_event_mask(xw: *c.struct_xwindow, mask: c_long) callconv(.c) c_int {
    const max_mask: c_long = @as(c_long, 1) << @intCast(c.event_type_supremum);
    if (mask >= max_mask) return 0;
    xw.event_mask = @bitCast(mask);
    updateInputMask(xw);
    return 1;
}

pub export fn x_window_or_event_mask(xw: *c.struct_xwindow, mask: c_long) callconv(.c) void {
    xw.event_mask |= @as(c_ulong, @bitCast(mask));
    updateInputMask(xw);
}

pub export fn x_window_andc_event_mask(xw: *c.struct_xwindow, mask: c_long) callconv(.c) void {
    xw.event_mask &= ~@as(c_ulong, @bitCast(mask));
    updateInputMask(xw);
}

// Miscellaneous Primitives

pub export fn x_window_display(xw: *c.struct_xwindow) callconv(.c) ?*c.struct_xdisplay {
    return xw.xd;
}

pub export fn x_window_screen_number(xw: *c.struct_xwindow) callconv(.c) c_long {
    var attrs: c.XWindowAttributes = undefined;
    _ = c.XGetWindowAttributes(xw.xd.*.display, xw.window, &attrs);
    return c.XScreenNumberOfScreen(attrs.screen);
}

pub export fn x_window_x_size(xw: *c.struct_xwindow) callconv(.c) c_int {
    return @intCast(xw.x_size);
}

pub export fn x_window_y_size(xw: *c.struct_xwindow) callconv(.c) c_int {
    return @intCast(xw.y_size);
}

pub export fn x_window_beep(xw: *c.struct_xwindow) callconv(.c) void {
    _ = c.XBell(xw.xd.*.display, 0);
}

pub export fn x_window_clear(xw: *c.struct_xwindow) callconv(.c) void {
    const dpy = xw.xd.*.display;
    if (xw.clip_x == 0 and xw.clip_y == 0 and
        xw.clip_width == xw.x_size and xw.clip_height == xw.y_size)
    {
        _ = c.XClearWindow(dpy, xw.window);
    } else {
        const ibw: c_uint = @intCast(xw.attributes.internal_border_width);
        _ = c.XClearArea(
            dpy,
            xw.window,
            @intCast(xw.clip_x + ibw),
            @intCast(xw.clip_y + ibw),
            xw.clip_width,
            xw.clip_height,
            c.False,
        );
    }
}

pub export fn x_display_flush(xd: *c.struct_xdisplay) callconv(.c) void {
    _ = c.XFlush(xd.display);
}

pub export fn x_window_flush(xw: *c.struct_xwindow) callconv(.c) void {
    _ = c.XFlush(xw.xd.*.display);
}

pub export fn x_display_sync(xd: *c.struct_xdisplay, discard: c.Bool) callconv(.c) void {
    _ = c.XSync(xd.display, discard);
}

pub export fn x_display_get_default(
    xd: *c.struct_xdisplay,
    resource_name: [*c]u8,
    class_name: [*c]u8,
) callconv(.c) [*c]u8 {
    return c.XGetDefault(xd.display, resource_name, class_name);
}

pub export fn x_window_query_pointer(xw: *c.struct_xwindow, result: [*c]c_int) callconv(.c) c_int {
    var root: c.Window = 0;
    var child: c.Window = 0;
    var root_x: c_int = 0;
    var root_y: c_int = 0;
    var win_x: c_int = 0;
    var win_y: c_int = 0;
    var keys_buttons: c_uint = 0;
    if (c.XQueryPointer(
        xw.xd.*.display,
        xw.window,
        &root,
        &child,
        &root_x,
        &root_y,
        &win_x,
        &win_y,
        &keys_buttons,
    ) == 0) {
        return 0;
    }
    result[0] = root_x;
    result[1] = root_y;
    result[2] = win_x;
    result[3] = win_y;
    result[4] = @bitCast(keys_buttons);
    return 1;
}

pub export fn x_window_id(xw: *c.struct_xwindow) callconv(.c) c_ulong {
    return xw.window;
}

// Appearance Control Functions

pub export fn x_window_set_foreground_color_pixel(xw: *c.struct_xwindow, pixel: c_ulong) callconv(.c) void {
    const display = xw.xd.*.display;
    xw.attributes.foreground_pixel = pixel;
    _ = c.XSetForeground(display, xw.normal_gc, pixel);
    _ = c.XSetBackground(display, xw.reverse_gc, pixel);
}

pub export fn x_window_set_foreground_color_name(xw: *c.struct_xwindow, color: [*c]u8) callconv(.c) void {
    var pixel: c_ulong = 0;
    if (!colorPixel(color, xw.xd.*.display, xw, &pixel)) return;
    x_window_set_foreground_color_pixel(xw, pixel);
}

pub export fn x_window_set_background_color_pixel(xw: *c.struct_xwindow, pixel: c_ulong) callconv(.c) c_int {
    const display = xw.xd.*.display;
    var cm: c.Colormap = 0;
    if (!xwColormap(xw, &cm)) return 0;
    xw.attributes.background_pixel = pixel;
    _ = c.XSetWindowBackground(display, xw.window, pixel);
    _ = c.XSetBackground(display, xw.normal_gc, pixel);
    _ = c.XSetForeground(display, xw.reverse_gc, pixel);
    _ = c.XSetForeground(display, xw.cursor_gc, pixel);
    xSetMouseColors(display, cm, xw.mouse_cursor, xw.attributes.mouse_pixel, pixel);
    return 1;
}

pub export fn x_window_set_background_color_name(xw: *c.struct_xwindow, color: [*c]u8) callconv(.c) void {
    var pixel: c_ulong = 0;
    if (!colorPixel(color, xw.xd.*.display, xw, &pixel)) return;
    _ = x_window_set_background_color_pixel(xw, pixel);
}

pub export fn x_window_set_border_color_pixel(xw: *c.struct_xwindow, pixel: c_ulong) callconv(.c) void {
    xw.attributes.border_pixel = pixel;
    _ = c.XSetWindowBorder(xw.xd.*.display, xw.window, pixel);
}

pub export fn x_window_set_border_color_name(xw: *c.struct_xwindow, color: [*c]u8) callconv(.c) void {
    var pixel: c_ulong = 0;
    if (!colorPixel(color, xw.xd.*.display, xw, &pixel)) return;
    x_window_set_border_color_pixel(xw, pixel);
}

pub export fn x_window_set_cursor_color_pixel(xw: *c.struct_xwindow, pixel: c_ulong) callconv(.c) void {
    xw.attributes.cursor_pixel = pixel;
    _ = c.XSetBackground(xw.xd.*.display, xw.cursor_gc, pixel);
}

pub export fn x_window_set_cursor_color_name(xw: *c.struct_xwindow, color: [*c]u8) callconv(.c) void {
    var pixel: c_ulong = 0;
    if (!colorPixel(color, xw.xd.*.display, xw, &pixel)) return;
    x_window_set_cursor_color_pixel(xw, pixel);
}

pub export fn x_window_set_mouse_color_pixel(xw: *c.struct_xwindow, pixel: c_ulong) callconv(.c) c_int {
    const display = xw.xd.*.display;
    var cm: c.Colormap = 0;
    if (!xwColormap(xw, &cm)) return 0;
    xw.attributes.mouse_pixel = pixel;
    xSetMouseColors(display, cm, xw.mouse_cursor, pixel, xw.attributes.background_pixel);
    return 1;
}

pub export fn x_window_set_mouse_color_name(xw: *c.struct_xwindow, color: [*c]u8) callconv(.c) void {
    var pixel: c_ulong = 0;
    if (!colorPixel(color, xw.xd.*.display, xw, &pixel)) return;
    _ = x_window_set_mouse_color_pixel(xw, pixel);
}

pub export fn x_window_set_mouse_shape(xw: *c.struct_xwindow, shape: c_int) callconv(.c) c_int {
    const display = xw.xd.*.display;
    var cm: c.Colormap = 0;
    if (shape < 0 or shape >= @divTrunc(c.XC_num_glyphs, 2)) return 0;
    if (!xwColormap(xw, &cm)) return 0;
    const old_cursor = xw.mouse_cursor;
    const mouse_cursor = c.XCreateFontCursor(display, @intCast(2 * shape));
    xSetMouseColors(display, cm, mouse_cursor, xw.attributes.mouse_pixel, xw.attributes.background_pixel);
    xw.mouse_cursor = mouse_cursor;
    _ = c.XDefineCursor(display, xw.window, mouse_cursor);
    _ = c.XFreeCursor(display, old_cursor);
    return 1;
}

pub export fn x_window_set_font(xw: *c.struct_xwindow, font_name: [*c]u8) callconv(.c) c_int {
    const display = xw.xd.*.display;
    const font = c.XLoadQueryFont(display, font_name) orelse return 0;
    _ = c.XFreeFont(display, xw.attributes.font);
    xw.attributes.font = font;
    const fid = font.*.fid;
    _ = c.XSetFont(display, xw.normal_gc, fid);
    _ = c.XSetFont(display, xw.reverse_gc, fid);
    _ = c.XSetFont(display, xw.cursor_gc, fid);
    if (xw.methods.update_normal_hints) |update| {
        update(xw);
    }
    return 1;
}

pub export fn x_window_set_border_width(xw: *c.struct_xwindow, border_width: c_uint) callconv(.c) void {
    xw.attributes.border_width = @intCast(border_width);
    _ = c.XSetWindowBorderWidth(xw.xd.*.display, xw.window, border_width);
}

pub export fn x_window_set_internal_border_width(xw: *c.struct_xwindow, internal_border_width: c_uint) callconv(.c) void {
    xw.attributes.internal_border_width = @intCast(internal_border_width);
    if (xw.methods.update_normal_hints) |update| {
        update(xw);
    }
    _ = c.XResizeWindow(
        xw.xd.*.display,
        xw.window,
        xw.x_size + 2 * internal_border_width,
        xw.y_size + 2 * internal_border_width,
    );
}

// WM Communication Primitives

pub export fn x_window_set_input_focus(xw: *c.struct_xwindow, time: c.Time) callconv(.c) c_int {
    const display = xw.xd.*.display;
    _ = c.XSetInputFocus(display, xw.window, c.RevertToParent, time);
    return if (anyXErrorsP(display)) 1 else 0;
}

// WM Control Primitives

pub export fn x_window_map(xw: *c.struct_xwindow) callconv(.c) void {
    _ = c.XMapWindow(xw.xd.*.display, xw.window);
}

pub export fn x_window_iconify(xw: *c.struct_xwindow) callconv(.c) void {
    const display = xw.xd.*.display;
    _ = c.XIconifyWindow(display, xw.window, x11.defaultScreen(display));
}

pub export fn x_window_withdraw(xw: *c.struct_xwindow) callconv(.c) void {
    const display = xw.xd.*.display;
    _ = c.XWithdrawWindow(display, xw.window, x11.defaultScreen(display));
}

pub export fn x_window_set_size(xw: *c.struct_xwindow, width: c_int, height: c_int) callconv(.c) void {
    const extra: c_int = 2 * xw.attributes.internal_border_width;
    _ = c.XResizeWindow(xw.xd.*.display, xw.window, @intCast(width + extra), @intCast(height + extra));
}

pub export fn x_window_raise(xw: *c.struct_xwindow) callconv(.c) void {
    _ = c.XRaiseWindow(xw.xd.*.display, xw.window);
}

pub export fn x_window_lower(xw: *c.struct_xwindow) callconv(.c) void {
    _ = c.XLowerWindow(xw.xd.*.display, xw.window);
}

pub export fn x_window_get_size(xw: *c.struct_xwindow, dimens: [*c]c_int) callconv(.c) void {
    _ = getWmDecorGeometry(xw);
    const extra = 2 * xw.wm_decor_border_width;
    dimens[0] = @intCast(xw.wm_decor_pixel_width + extra);
    dimens[1] = @intCast(xw.wm_decor_pixel_height + extra);
}

pub export fn x_window_get_position(xw: *c.struct_xwindow, coord_return: [*c]c_int) callconv(.c) void {
    _ = getWmDecorGeometry(xw);
    coord_return[0] = xw.wm_decor_x;
    coord_return[1] = xw.wm_decor_y;
}

pub export fn x_window_set_position(xw: *c.struct_xwindow, x_in: c_int, y_in: c_int) callconv(.c) void {
    if (xw.methods.update_normal_hints) |update| {
        update(xw);
    }
    var x = x_in;
    var y = y_in;
    const xd = xw.xd;
    if (xd.*.wm_type == c.X_WMTYPE_A) {
        x += xw.move_offset_x;
        y += xw.move_offset_y;
    }
    _ = c.XMoveWindow(xd.*.display, xw.window, x, y);
    if (xd.*.wm_type == c.X_WMTYPE_UNKNOWN) {
        xw.expected_x = x;
        xw.expected_y = y;
        xw.check_expected_move_p = 1;
    }
}

fn checkExpectedMove(xw: *c.struct_xwindow) void {
    const xd = xw.xd;
    if (xw.wm_decor_x == xw.expected_x and xw.wm_decor_y == xw.expected_y) {
        if (xd.*.wm_type == c.X_WMTYPE_UNKNOWN) {
            xd.*.wm_type = c.X_WMTYPE_B;
        }
    } else {
        xd.*.wm_type = c.X_WMTYPE_A;
        xw.move_offset_x = xw.expected_x - xw.wm_decor_x;
        xw.move_offset_y = xw.expected_y - xw.wm_decor_y;
        x_window_set_position(xw, xw.expected_x, xw.expected_y);
    }
    xw.check_expected_move_p = 0;
}

// Font Structure Primitives

pub export fn x_font_structure_by_name(xd: *c.struct_xdisplay, font_name: [*c]const u8) callconv(.c) ?*c.XFontStruct {
    return c.XLoadQueryFont(xd.display, font_name);
}

pub export fn x_font_structure_by_id(xd: *c.struct_xdisplay, id: c.XID) callconv(.c) ?*c.XFontStruct {
    return c.XQueryFont(xd.display, id);
}

pub export fn x_free_font(xd: *c.struct_xdisplay, font: ?*c.XFontStruct) callconv(.c) void {
    _ = c.XFreeFont(xd.display, font);
}

pub export fn x_list_fonts(
    xd: *c.struct_xdisplay,
    pattern: [*c]u8,
    limit: c_long,
    actual_count: [*c]c_int,
) callconv(.c) [*c][*c]u8 {
    return c.XListFonts(xd.display, pattern, @intCast(limit), actual_count);
}

// Atoms

pub export fn x_intern_atom(xd: *c.struct_xdisplay, name: [*c]const u8, soft_p: c_int) callconv(.c) c.Atom {
    return c.XInternAtom(xd.display, name, soft_p);
}

pub export fn x_get_atom_name(xd: *c.struct_xdisplay, atom: c.Atom, name_return: [*c][*c]u8) callconv(.c) c_int {
    const display = xd.display;
    name_return.* = c.XGetAtomName(display, atom);
    return xErrorCode(display);
}

// Window Properties

pub export fn x_get_window_property(
    xd: *c.struct_xdisplay,
    window: c.Window,
    property: c.Atom,
    long_offset: c_long,
    long_length: c_long,
    del: c.Bool,
    req_type: c.Atom,
    actual_type_return: [*c]c.Atom,
    actual_format_return: [*c]c_int,
    nitems_return: [*c]c_ulong,
    bytes_after_return: [*c]c_ulong,
    prop_return: [*c][*c]u8,
) callconv(.c) c_int {
    const display = xd.display;
    var actual_format: c_int = 0;

    if (c.XGetWindowProperty(
        display,
        window,
        property,
        long_offset,
        long_length,
        del,
        req_type,
        actual_type_return,
        &actual_format,
        nitems_return,
        bytes_after_return,
        prop_return,
    ) != c.Success) {
        return 1;
    }
    actual_format_return.* = actual_format;
    if (actual_format == 0) {
        _ = c.XFree(@ptrCast(prop_return.*));
        prop_return.* = null;
        return 2;
    }
    if (!(actual_format == 8 or actual_format == 16 or actual_format == 32)) {
        return 3;
    }
    return 0;
}

pub export fn x_change_property(
    xd: *c.struct_xdisplay,
    window: c.Window,
    property: c.Atom,
    prop_type: c.Atom,
    format: c_int,
    mode: c_int,
    data: [*c]u8,
    dlen: c_ulong,
) callconv(.c) c_int {
    const display = xd.display;
    if (mode >= 3) return 0;
    _ = c.XChangeProperty(display, window, property, prop_type, format, mode, data, @intCast(dlen));
    return xErrorCode(display);
}

pub export fn x_delete_property(xd: *c.struct_xdisplay, window: c.Window, property: c.Atom) callconv(.c) void {
    _ = c.XDeleteProperty(xd.display, window, property);
}

// Selections

pub export fn x_set_selection_owner(
    xd: *c.struct_xdisplay,
    selection: c.Atom,
    owner: c.Window,
    time: c.Time,
) callconv(.c) void {
    _ = c.XSetSelectionOwner(xd.display, selection, owner, time);
}

pub export fn x_get_selection_owner(xd: *c.struct_xdisplay, selection: c.Atom) callconv(.c) c.Window {
    return c.XGetSelectionOwner(xd.display, selection);
}

pub export fn x_convert_selection(
    xd: *c.struct_xdisplay,
    selection: c.Atom,
    target: c.Atom,
    property: c.Atom,
    requestor: c.Window,
    time: c.Time,
) callconv(.c) void {
    _ = c.XConvertSelection(xd.display, selection, target, property, requestor, time);
}

pub export fn x_send_selection_notify(
    xd: *c.struct_xdisplay,
    requestor: c.Window,
    selection: c.Atom,
    target: c.Atom,
    property: c.Atom,
    time: c.Time,
) callconv(.c) void {
    const display = xd.display;
    var event: c.XEvent = std.mem.zeroes(c.XEvent);
    event.xselection.type = c.SelectionNotify;
    event.xselection.display = display;
    event.xselection.requestor = requestor;
    event.xselection.selection = selection;
    event.xselection.target = target;
    event.xselection.property = property;
    event.xselection.time = time;
    _ = c.XSendEvent(display, requestor, c.False, 0, &event);
}
