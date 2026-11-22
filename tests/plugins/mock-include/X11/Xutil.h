#ifndef MOCK_X11_XUTIL_H
#define MOCK_X11_XUTIL_H

#include <X11/Xlib.h>

#define XValue      0x0001
#define YValue      0x0002
#define WidthValue  0x0004
#define HeightValue 0x0008

#define USPosition  (1L << 0)
#define USSize      (1L << 1)
#define PPosition   (1L << 2)
#define PSize       (1L << 3)
#define PMinSize    (1L << 4)
#define PResizeInc  (1L << 6)
#define PBaseSize   (1L << 8)
#define PWinGravity (1L << 9)

typedef struct {
    long flags;
    int x, y;
    int width, height;
    int min_width, min_height;
    int max_width, max_height;
    int width_inc, height_inc;
    struct { int x, y; } min_aspect, max_aspect;
    int base_width, base_height;
    int win_gravity;
} XSizeHints;

typedef struct {
    long flags;
    Bool input;
    int initial_state;
    Pixmap icon_pixmap;
    Window icon_window;
    int icon_x, icon_y;
    Pixmap icon_mask;
    XID window_group;
} XWMHints;

typedef struct {
    char *res_name;
    char *res_class;
} XClassHint;

typedef struct {
    unsigned char *value;
    Atom encoding;
    int format;
    unsigned long nitems;
} XTextProperty;

typedef struct {
    Visual *visual;
    unsigned long visualid;
    int screen;
    int depth;
    int c_class;
    unsigned long red_mask;
    unsigned long green_mask;
    unsigned long blue_mask;
    int colormap_size;
    int bits_per_rgb;
} XVisualInfo;

typedef struct _XComposeStatus {
    XPointer compose_ptr;
    int chars_matched;
} XComposeStatus;

extern XSizeHints *XAllocSizeHints(void);
extern void XSetWMNormalHints(Display *, Window, XSizeHints *);
extern XWMHints *XAllocWMHints(void);
extern int XSetWMHints(Display *, Window, XWMHints *);
extern XClassHint *XAllocClassHint(void);
extern int XSetClassHint(Display *, Window, XClassHint *);
extern Status XStringListToTextProperty(char **, int, XTextProperty *);
extern void XSetWMName(Display *, Window, XTextProperty *);
extern void XSetWMIconName(Display *, Window, XTextProperty *);
extern XVisualInfo *XGetVisualInfo(Display *, long, XVisualInfo *, int *);
extern int XLookupString(XKeyEvent *, char *, int, KeySym *, XComposeStatus *);
extern int XWMGeometry(Display *, int, const char *, const char *, unsigned int, XSizeHints *, int *, int *, int *, int *, int *);

#endif
