// PySceneBridge.mm — _paxscene：scene/ui 圖形橋接的 C 側原語
// 節點＝UIView（ShapeNode 用 CAShapeLayer 子類 view、LabelNode 用內含
// UILabel 的容器 view），物件以整數句柄註冊，Python 側 scene.py/ui.py
// 是薄封裝。所有 UI 操作切到主線程（Python 側呼叫時先放掉 GIL 防死鎖）；
// CADisplayLink 在主線程回調場景的 update()（先設 dt／t 屬性）。
#import <Foundation/Foundation.h>
#import <UIKit/UIKit.h>
#import <QuartzCore/QuartzCore.h>
#import <Python/Python.h>

// ---- 句柄註冊表 ----
static NSMutableDictionary<NSNumber *, id> *gReg = nil;
static long gNextHandle = 1;

static NSNumber *regAdd(id obj) {
    if (gReg == nil) gReg = [NSMutableDictionary dictionary];
    NSNumber *key = @(gNextHandle++);
    gReg[key] = obj;
    return key;
}
static id regGet(PyObject *h) {
    long v = PyLong_AsLong(h);
    return gReg[@(v)];
}

// 在主線程執行 block；若在 Python 線程，先放掉 GIL 再等（防與 tick 死鎖）
static void onMainSync(void (^block)(void)) {
    if ([NSThread isMainThread]) { block(); return; }
    Py_BEGIN_ALLOW_THREADS
    dispatch_sync(dispatch_get_main_queue(), block);
    Py_END_ALLOW_THREADS
}

// ---- View 子類 ----
@interface PXShapeView : UIView
@end
@implementation PXShapeView
+ (Class)layerClass { return [CAShapeLayer class]; }
@end

@interface PXLabelView : UIView
@property (nonatomic, strong) UILabel *label;
@end
@implementation PXLabelView
@end

// ---- Path ----
static PyObject *path_oval(PyObject *self, PyObject *args) {
    double x, y, w, h;
    if (!PyArg_ParseTuple(args, "dddd", &x, &y, &w, &h)) return NULL;
    UIBezierPath *p = [UIBezierPath bezierPathWithOvalInRect:CGRectMake(x, y, w, h)];
    return PyLong_FromLong([regAdd(p) longValue]);
}
static PyObject *path_rect(PyObject *self, PyObject *args) {
    double x, y, w, h;
    if (!PyArg_ParseTuple(args, "dddd", &x, &y, &w, &h)) return NULL;
    UIBezierPath *p = [UIBezierPath bezierPathWithRect:CGRectMake(x, y, w, h)];
    return PyLong_FromLong([regAdd(p) longValue]);
}
static PyObject *path_rounded_rect(PyObject *self, PyObject *args) {
    double x, y, w, h, r;
    if (!PyArg_ParseTuple(args, "ddddd", &x, &y, &w, &h, &r)) return NULL;
    UIBezierPath *p = [UIBezierPath bezierPathWithRoundedRect:CGRectMake(x, y, w, h)
                                                 cornerRadius:r];
    return PyLong_FromLong([regAdd(p) longValue]);
}
static PyObject *path_set_line_width(PyObject *self, PyObject *args) {
    PyObject *h; double w;
    if (!PyArg_ParseTuple(args, "Od", &h, &w)) return NULL;
    UIBezierPath *p = regGet(h);
    if (p) p.lineWidth = w;
    Py_RETURN_NONE;
}
static PyObject *path_bounds(PyObject *self, PyObject *args) {
    PyObject *h;
    if (!PyArg_ParseTuple(args, "O", &h)) return NULL;
    UIBezierPath *p = regGet(h);
    CGRect b = p ? p.bounds : CGRectZero;
    return Py_BuildValue("(dddd)", b.origin.x, b.origin.y, b.size.width, b.size.height);
}

// ---- View 原語 ----
static PyObject *view_create(PyObject *self, PyObject *args) {
    int kind;
    if (!PyArg_ParseTuple(args, "i", &kind)) return NULL;
    __block UIView *v = nil;
    onMainSync(^{
        if (kind == 1) v = [[PXShapeView alloc] initWithFrame:CGRectZero];
        else if (kind == 2) v = [[PXLabelView alloc] initWithFrame:CGRectZero];
        else v = [[UIView alloc] initWithFrame:CGRectZero];
        v.backgroundColor = [UIColor clearColor];
    });
    return PyLong_FromLong([regAdd(v) longValue]);
}
static PyObject *view_set_position(PyObject *self, PyObject *args) {
    PyObject *h; double x, y;
    if (!PyArg_ParseTuple(args, "Odd", &h, &x, &y)) return NULL;
    UIView *v = regGet(h);
    onMainSync(^{ if (v) v.center = CGPointMake(x, y); });
    Py_RETURN_NONE;
}
static PyObject *view_set_anchor(PyObject *self, PyObject *args) {
    PyObject *h; double x, y;
    if (!PyArg_ParseTuple(args, "Odd", &h, &x, &y)) return NULL;
    UIView *v = regGet(h);
    onMainSync(^{ if (v) v.layer.anchorPoint = CGPointMake(x, y); });
    Py_RETURN_NONE;
}
static PyObject *view_set_rotation(PyObject *self, PyObject *args) {
    PyObject *h; double r;
    if (!PyArg_ParseTuple(args, "Od", &h, &r)) return NULL;
    UIView *v = regGet(h);
    onMainSync(^{ if (v) v.transform = CGAffineTransformMakeRotation(r); });
    Py_RETURN_NONE;
}
static PyObject *view_set_alpha(PyObject *self, PyObject *args) {
    PyObject *h; double a;
    if (!PyArg_ParseTuple(args, "Od", &h, &a)) return NULL;
    UIView *v = regGet(h);
    onMainSync(^{ if (v) v.alpha = a; });
    Py_RETURN_NONE;
}
static PyObject *view_add_child(PyObject *self, PyObject *args) {
    PyObject *hp, *hc;
    if (!PyArg_ParseTuple(args, "OO", &hp, &hc)) return NULL;
    UIView *p = regGet(hp), *c = regGet(hc);
    onMainSync(^{ if (p && c) [p addSubview:c]; });
    Py_RETURN_NONE;
}
static PyObject *view_remove_from_parent(PyObject *self, PyObject *args) {
    PyObject *h;
    if (!PyArg_ParseTuple(args, "O", &h)) return NULL;
    UIView *v = regGet(h);
    onMainSync(^{ if (v) [v removeFromSuperview]; });
    Py_RETURN_NONE;
}
static PyObject *view_flip_y(PyObject *self, PyObject *args) {
    PyObject *h;
    if (!PyArg_ParseTuple(args, "O", &h)) return NULL;
    UIView *v = regGet(h);
    onMainSync(^{ if (v) v.layer.transform = CATransform3DMakeScale(1, -1, 1); });
    Py_RETURN_NONE;
}

// ---- 顏色 ----
struct PXRgba { CGFloat r, g, b, a; };
static BOOL parseRGBA(PyObject *o, PXRgba &out) {
    if (o == Py_None) return NO;
    if (!PyTuple_Check(o) || PyTuple_Size(o) != 4) return NO;
    CGFloat v[4];
    for (int i = 0; i < 4; i++) v[i] = PyFloat_AsDouble(PyTuple_GetItem(o, i));
    out = {v[0], v[1], v[2], v[3]};
    return YES;
}
static UIColor *colorFromRGBA(const PXRgba &c) {
    return [UIColor colorWithRed:c.r green:c.g blue:c.b alpha:c.a];
}

// ---- Shape ----
static PyObject *shape_set(PyObject *self, PyObject *args) {
    PyObject *h, *ph, *fill, *stroke; double lw;
    if (!PyArg_ParseTuple(args, "OOOOd", &h, &ph, &fill, &stroke, &lw)) return NULL;
    PXShapeView *v = regGet(h);
    UIBezierPath *p = regGet(ph);
    PXRgba fr, sr;
    BOOL hasFill = parseRGBA(fill, fr), hasStroke = parseRGBA(stroke, sr);
    onMainSync(^{
        if (!v || !p) return;
        CAShapeLayer *sl = (CAShapeLayer *)v.layer;
        sl.path = p.CGPath;
        sl.fillColor = hasFill ? colorFromRGBA(fr).CGColor : NULL;
        sl.strokeColor = hasStroke ? colorFromRGBA(sr).CGColor : NULL;
        sl.lineWidth = lw;
        v.bounds = p.bounds;
    });
    Py_RETURN_NONE;
}
static PyObject *shape_set_shadow(PyObject *self, PyObject *args) {
    PyObject *h, *col; double dx, dy, blur;
    if (!PyArg_ParseTuple(args, "OOddd", &h, &col, &dx, &dy, &blur)) return NULL;
    UIView *v = regGet(h);
    PXRgba rgba;
    if (!parseRGBA(col, rgba)) Py_RETURN_NONE;
    onMainSync(^{
        if (!v) return;
        v.layer.shadowColor = colorFromRGBA(rgba).CGColor;
        v.layer.shadowOpacity = (float)rgba.a;
        v.layer.shadowOffset = CGSizeMake(dx, dy);
        v.layer.shadowRadius = blur;
    });
    Py_RETURN_NONE;
}

// ---- Label ----
static PyObject *label_set(PyObject *self, PyObject *args) {
    PyObject *h, *col;
    const char *text, *fontName; double size;
    if (!PyArg_ParseTuple(args, "OssdO", &h, &text, &fontName, &size, &col)) return NULL;
    PXLabelView *v = regGet(h);
    PXRgba rgba;
    BOOL hasCol = parseRGBA(col, rgba);
    NSString *nsText = [NSString stringWithUTF8String:text];
    NSString *nsFont = [NSString stringWithUTF8String:fontName];
    onMainSync(^{
        if (!v) return;
        if (v.label == nil) {
            v.label = [[UILabel alloc] initWithFrame:CGRectZero];
            v.label.textAlignment = NSTextAlignmentCenter;
            // 父層 world 已 y 翻轉，文字再翻一次才正向
            v.label.transform = CGAffineTransformMakeScale(1, -1);
            [v addSubview:v.label];
        }
        UIFont *font = [UIFont fontWithName:nsFont size:size];
        if (font == nil) font = [UIFont systemFontOfSize:size];
        v.label.font = font;
        v.label.text = nsText;
        if (hasCol) v.label.textColor = colorFromRGBA(rgba);
        [v.label sizeToFit];
        CGRect f = v.label.frame;
        v.bounds = CGRectMake(0, 0, ceil(f.size.width), ceil(f.size.height));
        v.label.frame = v.bounds;
    });
    Py_RETURN_NONE;
}
static PyObject *label_set_color(PyObject *self, PyObject *args) {
    PyObject *h, *col;
    if (!PyArg_ParseTuple(args, "OO", &h, &col)) return NULL;
    PXLabelView *v = regGet(h);
    PXRgba rgba;
    if (!parseRGBA(col, rgba)) Py_RETURN_NONE;
    onMainSync(^{ if (v && v.label) v.label.textColor = colorFromRGBA(rgba); });
    Py_RETURN_NONE;
}

// ---- 場景呈現 ----
static PyObject *gSceneObj = NULL;      // 已 INCREF
static CADisplayLink *gLink = nil;
static UIViewController *gSceneVC = nil;
static UIView *gWorldView = nil;
static CGSize gSceneSize = {0, 0};
static NSTimeInterval gLastTs = 0;
static double gSceneT = 0;
static BOOL gSetupDone = NO;
static UIColor *gPendingBG = nil;

static void callSceneNoArg(const char *name) {
    if (gSceneObj == NULL) return;
    PyObject *m = PyObject_GetAttrString(gSceneObj, name);
    if (m == NULL) { PyErr_Clear(); return; }
    if (PyCallable_Check(m)) {
        PyObject *r = PyObject_CallObject(m, NULL);
        if (r == NULL) PyErr_Print();
        Py_XDECREF(r);
    }
    Py_DECREF(m);
}

static void stopSceneInternal(void) {
    [gLink invalidate];
    gLink = nil;
    gSetupDone = NO;
    if (gSceneObj != NULL) {
        PyGILState_STATE gil = PyGILState_Ensure();
        Py_DECREF(gSceneObj);
        gSceneObj = NULL;
        PyGILState_Release(gil);
    }
    gWorldView = nil;
}

@interface PXSceneTicker : NSObject
- (void)onTick:(CADisplayLink *)link;
@end
@implementation PXSceneTicker
- (void)onTick:(CADisplayLink *)link {
    if (gSceneObj == NULL) return;
    NSTimeInterval dt = (gLastTs == 0) ? 0 : (link.timestamp - gLastTs);
    gLastTs = link.timestamp;
    gSceneT += dt;
    PyGILState_STATE gil = PyGILState_Ensure();
    PyObject *dtObj = PyFloat_FromDouble(dt);
    PyObject *tObj = PyFloat_FromDouble(gSceneT);
    PyObject_SetAttrString(gSceneObj, "dt", dtObj);
    PyObject_SetAttrString(gSceneObj, "t", tObj);
    Py_DECREF(dtObj);
    Py_DECREF(tObj);
    PyObject *m = PyObject_GetAttrString(gSceneObj, "update");
    if (m != NULL && PyCallable_Check(m)) {
        PyObject *r = PyObject_CallObject(m, NULL);
        if (r == NULL) {
            PyErr_Print(); // 印到主控台（writer）後停表，避免每幀刷屏
            [gLink invalidate];
            gLink = nil;
        }
        Py_XDECREF(r);
    } else if (m == NULL) {
        PyErr_Clear();
    }
    Py_XDECREF(m);
    PyGILState_Release(gil);
}
@end
static PXSceneTicker *gTicker = nil;

@interface PXSceneViewController : UIViewController
@end
@implementation PXSceneViewController
- (void)viewDidLoad {
    [super viewDidLoad];
    self.view.backgroundColor = gPendingBG ?: [UIColor blackColor];
    UIButton *close = [UIButton buttonWithType:UIButtonTypeCustom];
    [close setTitle:@"✕" forState:UIControlStateNormal];
    [close setTitleColor:[UIColor whiteColor] forState:UIControlStateNormal];
    close.titleLabel.font = [UIFont systemFontOfSize:22];
    close.frame = CGRectMake(self.view.bounds.size.width - 52, 28, 44, 44);
    close.autoresizingMask = UIViewAutoresizingFlexibleLeftMargin;
    [close addTarget:self action:@selector(closeTapped) forControlEvents:UIControlEventTouchUpInside];
    [self.view addSubview:close];
}
- (void)closeTapped {
    UIViewController *vc = gSceneVC;
    stopSceneInternal();
    gSceneVC = nil;
    [vc dismissViewControllerAnimated:YES completion:nil];
}
- (void)viewDidLayoutSubviews {
    [super viewDidLayoutSubviews];
    CGSize sz = self.view.bounds.size;
    if (gWorldView != nil) {
        gWorldView.bounds = CGRectMake(0, 0, sz.width, sz.height);
        gWorldView.layer.position = CGPointMake(sz.width / 2, sz.height / 2);
    }
    BOOL changed = !CGSizeEqualToSize(sz, gSceneSize) && gSceneSize.width != 0;
    gSceneSize = sz;
    if (changed && gSetupDone) {
        PyGILState_STATE gil = PyGILState_Ensure();
        callSceneNoArg("did_change_size");
        PyGILState_Release(gil);
    }
}
- (void)viewDidAppear:(BOOL)animated {
    [super viewDidAppear:animated];
    if (!gSetupDone && gSceneObj != NULL) {
        gSceneSize = self.view.bounds.size;
        PyGILState_STATE gil = PyGILState_Ensure();
        callSceneNoArg("setup");
        PyGILState_Release(gil);
        gSetupDone = YES;
        gLastTs = 0;
        gSceneT = 0;
        if (gTicker == nil) gTicker = [[PXSceneTicker alloc] init];
        gLink = [CADisplayLink displayLinkWithTarget:gTicker selector:@selector(onTick:)];
        [gLink addToRunLoop:[NSRunLoop mainRunLoop] forMode:NSRunLoopCommonModes];
    }
}
@end

static UIViewController *topmostVC(void) {
    UIWindow *win = nil;
    for (UIScene *s in [UIApplication sharedApplication].connectedScenes) {
        if ([s isKindOfClass:[UIWindowScene class]]) {
            for (UIWindow *w in ((UIWindowScene *)s).windows) {
                if (w.isKeyWindow) { win = w; break; }
            }
        }
        if (win) break;
    }
    UIViewController *vc = win.rootViewController;
    while (vc.presentedViewController) vc = vc.presentedViewController;
    return vc;
}

static PyObject *scene_present(PyObject *self, PyObject *args) {
    PyObject *vh, *wh, *obj;
    if (!PyArg_ParseTuple(args, "OOO", &vh, &wh, &obj)) return NULL;
    UIView *rootView = regGet(vh);
    UIView *worldView = regGet(wh);
    Py_INCREF(obj);
    onMainSync(^{
        if (gSceneVC != nil) {
            UIViewController *old = gSceneVC;
            stopSceneInternal();
            gSceneVC = nil;
            [old dismissViewControllerAnimated:NO completion:nil];
        }
        if (gSceneObj != NULL) { // onMainSync 可能已在主線程，stop 內已清；保險再清
            PyGILState_STATE gil = PyGILState_Ensure();
            Py_DECREF(gSceneObj);
            PyGILState_Release(gil);
        }
        gSceneObj = obj;
        gWorldView = worldView;
        PXSceneViewController *vc = [[PXSceneViewController alloc] init];
        gSceneVC = vc;
        rootView.frame = vc.view.bounds;
        rootView.autoresizingMask = UIViewAutoresizingFlexibleWidth | UIViewAutoresizingFlexibleHeight;
        [vc.view insertSubview:rootView atIndex:0];
        UIViewController *top = topmostVC();
        [top presentViewController:vc animated:YES completion:nil];
    });
    Py_RETURN_NONE;
}
static PyObject *scene_set_bg(PyObject *self, PyObject *args) {
    PyObject *h, *col;
    if (!PyArg_ParseTuple(args, "OO", &h, &col)) return NULL;
    PXRgba rgba;
    if (!parseRGBA(col, rgba)) Py_RETURN_NONE;
    onMainSync(^{
        gPendingBG = colorFromRGBA(rgba);
        if (gSceneVC) gSceneVC.view.backgroundColor = gPendingBG;
    });
    Py_RETURN_NONE;
}
static PyObject *screen_size(PyObject *self, PyObject *args) {
    return Py_BuildValue("(dd)", (double)gSceneSize.width, (double)gSceneSize.height);
}

// ---- 模組註冊 ----
static PyMethodDef paxscene_methods[] = {
    {"path_oval", path_oval, METH_VARARGS, ""},
    {"path_rect", path_rect, METH_VARARGS, ""},
    {"path_rounded_rect", path_rounded_rect, METH_VARARGS, ""},
    {"path_set_line_width", path_set_line_width, METH_VARARGS, ""},
    {"path_bounds", path_bounds, METH_VARARGS, ""},
    {"view_create", view_create, METH_VARARGS, ""},
    {"view_set_position", view_set_position, METH_VARARGS, ""},
    {"view_set_anchor", view_set_anchor, METH_VARARGS, ""},
    {"view_set_rotation", view_set_rotation, METH_VARARGS, ""},
    {"view_set_alpha", view_set_alpha, METH_VARARGS, ""},
    {"view_add_child", view_add_child, METH_VARARGS, ""},
    {"view_remove_from_parent", view_remove_from_parent, METH_VARARGS, ""},
    {"view_flip_y", view_flip_y, METH_VARARGS, ""},
    {"shape_set", shape_set, METH_VARARGS, ""},
    {"shape_set_shadow", shape_set_shadow, METH_VARARGS, ""},
    {"label_set", label_set, METH_VARARGS, ""},
    {"label_set_color", label_set_color, METH_VARARGS, ""},
    {"scene_present", scene_present, METH_VARARGS, ""},
    {"scene_set_bg", scene_set_bg, METH_VARARGS, ""},
    {"screen_size", screen_size, METH_NOARGS, ""},
    {NULL, NULL, 0, NULL},
};

static struct PyModuleDef paxscene_module = {
    PyModuleDef_HEAD_INIT, "_paxscene", NULL, -1, paxscene_methods,
};

extern "C" PyObject *PyInit__paxscene(void) {
    return PyModule_Create(&paxscene_module);
}
