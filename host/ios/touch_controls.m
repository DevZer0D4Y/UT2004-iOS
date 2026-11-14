// Touch controls for UT2004 on iOS.
//
// One transparent view on top of SDL's window handles every touch and feeds
// SDL's own input pipeline (SDL_UT_* from sdl_ext/), so SDLDrv sees a mouse
// and keyboard exactly as on macOS:
//   menus    (a GUI is open, host_menu_active()): finger = absolute pointer,
//            touch down = left button down, lift = release (a click)
//   gameplay: left part = movement stick (WASD), elsewhere drag = look,
//            buttons for fire/alt/jump/crouch/weapons/use/scores
// The overlay hides itself while a game controller is connected.
//
// SDLDrv applies the pointer position after it has processed the frame's
// button events, so pointer moves and button changes go out on separate
// display-link ticks (one queued mouse event per tick, >= 40 ms apart).
#import <GameController/GameController.h>
#import <UIKit/UIKit.h>
#include <SDL3/SDL.h>
#include <SDL3/SDL_ut2004.h>

#include "../host_common.h"
#include "touch_controls.h"

typedef enum { BTN_KEY, BTN_MOUSE, BTN_WHEEL, BTN_TEXT } BtnKind;

typedef struct {
    const char *label;
    BtnKind kind;
    int code;        // scancode, mouse button, or wheel direction
    float cx, cy;    // centre, fractions of width/height (from the right edge if cx < 0)
    float r;         // radius in points
    bool aim;        // dragging from this button also looks around
    bool game_only;  // hidden in menus
} BtnDef;

static const BtnDef kButtons[] = {
    {"FIRE", BTN_MOUSE, SDL_BUTTON_LEFT, -0.115f, 0.70f, 46, true, true},
    {"ALT", BTN_MOUSE, SDL_BUTTON_RIGHT, -0.255f, 0.80f, 34, true, true},
    {"JUMP", BTN_KEY, SDL_SCANCODE_SPACE, -0.085f, 0.40f, 32, false, true},
    {"DUCK", BTN_KEY, SDL_SCANCODE_C, -0.215f, 0.52f, 28, false, true},
    {"◀ WPN", BTN_WHEEL, 1, -0.345f, 0.88f, 24, false, true},
    {"WPN ▶", BTN_WHEEL, -1, -0.345f, 0.68f, 24, false, true},
    {"USE", BTN_KEY, SDL_SCANCODE_U, -0.345f, 0.48f, 22, false, true},
    {"SCORE", BTN_KEY, SDL_SCANCODE_F1, 0.53f, 0.07f, 22, false, true},
    {"MENU", BTN_KEY, SDL_SCANCODE_ESCAPE, 0.06f, 0.10f, 24, false, false},
    {"⌨", BTN_TEXT, 0, 0.47f, 0.07f, 22, false, false},
};
#define NUM_BUTTONS (sizeof kButtons / sizeof *kButtons)

static const float kStickRadius = 60.0f;
static const float kStickDead = 0.30f;   // fraction of radius before a key is pressed
static const float kLookScale = 2.2f;    // mouse units per point of finger travel

// ---- spaced pointer events (menus) -------------------------------------------
typedef enum { PEV_MOVE, PEV_DOWN, PEV_UP } PevKind;
typedef struct {
    PevKind kind;
    float x, y;
} Pev;
#define PEV_MAX 64
static Pev g_pev[PEV_MAX];
static int g_pev_head, g_pev_count;
static double g_pev_last;

static double now_s(void)
{
    return CACurrentMediaTime();
}

static void pev_push(PevKind k, CGPoint p)
{
    if (k == PEV_MOVE && g_pev_count > 0) { // coalesce consecutive moves
        Pev *last = &g_pev[(g_pev_head + g_pev_count - 1) % PEV_MAX];
        if (last->kind == PEV_MOVE) {
            last->x = (float)p.x;
            last->y = (float)p.y;
            return;
        }
    }
    if (g_pev_count == PEV_MAX)
        return;
    g_pev[(g_pev_head + g_pev_count) % PEV_MAX] = (Pev){k, (float)p.x, (float)p.y};
    g_pev_count++;
}

static void pev_pump(void)
{
    if (!g_pev_count || now_s() - g_pev_last < 0.04)
        return;
    Pev e = g_pev[g_pev_head];
    g_pev_head = (g_pev_head + 1) % PEV_MAX;
    g_pev_count--;
    g_pev_last = now_s();
    switch (e.kind) {
    case PEV_MOVE: SDL_UT_MouseMoveTo(e.x, e.y); break;
    case PEV_DOWN: SDL_UT_MouseButton(SDL_BUTTON_LEFT, true); break;
    case PEV_UP: SDL_UT_MouseButton(SDL_BUTTON_LEFT, false); break;
    }
}

@interface UTTouchOverlay : UIView
- (void)fingerBegan:(id)key at:(CGPoint)p;
- (void)fingerMoved:(id)key at:(CGPoint)p;
- (void)fingerEnded:(id)key at:(CGPoint)p;
- (void)tick;
@end

@implementation UTTouchOverlay {
    SDL_Window *_sdlWindow;
    BOOL _gameMode;
    BOOL _padMode;
    BOOL _textInput;
    CAShapeLayer *_btnLayers[NUM_BUTTONS];
    CATextLayer *_btnText[NUM_BUTTONS];
    CGPoint _btnCenter[NUM_BUTTONS];
    id _btnTouch[NUM_BUTTONS];
    CGPoint _btnLast[NUM_BUTTONS];
    id _stickTouch;
    CGPoint _stickOrigin;
    CAShapeLayer *_stickBase, *_stickKnob;
    bool _keys[4]; // W A S D
    id _lookTouch;
    CGPoint _lookLast;
    id _pointerTouch;
}

- (instancetype)initWithFrame:(CGRect)frame window:(SDL_Window *)window
{
    if ((self = [super initWithFrame:frame])) {
        _sdlWindow = window;
        self.multipleTouchEnabled = YES;
        self.backgroundColor = UIColor.clearColor;
        self.autoresizingMask = UIViewAutoresizingFlexibleWidth | UIViewAutoresizingFlexibleHeight;
        for (size_t i = 0; i < NUM_BUTTONS; i++) {
            CAShapeLayer *l = [CAShapeLayer layer];
            l.fillColor = [UIColor colorWithWhite:0.1 alpha:0.35].CGColor;
            l.strokeColor = [UIColor colorWithWhite:1.0 alpha:0.55].CGColor;
            l.lineWidth = 2;
            [self.layer addSublayer:l];
            CATextLayer *t = [CATextLayer layer];
            t.string = @(kButtons[i].label);
            t.fontSize = kButtons[i].r > 30 ? 15 : 12;
            t.alignmentMode = kCAAlignmentCenter;
            t.foregroundColor = [UIColor colorWithWhite:1.0 alpha:0.85].CGColor;
            t.contentsScale = UIScreen.mainScreen.scale;
            [l addSublayer:t];
            _btnLayers[i] = l;
            _btnText[i] = t;
        }
        _stickBase = [CAShapeLayer layer];
        _stickBase.fillColor = [UIColor colorWithWhite:0.1 alpha:0.25].CGColor;
        _stickBase.strokeColor = [UIColor colorWithWhite:1.0 alpha:0.4].CGColor;
        _stickBase.lineWidth = 2;
        _stickBase.hidden = YES;
        _stickKnob = [CAShapeLayer layer];
        _stickKnob.fillColor = [UIColor colorWithWhite:1.0 alpha:0.45].CGColor;
        _stickKnob.hidden = YES;
        [self.layer addSublayer:_stickBase];
        [self.layer addSublayer:_stickKnob];
        [self applyVisibility];
    }
    return self;
}

- (void)layoutSubviews
{
    [super layoutSubviews];
    CGRect b = self.bounds;
    UIEdgeInsets safe = self.safeAreaInsets;
    for (size_t i = 0; i < NUM_BUTTONS; i++) {
        const BtnDef *d = &kButtons[i];
        CGFloat x = d->cx < 0 ? b.size.width - safe.right + d->cx * b.size.width
                              : safe.left + d->cx * b.size.width;
        CGFloat y = d->cy * b.size.height;
        _btnCenter[i] = CGPointMake(x, y);
        CGRect box = CGRectMake(x - d->r, y - d->r, 2 * d->r, 2 * d->r);
        [CATransaction begin];
        [CATransaction setDisableActions:YES];
        _btnLayers[i].path = [UIBezierPath bezierPathWithOvalInRect:box].CGPath;
        _btnText[i].frame = CGRectMake(box.origin.x, y - _btnText[i].fontSize * 0.65, box.size.width,
                                       _btnText[i].fontSize * 1.4);
        [CATransaction commit];
    }
}

// ---- mode ------------------------------------------------------------------
- (void)applyVisibility
{
    [CATransaction begin];
    [CATransaction setDisableActions:YES];
    for (size_t i = 0; i < NUM_BUTTONS; i++)
        _btnLayers[i].hidden = _padMode || (kButtons[i].game_only && !_gameMode);
    [CATransaction commit];
}

- (void)tick
{
    SDL_UT_EnsureRelativeMouseMode(); // backstop: SDLDrv asserts that relative mode can be set
    pev_pump();
    BOOL game = host_menu_active() == 0; // unknown (loading) counts as menu
    BOOL pad = GCController.controllers.count > 0;
    if (game != _gameMode || pad != _padMode) {
        [self releaseAll];
        _gameMode = game;
        _padMode = pad;
        [self applyVisibility];
        host_log("[touch] %s%s", game ? "gameplay controls" : "menu pointer", pad ? " (controller: hidden)" : "");
    }
    [self.superview bringSubviewToFront:self];
}

- (void)releaseAll
{
    for (size_t i = 0; i < NUM_BUTTONS; i++)
        if (_btnTouch[i])
            [self button:i down:NO];
    [self setStick:CGPointZero];
    _stickTouch = nil;
    _stickBase.hidden = _stickKnob.hidden = YES;
    _lookTouch = nil;
    if (_pointerTouch) {
        pev_push(PEV_UP, CGPointZero);
        _pointerTouch = nil;
    }
}

// ---- buttons ---------------------------------------------------------------
- (int)buttonAt:(CGPoint)p
{
    for (size_t i = 0; i < NUM_BUTTONS; i++) {
        if (_btnLayers[i].hidden)
            continue;
        CGFloat dx = p.x - _btnCenter[i].x, dy = p.y - _btnCenter[i].y;
        CGFloat r = kButtons[i].r + 8;
        if (dx * dx + dy * dy <= r * r)
            return (int)i;
    }
    return -1;
}

- (void)button:(size_t)i down:(BOOL)down
{
    const BtnDef *d = &kButtons[i];
    switch (d->kind) {
    case BTN_KEY:
        SDL_UT_Key((SDL_Scancode)d->code, down);
        break;
    case BTN_MOUSE:
        SDL_UT_MouseButton((Uint8)d->code, down);
        break;
    case BTN_WHEEL:
        if (down)
            SDL_UT_MouseWheel((float)d->code);
        break;
    case BTN_TEXT:
        if (down) {
            _textInput = !_textInput;
            if (_textInput)
                SDL_StartTextInput(_sdlWindow);
            else
                SDL_StopTextInput(_sdlWindow);
        }
        break;
    }
    _btnLayers[i].fillColor = [UIColor colorWithWhite:down ? 0.9 : 0.1 alpha:down ? 0.45 : 0.35].CGColor;
    if (!down)
        _btnTouch[i] = nil;
}

// ---- stick -----------------------------------------------------------------
- (void)setStick:(CGPoint)v // v in [-1,1], y down
{
    static const SDL_Scancode sc[4] = {SDL_SCANCODE_W, SDL_SCANCODE_A, SDL_SCANCODE_S, SDL_SCANCODE_D};
    bool want[4] = {v.y < -kStickDead, v.x < -kStickDead, v.y > kStickDead, v.x > kStickDead};
    for (int k = 0; k < 4; k++) {
        if (want[k] != _keys[k]) {
            _keys[k] = want[k];
            SDL_UT_Key(sc[k], want[k]);
        }
    }
}

- (void)drawStickAt:(CGPoint)knob
{
    [CATransaction begin];
    [CATransaction setDisableActions:YES];
    _stickBase.path = [UIBezierPath bezierPathWithOvalInRect:CGRectMake(_stickOrigin.x - kStickRadius,
                                                                         _stickOrigin.y - kStickRadius,
                                                                         2 * kStickRadius, 2 * kStickRadius)].CGPath;
    _stickKnob.path = [UIBezierPath bezierPathWithOvalInRect:CGRectMake(knob.x - 24, knob.y - 24, 48, 48)].CGPath;
    _stickBase.hidden = _stickKnob.hidden = NO;
    [CATransaction commit];
}

// ---- fingers (UITouch or a test key) ----------------------------------------
- (void)fingerBegan:(id)key at:(CGPoint)p
{
    if (_padMode)
        return;
    int b = [self buttonAt:p];
    if (b >= 0 && !_btnTouch[b]) {
        _btnTouch[b] = key;
        _btnLast[b] = p;
        [self button:(size_t)b down:YES];
        return;
    }
    if (!_gameMode) {
        if (!_pointerTouch) { // menus: the finger is the mouse pointer
            _pointerTouch = key;
            pev_push(PEV_MOVE, p);
            pev_push(PEV_DOWN, p);
        }
    } else if (p.x < self.bounds.size.width * 0.4f && !_stickTouch) {
        _stickTouch = key;
        _stickOrigin = p;
        [self drawStickAt:p];
    } else if (!_lookTouch) {
        _lookTouch = key;
        _lookLast = p;
    }
}

- (void)fingerMoved:(id)key at:(CGPoint)p
{
    if (key == _pointerTouch) {
        pev_push(PEV_MOVE, p);
    } else if (key == _stickTouch) {
        CGFloat dx = p.x - _stickOrigin.x, dy = p.y - _stickOrigin.y;
        CGFloat len = sqrt(dx * dx + dy * dy);
        if (len > kStickRadius) { // drag the stick base along
            _stickOrigin.x += dx * (1 - kStickRadius / len);
            _stickOrigin.y += dy * (1 - kStickRadius / len);
            dx = p.x - _stickOrigin.x;
            dy = p.y - _stickOrigin.y;
        }
        [self setStick:CGPointMake(dx / kStickRadius, dy / kStickRadius)];
        [self drawStickAt:p];
    } else if (key == _lookTouch) {
        SDL_UT_MouseMotion((float)(p.x - _lookLast.x) * kLookScale, (float)(p.y - _lookLast.y) * kLookScale);
        _lookLast = p;
    } else {
        for (size_t i = 0; i < NUM_BUTTONS; i++) {
            if (_btnTouch[i] == key && kButtons[i].aim) {
                SDL_UT_MouseMotion((float)(p.x - _btnLast[i].x) * kLookScale,
                                   (float)(p.y - _btnLast[i].y) * kLookScale);
                _btnLast[i] = p;
            }
        }
    }
}

- (void)fingerEnded:(id)key at:(CGPoint)p
{
    if (key == _pointerTouch) {
        pev_push(PEV_MOVE, p);
        pev_push(PEV_UP, p);
        _pointerTouch = nil;
    } else if (key == _stickTouch) {
        _stickTouch = nil;
        [self setStick:CGPointZero];
        _stickBase.hidden = _stickKnob.hidden = YES;
    } else if (key == _lookTouch) {
        _lookTouch = nil;
    } else {
        for (size_t i = 0; i < NUM_BUTTONS; i++)
            if (_btnTouch[i] == key)
                [self button:i down:NO];
    }
}

- (void)touchesBegan:(NSSet<UITouch *> *)touches withEvent:(UIEvent *)event
{
    for (UITouch *t in touches)
        [self fingerBegan:t at:[t locationInView:self]];
}

- (void)touchesMoved:(NSSet<UITouch *> *)touches withEvent:(UIEvent *)event
{
    for (UITouch *t in touches)
        [self fingerMoved:t at:[t locationInView:self]];
}

- (void)touchesEnded:(NSSet<UITouch *> *)touches withEvent:(UIEvent *)event
{
    for (UITouch *t in touches)
        [self fingerEnded:t at:[t locationInView:self]];
}

- (void)touchesCancelled:(NSSet<UITouch *> *)touches withEvent:(UIEvent *)event
{
    [self touchesEnded:touches withEvent:event];
}

@end

// ---- attach to SDL's window once the game has created it --------------------
static UTTouchOverlay *g_overlay;
static CADisplayLink *g_link;

static UIWindow *sdl_uiwindow(SDL_Window **out)
{
    int n = 0;
    SDL_Window **wins = SDL_GetWindows(&n);
    SDL_Window *w = (wins && n > 0) ? wins[0] : NULL;
    SDL_free(wins);
    if (out)
        *out = w;
    if (!w)
        return nil;
    return (__bridge UIWindow *)SDL_GetPointerProperty(SDL_GetWindowProperties(w),
                                                        SDL_PROP_WINDOW_UIKIT_WINDOW_POINTER, NULL);
}

@interface UTTouchAttacher : NSObject
@end
@implementation UTTouchAttacher
- (void)step:(CADisplayLink *)link
{
    if (g_overlay) {
        [g_overlay tick];
        return;
    }
    SDL_Window *w = NULL;
    UIWindow *uiwin = sdl_uiwindow(&w);
    if (!uiwin)
        return;
    g_overlay = [[UTTouchOverlay alloc] initWithFrame:uiwin.bounds window:w];
    [uiwin addSubview:g_overlay];
    host_log("[touch] overlay attached to %.0fx%.0f window", uiwin.bounds.size.width, uiwin.bounds.size.height);
}
@end

void ut_touch_controls_start(void)
{
    // the overlay generates all mouse input; no synthetic mouse from touches
    SDL_SetHint(SDL_HINT_TOUCH_MOUSE_EVENTS, "0");
    static UTTouchAttacher *attacher;
    attacher = [UTTouchAttacher new];
    g_link = [CADisplayLink displayLinkWithTarget:attacher selector:@selector(step:)];
    g_link.preferredFramesPerSecond = 60;
    [g_link addToRunLoop:[NSRunLoop mainRunLoop] forMode:NSRunLoopCommonModes];
}

// ---- test hooks (for an optional scripted-input module) ------------------------------------
__attribute__((visibility("default"))) void ut_touch_inject(int phase, int finger, float x, float y)
{
    static NSNumber *keys[10];
    if (finger < 0 || finger >= 10 || !g_overlay)
        return;
    if (!keys[finger])
        keys[finger] = [[NSNumber alloc] initWithInt:1000 + finger];
    CGPoint p = CGPointMake(x, y);
    if (phase == 0)
        [g_overlay fingerBegan:keys[finger] at:p];
    else if (phase == 1)
        [g_overlay fingerMoved:keys[finger] at:p];
    else
        [g_overlay fingerEnded:keys[finger] at:p];
}

// Renders the UIKit window (game layer + overlay) to a PNG.
__attribute__((visibility("default"))) void ut_ui_snapshot(const char *path)
{
    UIWindow *win = sdl_uiwindow(NULL);
    if (!win)
        return;
    UIGraphicsImageRenderer *r = [[UIGraphicsImageRenderer alloc] initWithBounds:win.bounds];
    UIImage *img = [r imageWithActions:^(UIGraphicsImageRendererContext *ctx) {
        [win drawViewHierarchyInRect:win.bounds afterScreenUpdates:NO];
    }];
    [UIImagePNGRepresentation(img) writeToFile:@(path) atomically:YES];
    host_log("[touch] snapshot %s (%.0fx%.0f)", path, win.bounds.size.width, win.bounds.size.height);
    // log the game's Metal layer geometry (snapshots of CAMetalLayer can mis-scale)
    NSMutableArray *todo = [NSMutableArray arrayWithObject:win.layer];
    while (todo.count) {
        CALayer *l = todo.lastObject;
        [todo removeLastObject];
        if ([l isKindOfClass:[CAMetalLayer class]]) {
            CAMetalLayer *m = (CAMetalLayer *)l;
            host_log("[touch] metal layer bounds %.0fx%.0f scale %.1f drawable %.0fx%.0f gravity %s",
                     m.bounds.size.width, m.bounds.size.height, m.contentsScale, m.drawableSize.width,
                     m.drawableSize.height, m.contentsGravity.UTF8String);
        }
        [todo addObjectsFromArray:l.sublayers ?: @[]];
    }
    [r release];
}
