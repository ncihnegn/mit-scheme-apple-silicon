const std = @import("std");
const c = @import("x11_c");
const x11 = @import("x11");

var mock_display_storage: usize = 0;
var mock_visual: c.Visual = .{
    .ext_data = null,
    .visualid = 0x21,
    .c_class = 4,
    .red_mask = 0xff0000,
    .green_mask = 0x00ff00,
    .blue_mask = 0x0000ff,
    .bits_per_rgb = 8,
    .map_entries = 256,
};
var mock_screen: c.Screen = .{
    .ext_data = null,
    .display = null,
    .root = 0x100,
    .width = 1024,
    .height = 768,
    .mwidth = 300,
    .mheight = 200,
    .ndepths = 1,
    .depths = null,
    .root_depth = 24,
    .root_visual = &mock_visual,
    .default_gc = null,
    .cmap = 0x200,
    .white_pixel = 0xffffff,
    .black_pixel = 0x000000,
    .max_maps = 1,
    .min_maps = 1,
    .backing_store = c.Always,
    .save_unders = c.False,
    .root_input_mask = 0,
};

var mock_io_handler: c.XIOErrorHandler = null;
var mock_err_handler: c.XErrorHandler = null;
var mock_trigger_io_error_on_destroy: bool = false;
var mock_next_window: c.Window = 0x1000;
var mock_next_atom: c.Atom = 0x50;
var mock_last_foreground: c_ulong = 0;
var mock_drawn_string: [64]u8 = @splat(0);
var mock_drawn_string_len: usize = 0;

pub export fn block_signals() callconv(.c) void {}
pub export fn unblock_signals() callconv(.c) void {}

fn dummyDisplay() ?*c.Display {
    return @ptrCast(&mock_display_storage);
}

pub export fn XOpenDisplay(_: [*c]const u8) callconv(.c) ?*c.Display {
    const dpy = dummyDisplay();
    mock_screen.display = dpy;
    return dpy;
}

pub export fn XCloseDisplay(_: ?*c.Display) callconv(.c) c_int {
    return 0;
}

pub export fn XDefaultScreen(_: ?*c.Display) callconv(.c) c_int {
    return 0;
}

pub export fn XRootWindow(_: ?*c.Display, _: c_int) callconv(.c) c.Window {
    return mock_screen.root;
}

pub export fn XDefaultColormap(_: ?*c.Display, _: c_int) callconv(.c) c.Colormap {
    return mock_screen.cmap;
}

pub export fn XWhitePixel(_: ?*c.Display, _: c_int) callconv(.c) c_ulong {
    return mock_screen.white_pixel;
}

pub export fn XBlackPixel(_: ?*c.Display, _: c_int) callconv(.c) c_ulong {
    return mock_screen.black_pixel;
}

pub export fn XDisplayWidth(_: ?*c.Display, _: c_int) callconv(.c) c_int {
    return mock_screen.width;
}

pub export fn XDisplayHeight(_: ?*c.Display, _: c_int) callconv(.c) c_int {
    return mock_screen.height;
}

pub export fn XConnectionNumber(_: ?*c.Display) callconv(.c) c_int {
    return 7;
}

pub export fn XDefaultVisualOfScreen(scr: ?*c.Screen) callconv(.c) ?*c.Visual {
    return scr.?.root_visual;
}

pub export fn XMaxRequestSize(_: ?*c.Display) callconv(.c) c_long {
    return 65535;
}

pub export fn XScreenNumberOfScreen(_: ?*c.Screen) callconv(.c) c_int {
    return 0;
}

pub export fn XFree(ptr: ?*anyopaque) callconv(.c) c_int {
    if (ptr) |p| std.c.free(p);
    return 1;
}

pub export fn XSync(_: ?*c.Display, _: c.Bool) callconv(.c) c_int {
    return 1;
}

pub export fn XFlush(_: ?*c.Display) callconv(.c) c_int {
    return 1;
}

pub export fn XNoOp(_: ?*c.Display) callconv(.c) c_int {
    return 1;
}

pub export fn XSetErrorHandler(h: c.XErrorHandler) callconv(.c) c.XErrorHandler {
    const prev = mock_err_handler;
    mock_err_handler = h;
    return prev;
}

pub export fn XSetIOErrorHandler(h: c.XIOErrorHandler) callconv(.c) c.XIOErrorHandler {
    const prev = mock_io_handler;
    mock_io_handler = h;
    return prev;
}

pub export fn XGetErrorText(_: ?*c.Display, _: c_int, buf: [*c]u8, len: c_int) callconv(.c) c_int {
    if (len > 0) buf[0] = 0;
    return 0;
}

pub export fn XGetDefault(_: ?*c.Display, _: [*c]const u8, _: [*c]const u8) callconv(.c) [*c]u8 {
    return null;
}

pub export fn XLoadQueryFont(_: ?*c.Display, _: [*c]const u8) callconv(.c) ?*c.XFontStruct {
    const raw = std.c.malloc(@sizeOf(c.XFontStruct)).?;
    const f: *c.XFontStruct = @ptrCast(@alignCast(raw));
    f.* = std.mem.zeroes(c.XFontStruct);
    f.fid = 0x77;
    f.max_bounds.width = 8;
    f.ascent = 10;
    f.descent = 3;
    return f;
}

pub export fn XQueryFont(dpy: ?*c.Display, _: c.XID) callconv(.c) ?*c.XFontStruct {
    return XLoadQueryFont(dpy, "fixed");
}

pub export fn XFreeFont(_: ?*c.Display, font: ?*c.XFontStruct) callconv(.c) c_int {
    if (font) |f| std.c.free(f);
    return 1;
}

pub export fn XListFonts(_: ?*c.Display, _: [*c]const u8, _: c_int, actual_count: [*c]c_int) callconv(.c) [*c][*c]u8 {
    actual_count.* = 0;
    return null;
}

pub export fn XParseColor(_: ?*c.Display, _: c.Colormap, _: [*c]const u8, exact: *c.XColor) callconv(.c) c.Status {
    exact.red = 0x1000;
    exact.green = 0x2000;
    exact.blue = 0x3000;
    return 1;
}

pub export fn XAllocColor(_: ?*c.Display, _: c.Colormap, col: *c.XColor) callconv(.c) c.Status {
    col.pixel = (@as(c_ulong, col.red >> 8) << 16) | (@as(c_ulong, col.green >> 8) << 8) | @as(c_ulong, col.blue >> 8);
    return 1;
}

pub export fn XQueryColor(_: ?*c.Display, _: c.Colormap, col: *c.XColor) callconv(.c) c_int {
    col.red = @intCast(((col.pixel >> 16) & 0xff) << 8);
    col.green = @intCast(((col.pixel >> 8) & 0xff) << 8);
    col.blue = @intCast((col.pixel & 0xff) << 8);
    return 1;
}

pub export fn XStoreColor(_: ?*c.Display, _: c.Colormap, _: *c.XColor) callconv(.c) c_int {
    return 1;
}

pub export fn XStoreColors(_: ?*c.Display, _: c.Colormap, _: [*c]c.XColor, _: c_int) callconv(.c) c_int {
    return 1;
}

pub export fn XCreateColormap(_: ?*c.Display, _: c.Window, _: ?*c.Visual, _: c_int) callconv(.c) c.Colormap {
    return 0x201;
}

pub export fn XFreeColormap(_: ?*c.Display, _: c.Colormap) callconv(.c) c_int {
    return 1;
}

pub export fn XSetWindowColormap(_: ?*c.Display, _: c.Window, _: c.Colormap) callconv(.c) c_int {
    return 1;
}

pub export fn XGetWindowAttributes(_: ?*c.Display, _: c.Window, attrs: *c.XWindowAttributes) callconv(.c) c.Status {
    attrs.* = std.mem.zeroes(c.XWindowAttributes);
    attrs.depth = 24;
    attrs.visual = &mock_visual;
    attrs.colormap = mock_screen.cmap;
    attrs.screen = &mock_screen;
    return 1;
}

pub export fn XQueryTree(
    _: ?*c.Display,
    _: c.Window,
    root: *c.Window,
    parent: *c.Window,
    children: *[*c]c.Window,
    nchildren: *c_uint,
) callconv(.c) c.Status {
    root.* = mock_screen.root;
    parent.* = mock_screen.root;
    children.* = null;
    nchildren.* = 0;
    return 1;
}

pub export fn XGetGeometry(
    _: ?*c.Display,
    _: c.Drawable,
    root: *c.Window,
    x: *c_int,
    y: *c_int,
    w: *c_uint,
    h: *c_uint,
    bw: *c_uint,
    depth: *c_uint,
) callconv(.c) c.Status {
    root.* = mock_screen.root;
    x.* = 0;
    y.* = 0;
    w.* = 512;
    h.* = 384;
    bw.* = 0;
    depth.* = 24;
    return 1;
}

pub export fn XCreateGC(_: ?*c.Display, _: c.Drawable, _: c_ulong, _: *c.XGCValues) callconv(.c) c.GC {
    return @ptrFromInt(0x88);
}

pub export fn XCreateFontCursor(_: ?*c.Display, _: c_uint) callconv(.c) c.Cursor {
    return 0x99;
}

pub export fn XFreeCursor(_: ?*c.Display, _: c.Cursor) callconv(.c) c_int {
    return 1;
}

pub export fn XRecolorCursor(_: ?*c.Display, _: c.Cursor, _: *c.XColor, _: *c.XColor) callconv(.c) c_int {
    return 1;
}

pub export fn XDefineCursor(_: ?*c.Display, _: c.Window, _: c.Cursor) callconv(.c) c_int {
    return 1;
}

pub export fn XSelectInput(_: ?*c.Display, _: c.Window, _: c_long) callconv(.c) c_int {
    return 1;
}

pub export fn XGetModifierMapping(_: ?*c.Display) callconv(.c) ?*c.XModifierKeymap {
    const m: *c.XModifierKeymap = @ptrCast(@alignCast(std.c.malloc(@sizeOf(c.XModifierKeymap)).?));
    const map: [*]c.KeyCode = @ptrCast(std.c.malloc(8 * 1).?);
    @memset(map[0..8], 0);
    map[3] = 10; // Mod1 -> keycode 10
    map[4] = 11; // Mod2 -> keycode 11
    m.max_keypermod = 1;
    m.modifiermap = map;
    return m;
}

pub export fn XFreeModifiermap(m: ?*c.XModifierKeymap) callconv(.c) c_int {
    if (m) |km| {
        if (km.modifiermap != null) std.c.free(km.modifiermap);
        std.c.free(km);
    }
    return 1;
}

pub export fn XDisplayKeycodes(_: ?*c.Display, min_k: *c_int, max_k: *c_int) callconv(.c) c_int {
    min_k.* = 8;
    max_k.* = 15;
    return 1;
}

pub export fn XGetKeyboardMapping(_: ?*c.Display, _: c.KeyCode, count: c_int, ksym_per: *c_int) callconv(.c) [*c]c.KeySym {
    ksym_per.* = 1;
    const n: usize = @intCast(count);
    const tbl: [*]c.KeySym = @ptrCast(@alignCast(std.c.malloc(n * @sizeOf(c.KeySym)).?));
    @memset(tbl[0..n], 0);
    tbl[10 - 8] = c.XK_Meta_L;
    tbl[11 - 8] = c.XK_Super_L;
    return tbl;
}

pub export fn XRebindKeysym(_: ?*c.Display, _: c.KeySym, _: [*c]c.KeySym, _: c_int, _: [*c]u8, _: c_int) callconv(.c) c_int {
    return 0;
}

pub export fn XInternAtom(_: ?*c.Display, _: [*c]const u8, _: c.Bool) callconv(.c) c.Atom {
    mock_next_atom += 1;
    return mock_next_atom;
}

pub export fn XGetAtomName(_: ?*c.Display, _: c.Atom) callconv(.c) [*c]u8 {
    return null;
}

pub export fn XGetWindowProperty(
    _: ?*c.Display,
    _: c.Window,
    _: c.Atom,
    _: c_long,
    _: c_long,
    _: c.Bool,
    _: c.Atom,
    _: [*c]c.Atom,
    actual_fmt: [*c]c_int,
    _: [*c]c_ulong,
    _: [*c]c_ulong,
    prop_ret: [*c][*c]u8,
) callconv(.c) c_int {
    actual_fmt.* = 0;
    prop_ret.* = null;
    return c.Success;
}

pub export fn XChangeProperty(_: ?*c.Display, _: c.Window, _: c.Atom, _: c.Atom, _: c_int, _: c_int, _: [*c]const u8, _: c_int) callconv(.c) c_int {
    return 1;
}

pub export fn XDeleteProperty(_: ?*c.Display, _: c.Window, _: c.Atom) callconv(.c) c_int {
    return 1;
}

pub export fn XSetSelectionOwner(_: ?*c.Display, _: c.Atom, _: c.Window, _: c.Time) callconv(.c) c_int {
    return 1;
}

pub export fn XGetSelectionOwner(_: ?*c.Display, _: c.Atom) callconv(.c) c.Window {
    return c.None;
}

pub export fn XConvertSelection(_: ?*c.Display, _: c.Atom, _: c.Atom, _: c.Atom, _: c.Window, _: c.Time) callconv(.c) c_int {
    return 1;
}

pub export fn XSendEvent(_: ?*c.Display, _: c.Window, _: c.Bool, _: c_long, _: *c.XEvent) callconv(.c) c.Status {
    return 1;
}

pub export fn XNextEvent(_: ?*c.Display, ev: *c.XEvent) callconv(.c) c_int {
    ev.* = std.mem.zeroes(c.XEvent);
    return 0;
}

pub export fn XEventsQueued(_: ?*c.Display, _: c_int) callconv(.c) c_int {
    return 0;
}

pub export fn XRefreshKeyboardMapping(_: [*c]c.XMappingEvent) callconv(.c) c_int {
    return 0;
}

pub export fn XSetForeground(_: ?*c.Display, _: c.GC, px: c_ulong) callconv(.c) c_int {
    mock_last_foreground = px;
    return 1;
}

pub export fn XSetBackground(_: ?*c.Display, _: c.GC, _: c_ulong) callconv(.c) c_int {
    return 1;
}

pub export fn XSetFont(_: ?*c.Display, _: c.GC, _: c.Font) callconv(.c) c_int {
    return 1;
}

pub export fn XSetFunction(_: ?*c.Display, _: c.GC, _: c_int) callconv(.c) c_int {
    return 1;
}

pub export fn XSetFillStyle(_: ?*c.Display, _: c.GC, _: c_int) callconv(.c) c_int {
    return 1;
}

pub export fn XSetLineAttributes(_: ?*c.Display, _: c.GC, _: c_uint, _: c_int, _: c_int, _: c_int) callconv(.c) c_int {
    return 1;
}

pub export fn XSetDashes(_: ?*c.Display, _: c.GC, _: c_int, _: [*c]const u8, _: c_int) callconv(.c) c_int {
    return 1;
}

pub export fn XSetClipRectangles(_: ?*c.Display, _: c.GC, _: c_int, _: c_int, _: [*c]c.XRectangle, _: c_int, _: c_int) callconv(.c) c_int {
    return 1;
}

pub export fn XSetWindowBackground(_: ?*c.Display, _: c.Window, _: c_ulong) callconv(.c) c_int {
    return 1;
}

pub export fn XSetWindowBorder(_: ?*c.Display, _: c.Window, _: c_ulong) callconv(.c) c_int {
    return 1;
}

pub export fn XSetWindowBorderWidth(_: ?*c.Display, _: c.Window, _: c_uint) callconv(.c) c_int {
    return 1;
}

pub export fn XSetInputFocus(_: ?*c.Display, _: c.Window, _: c_int, _: c.Time) callconv(.c) c_int {
    return 1;
}

pub export fn XMapWindow(_: ?*c.Display, _: c.Window) callconv(.c) c_int {
    return 1;
}

pub export fn XIconifyWindow(_: ?*c.Display, _: c.Window, _: c_int) callconv(.c) c.Status {
    return 1;
}

pub export fn XWithdrawWindow(_: ?*c.Display, _: c.Window, _: c_int) callconv(.c) c.Status {
    return 1;
}

pub export fn XResizeWindow(_: ?*c.Display, _: c.Window, _: c_uint, _: c_uint) callconv(.c) c_int {
    return 1;
}

pub export fn XRaiseWindow(_: ?*c.Display, _: c.Window) callconv(.c) c_int {
    return 1;
}

pub export fn XLowerWindow(_: ?*c.Display, _: c.Window) callconv(.c) c_int {
    return 1;
}

pub export fn XMoveWindow(_: ?*c.Display, _: c.Window, _: c_int, _: c_int) callconv(.c) c_int {
    return 1;
}

pub export fn XClearWindow(_: ?*c.Display, _: c.Window) callconv(.c) c_int {
    return 1;
}

pub export fn XClearArea(_: ?*c.Display, _: c.Window, _: c_int, _: c_int, _: c_uint, _: c_uint, _: c.Bool) callconv(.c) c_int {
    return 1;
}

pub export fn XCreateWindow(
    _: ?*c.Display,
    _: c.Window,
    _: c_int,
    _: c_int,
    _: c_uint,
    _: c_uint,
    _: c_uint,
    _: c_int,
    _: c_uint,
    _: ?*c.Visual,
    _: c_ulong,
    _: *c.XSetWindowAttributes,
) callconv(.c) c.Window {
    mock_next_window += 1;
    return mock_next_window;
}

pub export fn XCreateSimpleWindow(
    _: ?*c.Display,
    _: c.Window,
    _: c_int,
    _: c_int,
    _: c_uint,
    _: c_uint,
    _: c_uint,
    _: c_ulong,
    _: c_ulong,
) callconv(.c) c.Window {
    mock_next_window += 1;
    return mock_next_window;
}

pub export fn XDestroyWindow(dpy: ?*c.Display, _: c.Window) callconv(.c) c_int {
    if (mock_trigger_io_error_on_destroy) {
        if (mock_io_handler) |handler| {
            _ = handler(dpy);
        }
    }
    return 1;
}

pub export fn XBell(_: ?*c.Display, _: c_int) callconv(.c) c_int {
    return 1;
}

pub export fn XQueryPointer(
    _: ?*c.Display,
    _: c.Window,
    root: *c.Window,
    child: *c.Window,
    rx: *c_int,
    ry: *c_int,
    wx: *c_int,
    wy: *c_int,
    mask: *c_uint,
) callconv(.c) c.Bool {
    root.* = mock_screen.root;
    child.* = c.None;
    rx.* = 10;
    ry.* = 20;
    wx.* = 5;
    wy.* = 6;
    mask.* = 0;
    return c.True;
}

pub export fn XGeometry(
    _: ?*c.Display,
    _: c_int,
    _: [*c]const u8,
    _: [*c]const u8,
    _: c_uint,
    _: c_uint,
    _: c_uint,
    _: c_int,
    _: c_int,
    x: *c_int,
    y: *c_int,
    w: *c_int,
    h: *c_int,
) callconv(.c) c_int {
    x.* = 0;
    y.* = 0;
    w.* = 100;
    h.* = 50;
    return 0;
}

pub export fn XDrawLine(_: ?*c.Display, _: c.Drawable, _: c.GC, _: c_int, _: c_int, _: c_int, _: c_int) callconv(.c) c_int {
    return 1;
}

pub export fn XDrawPoint(_: ?*c.Display, _: c.Drawable, _: c.GC, _: c_int, _: c_int) callconv(.c) c_int {
    return 1;
}

pub export fn XDrawArc(_: ?*c.Display, _: c.Drawable, _: c.GC, _: c_int, _: c_int, _: c_uint, _: c_uint, _: c_int, _: c_int) callconv(.c) c_int {
    return 1;
}

pub export fn XFillArc(_: ?*c.Display, _: c.Drawable, _: c.GC, _: c_int, _: c_int, _: c_uint, _: c_uint, _: c_int, _: c_int) callconv(.c) c_int {
    return 1;
}

pub export fn XDrawString(_: ?*c.Display, _: c.Drawable, _: c.GC, _: c_int, _: c_int, _: [*c]const u8, _: c_int) callconv(.c) c_int {
    return 1;
}

pub export fn XDrawImageString(
    _: ?*c.Display,
    _: c.Drawable,
    _: c.GC,
    _: c_int,
    _: c_int,
    s: [*c]const u8,
    len: c_int,
) callconv(.c) c_int {
    const n: usize = @min(@as(usize, @intCast(len)), mock_drawn_string.len);
    @memcpy(mock_drawn_string[0..n], s[0..n]);
    mock_drawn_string_len = n;
    return 1;
}

pub export fn XDrawPoints(_: ?*c.Display, _: c.Drawable, _: c.GC, _: [*c]c.XPoint, _: c_int, _: c_int) callconv(.c) c_int {
    return 1;
}

pub export fn XDrawLines(_: ?*c.Display, _: c.Drawable, _: c.GC, _: [*c]c.XPoint, _: c_int, _: c_int) callconv(.c) c_int {
    return 1;
}

pub export fn XFillPolygon(_: ?*c.Display, _: c.Drawable, _: c.GC, _: [*c]c.XPoint, _: c_int, _: c_int, _: c_int) callconv(.c) c_int {
    return 1;
}

pub export fn XCopyArea(_: ?*c.Display, _: c.Drawable, _: c.Drawable, _: c.GC, _: c_int, _: c_int, _: c_uint, _: c_uint, _: c_int, _: c_int) callconv(.c) c_int {
    return 1;
}

pub export fn XListPixmapFormats(_: ?*c.Display, count: *c_int) callconv(.c) [*c]c.XPixmapFormatValues {
    count.* = 1;
    const fmt: *c.XPixmapFormatValues = @ptrCast(@alignCast(std.c.malloc(@sizeOf(c.XPixmapFormatValues)).?));
    fmt.* = .{ .depth = 24, .bits_per_pixel = 32, .scanline_pad = 32 };
    return fmt;
}

fn mockDestroyImage(img: [*c]c.XImage) callconv(.c) c_int {
    const xim: *c.XImage = @ptrCast(img);
    if (xim.data != null) std.c.free(xim.data);
    std.c.free(xim);
    return 1;
}

fn mockGetPixel(img: [*c]c.XImage, x: c_int, y: c_int) callconv(.c) c_ulong {
    const xim: *const c.XImage = @ptrCast(img);
    const offset: usize = @as(usize, @intCast(y)) * @as(usize, @intCast(xim.bytes_per_line)) + @as(usize, @intCast(x)) * 4;
    const ptr: *const u32 = @ptrCast(@alignCast(xim.data + offset));
    return ptr.*;
}

fn mockPutPixel(img: [*c]c.XImage, x: c_int, y: c_int, pixel: c_ulong) callconv(.c) c_int {
    const xim: *const c.XImage = @ptrCast(img);
    const offset: usize = @as(usize, @intCast(y)) * @as(usize, @intCast(xim.bytes_per_line)) + @as(usize, @intCast(x)) * 4;
    const ptr: *u32 = @ptrCast(@alignCast(xim.data + offset));
    ptr.* = @truncate(pixel);
    return 1;
}

pub export fn XCreateImage(
    _: ?*c.Display,
    _: ?*c.Visual,
    depth: c_uint,
    format: c_int,
    offset: c_int,
    data: [*c]u8,
    width: c_uint,
    height: c_uint,
    bitmap_pad: c_int,
    bytes_per_line: c_int,
) callconv(.c) ?*c.XImage {
    const raw = std.c.malloc(@sizeOf(c.XImage)) orelse return null;
    const img: *c.XImage = @ptrCast(@alignCast(raw));
    img.* = std.mem.zeroes(c.XImage);
    img.width = @intCast(width);
    img.height = @intCast(height);
    img.xoffset = offset;
    img.format = format;
    img.data = data;
    img.depth = @intCast(depth);
    img.bitmap_pad = bitmap_pad;
    img.bytes_per_line = bytes_per_line;
    img.bits_per_pixel = 32;
    img.f.destroy_image = &mockDestroyImage;
    img.f.get_pixel = &mockGetPixel;
    img.f.put_pixel = &mockPutPixel;
    return img;
}

pub export fn XPutImage(_: ?*c.Display, _: c.Drawable, _: c.GC, _: *c.XImage, _: c_int, _: c_int, _: c_int, _: c_int, _: c_uint, _: c_uint) callconv(.c) c_int {
    return 1;
}

pub export fn XGetSubImage(_: ?*c.Display, _: c.Drawable, _: c_int, _: c_int, _: c_uint, _: c_uint, _: c_ulong, _: c_int, xi: ?*c.XImage, _: c_int, _: c_int) callconv(.c) ?*c.XImage {
    return xi;
}

pub export fn XSetWMProtocols(_: ?*c.Display, _: c.Window, _: [*c]c.Atom, _: c_int) callconv(.c) c.Status {
    return 1;
}

pub export fn XAllocSizeHints() callconv(.c) ?*c.XSizeHints {
    const sh: *c.XSizeHints = @ptrCast(@alignCast(std.c.malloc(@sizeOf(c.XSizeHints)).?));
    sh.* = std.mem.zeroes(c.XSizeHints);
    return sh;
}

pub export fn XSetWMNormalHints(_: ?*c.Display, _: c.Window, _: *c.XSizeHints) callconv(.c) void {}

pub export fn XAllocWMHints() callconv(.c) ?*c.XWMHints {
    const h: *c.XWMHints = @ptrCast(@alignCast(std.c.malloc(@sizeOf(c.XWMHints)).?));
    h.* = std.mem.zeroes(c.XWMHints);
    return h;
}

pub export fn XSetWMHints(_: ?*c.Display, _: c.Window, _: *c.XWMHints) callconv(.c) c_int {
    return 1;
}

pub export fn XAllocClassHint() callconv(.c) ?*c.XClassHint {
    const ch: *c.XClassHint = @ptrCast(@alignCast(std.c.malloc(@sizeOf(c.XClassHint)).?));
    ch.* = std.mem.zeroes(c.XClassHint);
    return ch;
}

pub export fn XSetClassHint(_: ?*c.Display, _: c.Window, _: *c.XClassHint) callconv(.c) c_int {
    return 1;
}

pub export fn XStringListToTextProperty(_: *[*c]u8, _: c_int, prop: *c.XTextProperty) callconv(.c) c.Status {
    prop.* = std.mem.zeroes(c.XTextProperty);
    return 1;
}

pub export fn XSetWMName(_: ?*c.Display, _: c.Window, _: *c.XTextProperty) callconv(.c) void {}
pub export fn XSetWMIconName(_: ?*c.Display, _: c.Window, _: *c.XTextProperty) callconv(.c) void {}

pub export fn XGetVisualInfo(_: ?*c.Display, _: c_long, _: [*c]c.XVisualInfo, nitems: [*c]c_int) callconv(.c) [*c]c.XVisualInfo {
    nitems.* = 0;
    return null;
}

pub export fn XLookupString(_: [*c]c.XKeyEvent, _: [*c]u8, _: c_int, _: [*c]c.KeySym, _: *c.XComposeStatus) callconv(.c) c_int {
    return 0;
}

pub export fn XWMGeometry(
    _: ?*c.Display,
    _: c_int,
    _: [*c]const u8,
    _: [*c]const u8,
    _: c_uint,
    hints: *c.XSizeHints,
    x: *c_int,
    y: *c_int,
    w: *c_int,
    h: *c_int,
    grav: *c_int,
) callconv(.c) c_int {
    x.* = 0;
    y.* = 0;
    w.* = 10 * hints.width_inc + hints.base_width;
    h.* = 5 * hints.height_inc + hints.base_height;
    grav.* = 1;
    return 0;
}

test "x11 display, graphics, color, image, and setjmp IO error recovery" {
    const xd = x11.base.x_open_display(":0").?;
    try std.testing.expectEqual(@as(c_int, 7), x11.base.x_display_descriptor(xd));

    var dims: [2]c_int = undefined;
    x11.base.x_display_get_size(xd, 0, &dims);
    try std.testing.expectEqual(@as(c_int, 1024), dims[0]);
    try std.testing.expectEqual(@as(c_int, 768), dims[1]);

    const atom = x11.base.x_intern_atom(xd, "UTF8_STRING", 0);
    try std.testing.expect(atom != 0);

    // Open graphics window and verify bucky bits & VDC coordinates
    const gw = x11.graph.x_graphics_open_window(xd, null, "g", "G", 1).?;
    const bucky = x11.base.x_modifier_mask_to_bucky_bits(@intCast(c.ControlMask | (1 << 3) | (1 << 4)), gw);
    // CONTROL(2) | META(1) | SUPER(4) = 7
    try std.testing.expectEqual(@as(c_ulong, 7), bucky);

    x11.graph.x_graphics_set_vdc_extent(gw, -2.0, -1.0, 2.0, 1.0);
    var ext: [4]f32 = undefined;
    x11.graph.x_graphics_vdc_extent(gw, &ext);
    try std.testing.expectEqual(@as(f32, -2.0), ext[0]);
    try std.testing.expectEqual(@as(f32, 1.0), ext[3]);
    try std.testing.expectApproxEqAbs(@as(f32, -2.0), x11.graph.x_graphics_map_x_coordinate(gw, 0), 0.05);

    // Colors
    const cmap = x11.color.x_window_colormap(gw).?;
    defer x11.color.x_free_colormap(cmap);
    const px = x11.color.x_allocate_color(cmap, 0x1200, 0x3400, 0x5600);
    try std.testing.expectEqual(@as(c_long, 0x123456), px);
    x11.color.x_store_color(cmap, 1, 0x0100, 0x0200, 0x0300);
    var vec = [_]c_int{ 2, 0x100, 0x200, 0x300 };
    x11.color.x_store_colors(cmap, &vec, 1);
    var qres: [3]c_uint = undefined;
    x11.color.x_query_color(cmap, @intCast(px), &qres);
    try std.testing.expectEqual(@as(c_uint, 0x1200), qres[0]);

    // Images
    const xi = x11.graph.x_create_image(gw, 4, 3).?;
    try std.testing.expectEqual(@as(c_ulong, 4), x11.graph.x_image_width(xi));
    try std.testing.expectEqual(@as(c_ulong, 3), x11.graph.x_image_height(xi));
    var raw_pixels: [12]u8 = @splat(0);
    raw_pixels[5] = 0x7a; // (x=1, y=1)
    try std.testing.expectEqual(@as(c_int, 0), x11.graph.x_bytes_into_image(&raw_pixels, 12, xi));
    try std.testing.expectEqual(@as(c_long, 0x7a), x11.graph.x_get_pixel_from_image(xi, 1, 1));
    try std.testing.expectEqual(@as(c_int, 1), x11.graph.x_set_pixel_in_image(xi, 2, 1, 0x3f));
    try std.testing.expectEqual(@as(c_long, 0x3f), x11.graph.x_get_pixel_from_image(xi, 2, 1));
    x11.graph.x_destroy_image(xi);

    // XTerm operations
    const tw = x11.term.xterm_open_window(xd, null, "t", "T", 1).?;
    try std.testing.expectEqual(@as(c_uint, 10), x11.term.xterm_x_size(tw));
    try std.testing.expectEqual(@as(c_uint, 5), x11.term.xterm_y_size(tw));
    try std.testing.expectEqual(@as(c_int, 0), x11.term.xterm_write_char(tw, 0, 0, 'A', 0));
    try std.testing.expectEqual(@as(c_int, 0), x11.term.xterm_write_substring(tw, 1, 0, "BCDE", 0, 4, 0));
    try std.testing.expectEqual(@as(c_int, 0), x11.term.xterm_scroll_lines_up(tw, 0, 5, 0, 3, 1));
    try std.testing.expectEqual(@as(c_int, 0), x11.term.xterm_scroll_lines_down(tw, 0, 5, 0, 3, 1));
    var saved: [20]u8 = @splat(0);
    try std.testing.expectEqual(@as(c_int, 0), x11.term.xterm_save_contents(tw, 0, 5, 0, 2, &saved));
    try std.testing.expectEqual(@as(c_int, 0), x11.term.xterm_restore_contents(tw, 0, 5, 0, 2, &saved));
    try std.testing.expectEqual(@as(c_int, 0), x11.term.xterm_reconfigure(tw, 12, 6));
    try std.testing.expectEqual(@as(c_uint, 12), x11.term.xterm_x_size(tw));
    try std.testing.expectEqual(@as(c_uint, 6), x11.term.xterm_y_size(tw));

    // Closing gw normally vs closing tw with IO error triggering scm_longjmp recovery
    x11.base.x_close_window(gw);
    mock_trigger_io_error_on_destroy = true;
    x11.base.x_close_window(tw);
    mock_trigger_io_error_on_destroy = false;

    x11.base.x_close_all_displays();
}
