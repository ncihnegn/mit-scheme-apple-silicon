#ifndef MOCK_X11_XLIB_H
#define MOCK_X11_XLIB_H

#include <sys/types.h>

typedef unsigned long XID;
typedef XID Window;
typedef XID Drawable;
typedef XID Font;
typedef XID Pixmap;
typedef XID Cursor;
typedef XID Colormap;
typedef XID GContext;
typedef XID KeySym;

typedef unsigned long Atom;
typedef unsigned long Time;
typedef unsigned char KeyCode;
typedef int Bool;
typedef int Status;
typedef char *XPointer;

#define True 1
#define False 0
#define None 0L
#define Success 0

#define CopyFromParent 0L
#define RevertToParent 2
#define InputHint (1L << 0)

#define ShiftMask   (1 << 0)
#define LockMask    (1 << 1)
#define ControlMask (1 << 2)

#define NoEventMask            0L
#define KeyPressMask           (1L << 0)
#define KeyReleaseMask         (1L << 1)
#define ButtonPressMask        (1L << 2)
#define ButtonReleaseMask      (1L << 3)
#define EnterWindowMask        (1L << 4)
#define LeaveWindowMask        (1L << 5)
#define PointerMotionMask      (1L << 6)
#define PointerMotionHintMask  (1L << 7)
#define ExposureMask           (1L << 15)
#define VisibilityChangeMask   (1L << 16)
#define StructureNotifyMask    (1L << 17)
#define FocusChangeMask        (1L << 21)
#define PropertyChangeMask     (1L << 22)

#define KeyPress         2
#define KeyRelease       3
#define ButtonPress      4
#define ButtonRelease    5
#define MotionNotify     6
#define EnterNotify      7
#define LeaveNotify      8
#define FocusIn          9
#define FocusOut         10
#define KeymapNotify     11
#define Expose           12
#define GraphicsExpose   13
#define NoExpose         14
#define VisibilityNotify 15
#define CreateNotify     16
#define DestroyNotify    17
#define UnmapNotify      18
#define MapNotify        19
#define ReparentNotify   21
#define ConfigureNotify  22
#define GravityNotify    24
#define CirculateNotify  26
#define PropertyNotify   28
#define SelectionClear   29
#define SelectionRequest 30
#define SelectionNotify  31
#define ClientMessage    33
#define MappingNotify    34

#define VisibilityUnobscured        0
#define VisibilityPartiallyObscured 1
#define VisibilityFullyObscured     2

#define MappingModifier 0
#define MappingKeyboard 1

#define QueuedAfterReading 1

#define Always        2
#define CWBackPixel   (1L << 1)
#define CWBorderPixel (1L << 3)
#define CWBackingStore (1L << 6)

#define GCFunction   (1L << 0)
#define GCForeground (1L << 2)
#define GCBackground (1L << 3)
#define GCFont       (1L << 14)

#define DoRed   (1 << 0)
#define DoGreen (1 << 1)
#define DoBlue  (1 << 2)

#define Unsorted        0
#define CoordModeOrigin 0
#define Nonconvex       1
#define CapButt         1
#define JoinMiter       0
#define ZPixmap         2

typedef struct _XDisplay Display;
typedef struct _XGC *GC;

typedef struct {
    void *ext_data;
    unsigned long visualid;
    int c_class;
    unsigned long red_mask, green_mask, blue_mask;
    int bits_per_rgb;
    int map_entries;
} Visual;

typedef struct {
    void *ext_data;
    Display *display;
    Window root;
    int width, height;
    int mwidth, mheight;
    int ndepths;
    void *depths;
    int root_depth;
    Visual *root_visual;
    GC default_gc;
    Colormap cmap;
    unsigned long white_pixel;
    unsigned long black_pixel;
    int max_maps, min_maps;
    int backing_store;
    Bool save_unders;
    long root_input_mask;
} Screen;

typedef struct {
    short lbearing;
    short rbearing;
    short width;
    short ascent;
    short descent;
    unsigned short attributes;
} XCharStruct;

typedef struct {
    void *ext_data;
    Font fid;
    unsigned direction;
    unsigned min_char_or_byte2;
    unsigned max_char_or_byte2;
    unsigned min_byte1;
    unsigned max_byte1;
    Bool all_chars_exist;
    unsigned default_char;
    int n_properties;
    void *properties;
    XCharStruct min_bounds;
    XCharStruct max_bounds;
    XCharStruct *per_char;
    int ascent;
    int descent;
} XFontStruct;

typedef struct {
    unsigned long pixel;
    unsigned short red, green, blue;
    char flags;
    char pad;
} XColor;

typedef struct {
    int function;
    unsigned long plane_mask;
    unsigned long foreground;
    unsigned long background;
    int line_width;
    int line_style;
    int cap_style;
    int join_style;
    int fill_style;
    int fill_rule;
    int arc_mode;
    Pixmap tile;
    Pixmap stipple;
    int ts_x_origin;
    int ts_y_origin;
    Font font;
    int subwindow_mode;
    Bool graphics_exposures;
    int clip_x_origin;
    int clip_y_origin;
    Pixmap clip_mask;
    int dash_offset;
    char dashes;
} XGCValues;

typedef struct {
    Pixmap background_pixmap;
    unsigned long background_pixel;
    Pixmap border_pixmap;
    unsigned long border_pixel;
    int bit_gravity;
    int win_gravity;
    int backing_store;
    unsigned long backing_planes;
    unsigned long backing_pixel;
    Bool save_under;
    long event_mask;
    long do_not_propagate_mask;
    Bool override_redirect;
    Colormap colormap;
    Cursor cursor;
} XSetWindowAttributes;

typedef struct {
    int x, y;
    int width, height;
    int border_width;
    int depth;
    Visual *visual;
    Window root;
    int c_class;
    int bit_gravity;
    int win_gravity;
    int backing_store;
    unsigned long backing_planes;
    unsigned long backing_pixel;
    Bool save_under;
    Colormap colormap;
    Bool map_installed;
    int map_state;
    long all_event_masks;
    long your_event_mask;
    long do_not_propagate_mask;
    Bool override_redirect;
    Screen *screen;
} XWindowAttributes;

typedef struct {
    short x, y;
    unsigned short width, height;
} XRectangle;

typedef struct {
    short x, y;
} XPoint;

typedef struct {
    int depth;
    int bits_per_pixel;
    int scanline_pad;
} XPixmapFormatValues;

typedef struct _XImage {
    int width, height;
    int xoffset;
    int format;
    char *data;
    int byte_order;
    int bitmap_unit;
    int bitmap_bit_order;
    int bitmap_pad;
    int depth;
    int bytes_per_line;
    int bits_per_pixel;
    unsigned long red_mask;
    unsigned long green_mask;
    unsigned long blue_mask;
    XPointer obdata;
    struct funcs {
        struct _XImage *(*create_image)(void);
        int (*destroy_image)(struct _XImage *);
        unsigned long (*get_pixel)(struct _XImage *, int, int);
        int (*put_pixel)(struct _XImage *, int, int, unsigned long);
        struct _XImage *(*sub_image)(struct _XImage *, int, int, unsigned int, unsigned int);
        int (*add_pixel)(struct _XImage *, long);
    } f;
} XImage;

typedef struct {
    int max_keypermod;
    KeyCode *modifiermap;
} XModifierKeymap;

typedef struct {
    int type;
    Display *display;
    XID resourceid;
    unsigned long serial;
    unsigned char error_code;
    unsigned char request_code;
    unsigned char minor_code;
} XErrorEvent;

typedef struct {
    int type;
    unsigned long serial;
    Bool send_event;
    Display *display;
    Window window;
} XAnyEvent;

typedef struct {
    int type;
    unsigned long serial;
    Bool send_event;
    Display *display;
    Window window;
    Window root;
    Window subwindow;
    Time time;
    int x, y;
    int x_root, y_root;
    unsigned int state;
    unsigned int keycode;
    Bool same_screen;
} XKeyEvent;

typedef struct {
    int type;
    unsigned long serial;
    Bool send_event;
    Display *display;
    Window window;
    int state;
} XVisibilityEvent;

typedef struct {
    int type;
    unsigned long serial;
    Bool send_event;
    Display *display;
    Window event;
    Window window;
    int x, y;
    int width, height;
    int border_width;
    Window above;
    Bool override_redirect;
} XConfigureEvent;

typedef struct {
    int type;
    unsigned long serial;
    Bool send_event;
    Display *display;
    Window window;
    Atom selection;
    Time time;
} XSelectionClearEvent;

typedef struct {
    int type;
    unsigned long serial;
    Bool send_event;
    Display *display;
    Window owner;
    Window requestor;
    Atom selection;
    Atom target;
    Atom property;
    Time time;
} XSelectionRequestEvent;

typedef struct {
    int type;
    unsigned long serial;
    Bool send_event;
    Display *display;
    Window requestor;
    Atom selection;
    Atom target;
    Atom property;
    Time time;
} XSelectionEvent;

typedef struct {
    int type;
    unsigned long serial;
    Bool send_event;
    Display *display;
    Window window;
    Atom message_type;
    int format;
    union {
        char b[20];
        short s[10];
        long l[5];
    } data;
} XClientMessageEvent;

typedef struct {
    int type;
    unsigned long serial;
    Bool send_event;
    Display *display;
    Window window;
    Atom atom;
    Time time;
    int state;
} XPropertyEvent;

typedef struct {
    int type;
    unsigned long serial;
    Bool send_event;
    Display *display;
    Window window;
    int request;
    int first_keycode;
    int count;
} XMappingEvent;

typedef union _XEvent {
    int type;
    XAnyEvent xany;
    XKeyEvent xkey;
    XVisibilityEvent xvisibility;
    XConfigureEvent xconfigure;
    XSelectionClearEvent xselectionclear;
    XSelectionRequestEvent xselectionrequest;
    XSelectionEvent xselection;
    XClientMessageEvent xclient;
    XPropertyEvent xproperty;
    XMappingEvent xmapping;
    long pad[24];
} XEvent;

typedef int (*XErrorHandler)(Display *, XErrorEvent *);
typedef int (*XIOErrorHandler)(Display *);

extern Display *XOpenDisplay(const char *);
extern int XCloseDisplay(Display *);
extern int XDefaultScreen(Display *);
extern Window XRootWindow(Display *, int);
extern Colormap XDefaultColormap(Display *, int);
extern unsigned long XWhitePixel(Display *, int);
extern unsigned long XBlackPixel(Display *, int);
extern int XDisplayWidth(Display *, int);
extern int XDisplayHeight(Display *, int);
extern int XConnectionNumber(Display *);
extern Visual *XDefaultVisualOfScreen(Screen *);
extern long XMaxRequestSize(Display *);
extern int XScreenNumberOfScreen(Screen *);
extern int XFree(void *);
extern int XSync(Display *, Bool);
extern int XFlush(Display *);
extern int XNoOp(Display *);
extern XErrorHandler XSetErrorHandler(XErrorHandler);
extern XIOErrorHandler XSetIOErrorHandler(XIOErrorHandler);
extern int XGetErrorText(Display *, int, char *, int);
extern char *XGetDefault(Display *, const char *, const char *);
extern XFontStruct *XLoadQueryFont(Display *, const char *);
extern XFontStruct *XQueryFont(Display *, XID);
extern int XFreeFont(Display *, XFontStruct *);
extern char **XListFonts(Display *, const char *, int, int *);
extern Status XParseColor(Display *, Colormap, const char *, XColor *);
extern Status XAllocColor(Display *, Colormap, XColor *);
extern int XQueryColor(Display *, Colormap, XColor *);
extern int XStoreColor(Display *, Colormap, XColor *);
extern int XStoreColors(Display *, Colormap, XColor *, int);
extern Colormap XCreateColormap(Display *, Window, Visual *, int);
extern int XFreeColormap(Display *, Colormap);
extern int XSetWindowColormap(Display *, Window, Colormap);
extern Status XGetWindowAttributes(Display *, Window, XWindowAttributes *);
extern Status XQueryTree(Display *, Window, Window *, Window *, Window **, unsigned int *);
extern Status XGetGeometry(Display *, Drawable, Window *, int *, int *, unsigned int *, unsigned int *, unsigned int *, unsigned int *);
extern GC XCreateGC(Display *, Drawable, unsigned long, XGCValues *);
extern Cursor XCreateFontCursor(Display *, unsigned int);
extern int XFreeCursor(Display *, Cursor);
extern int XRecolorCursor(Display *, Cursor, XColor *, XColor *);
extern int XDefineCursor(Display *, Window, Cursor);
extern int XSelectInput(Display *, Window, long);
extern XModifierKeymap *XGetModifierMapping(Display *);
extern int XFreeModifiermap(XModifierKeymap *);
extern int XDisplayKeycodes(Display *, int *, int *);
extern KeySym *XGetKeyboardMapping(Display *, KeyCode, int, int *);
extern int XRebindKeysym(Display *, KeySym, KeySym *, int, unsigned char *, int);
extern Atom XInternAtom(Display *, const char *, Bool);
extern char *XGetAtomName(Display *, Atom);
extern int XGetWindowProperty(Display *, Window, Atom, long, long, Bool, Atom, Atom *, int *, unsigned long *, unsigned long *, unsigned char **);
extern int XChangeProperty(Display *, Window, Atom, Atom, int, int, const unsigned char *, int);
extern int XDeleteProperty(Display *, Window, Atom);
extern int XSetSelectionOwner(Display *, Atom, Window, Time);
extern Window XGetSelectionOwner(Display *, Atom);
extern int XConvertSelection(Display *, Atom, Atom, Atom, Window, Time);
extern Status XSendEvent(Display *, Window, Bool, long, XEvent *);
extern int XNextEvent(Display *, XEvent *);
extern int XEventsQueued(Display *, int);
extern int XRefreshKeyboardMapping(XMappingEvent *);
extern int XSetForeground(Display *, GC, unsigned long);
extern int XSetBackground(Display *, GC, unsigned long);
extern int XSetFont(Display *, GC, Font);
extern int XSetFunction(Display *, GC, int);
extern int XSetFillStyle(Display *, GC, int);
extern int XSetLineAttributes(Display *, GC, unsigned int, int, int, int);
extern int XSetDashes(Display *, GC, int, const char *, int);
extern int XSetClipRectangles(Display *, GC, int, int, XRectangle *, int, int);
extern int XSetWindowBackground(Display *, Window, unsigned long);
extern int XSetWindowBorder(Display *, Window, unsigned long);
extern int XSetWindowBorderWidth(Display *, Window, unsigned int);
extern int XSetInputFocus(Display *, Window, int, Time);
extern int XMapWindow(Display *, Window);
extern Status XIconifyWindow(Display *, Window, int);
extern Status XWithdrawWindow(Display *, Window, int);
extern int XResizeWindow(Display *, Window, unsigned int, unsigned int);
extern int XRaiseWindow(Display *, Window);
extern int XLowerWindow(Display *, Window);
extern int XMoveWindow(Display *, Window, int, int);
extern int XClearWindow(Display *, Window);
extern int XClearArea(Display *, Window, int, int, unsigned int, unsigned int, Bool);
extern Window XCreateWindow(Display *, Window, int, int, unsigned int, unsigned int, unsigned int, int, unsigned int, Visual *, unsigned long, XSetWindowAttributes *);
extern Window XCreateSimpleWindow(Display *, Window, int, int, unsigned int, unsigned int, unsigned int, unsigned long, unsigned long);
extern int XDestroyWindow(Display *, Window);
extern int XBell(Display *, int);
extern Bool XQueryPointer(Display *, Window, Window *, Window *, int *, int *, int *, int *, unsigned int *);
extern int XGeometry(Display *, int, const char *, const char *, unsigned int, unsigned int, unsigned int, int, int, int *, int *, int *, int *);
extern int XDrawLine(Display *, Drawable, GC, int, int, int, int);
extern int XDrawPoint(Display *, Drawable, GC, int, int);
extern int XDrawArc(Display *, Drawable, GC, int, int, unsigned int, unsigned int, int, int);
extern int XFillArc(Display *, Drawable, GC, int, int, unsigned int, unsigned int, int, int);
extern int XDrawString(Display *, Drawable, GC, int, int, const char *, int);
extern int XDrawImageString(Display *, Drawable, GC, int, int, const char *, int);
extern int XDrawPoints(Display *, Drawable, GC, XPoint *, int, int);
extern int XDrawLines(Display *, Drawable, GC, XPoint *, int, int);
extern int XFillPolygon(Display *, Drawable, GC, XPoint *, int, int, int);
extern int XCopyArea(Display *, Drawable, Drawable, GC, int, int, unsigned int, unsigned int, int, int);
extern XPixmapFormatValues *XListPixmapFormats(Display *, int *);
extern XImage *XCreateImage(Display *, Visual *, unsigned int, int, int, char *, unsigned int, unsigned int, int, int);
extern int XPutImage(Display *, Drawable, GC, XImage *, int, int, int, int, unsigned int, unsigned int);
extern XImage *XGetSubImage(Display *, Drawable, int, int, unsigned int, unsigned int, unsigned long, int, XImage *, int, int);
extern Status XSetWMProtocols(Display *, Window, Atom *, int);

#endif
