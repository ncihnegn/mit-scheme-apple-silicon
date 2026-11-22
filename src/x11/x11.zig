// MIT/GNU Scheme X11 FFI plugin root module.
// Derived from MIT/GNU Scheme C sources (`src/x11/x11.h`, `src/x11/x11*.c`):
// Copyright (C) 1986-2022 Massachusetts Institute of Technology
// Licensed under the GNU General Public License (GPL v2 or later); see src/COPYING.

pub const c = @import("x11_c");
pub const base = @import("x11base.zig");
pub const color = @import("x11color.zig");
pub const graph = @import("x11graph.zig");
pub const term = @import("x11term.zig");

comptime {
    _ = base;
    _ = color;
    _ = graph;
    _ = term;
}

pub inline fn defaultScreen(dpy: ?*c.Display) c_int {
    return c.XDefaultScreen(dpy);
}

pub inline fn rootWindow(dpy: ?*c.Display, scr: c_int) c.Window {
    return c.XRootWindow(dpy, scr);
}

pub inline fn defaultColormap(dpy: ?*c.Display, scr: c_int) c.Colormap {
    return c.XDefaultColormap(dpy, scr);
}

pub inline fn whitePixel(dpy: ?*c.Display, scr: c_int) c_ulong {
    return c.XWhitePixel(dpy, scr);
}

pub inline fn blackPixel(dpy: ?*c.Display, scr: c_int) c_ulong {
    return c.XBlackPixel(dpy, scr);
}

pub inline fn displayWidth(dpy: ?*c.Display, scr: c_int) c_int {
    return c.XDisplayWidth(dpy, scr);
}

pub inline fn displayHeight(dpy: ?*c.Display, scr: c_int) c_int {
    return c.XDisplayHeight(dpy, scr);
}

pub inline fn connectionNumber(dpy: ?*c.Display) c_int {
    return c.XConnectionNumber(dpy);
}

pub inline fn defaultVisualOfScreen(scr: ?*c.Screen) ?*c.Visual {
    return c.XDefaultVisualOfScreen(scr);
}

pub inline fn fontWidth(f: *const c.XFontStruct) c_int {
    return f.max_bounds.width;
}

pub inline fn fontHeight(f: *const c.XFontStruct) c_int {
    return f.ascent + f.descent;
}

pub inline fn fontBase(f: *const c.XFontStruct) c_int {
    return f.ascent;
}

pub inline fn imagePutPixel(img: *c.XImage, x: c_int, y: c_int, pixel: c_ulong) void {
    _ = img.f.put_pixel.?(img, x, y, pixel);
}

pub inline fn imageGetPixel(img: *c.XImage, x: c_int, y: c_int) c_ulong {
    return img.f.get_pixel.?(img, x, y);
}

pub inline fn imageDestroy(img: *c.XImage) void {
    _ = img.f.destroy_image.?(img);
}
