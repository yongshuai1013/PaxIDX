#import <UIKit/UIKit.h>
#import <Python/Python.h>

// PaxIDX 的 Python 通用宿主：啟動後以隔離配置初始化包內 CPython，
// PYTHONHOME 指向包內 python/（完整標準庫），執行包根目錄的 main.py，
// 把 stdout/stderr 顯示在畫面上。所有 Python 專案共用這一支二進制，
// 打包時改名為專案的可執行檔名。

@interface ViewController : UIViewController
@end

@implementation ViewController
- (void)viewDidLoad {
    [super viewDidLoad];
    self.view.backgroundColor = [UIColor blackColor];
    UILabel *label = [[UILabel alloc] initWithFrame:self.view.bounds];
    label.numberOfLines = 0;
    label.textColor = [UIColor whiteColor];
    label.font = [UIFont monospacedSystemFontOfSize:14 weight:UIFontWeightRegular];
    label.autoresizingMask = UIViewAutoresizingFlexibleWidth | UIViewAutoresizingFlexibleHeight;
    [self.view addSubview:label];
    label.text = [self runPython];
}

- (NSString *)runPython {
    NSString *resourcePath = [[NSBundle mainBundle] resourcePath];
    NSString *mainPy = [[NSBundle mainBundle] pathForResource:@"main" ofType:@"py"];
    if (mainPy == nil) return @"找不到 main.py";

    PyPreConfig preconfig;
    PyConfig config;
    PyStatus status;
    PyPreConfig_InitIsolatedConfig(&preconfig);
    preconfig.utf8_mode = 1;
    PyConfig_InitIsolatedConfig(&config);
    config.buffered_stdio = 0;
    config.write_bytecode = 0;

    status = Py_PreInitialize(&preconfig);
    if (PyStatus_Exception(status)) {
        return [NSString stringWithFormat:@"PreInitialize 失敗：%s", status.err_msg];
    }
    NSString *home = [resourcePath stringByAppendingPathComponent:@"python"];
    wchar_t *whome = Py_DecodeLocale([home UTF8String], NULL);
    status = PyConfig_SetString(&config, &config.home, whome);
    PyMem_RawFree(whome);
    if (PyStatus_Exception(status)) {
        return [NSString stringWithFormat:@"設定 home 失敗：%s", status.err_msg];
    }
    status = PyConfig_Read(&config);
    if (PyStatus_Exception(status)) {
        return [NSString stringWithFormat:@"讀取配置失敗：%s", status.err_msg];
    }
    char *argv[] = {(char *)"PythonHost"};
    status = PyConfig_SetBytesArgv(&config, 1, argv);
    if (PyStatus_Exception(status)) {
        return [NSString stringWithFormat:@"設定 argv 失敗：%s", status.err_msg];
    }
    status = Py_InitializeFromConfig(&config);
    PyConfig_Clear(&config);
    if (PyStatus_Exception(status)) {
        return [NSString stringWithFormat:@"初始化失敗：%s", status.err_msg];
    }

    PyObject *sysPath = PySys_GetObject("path");
    PyList_Insert(sysPath, 0, PyUnicode_FromString([resourcePath UTF8String]));
    PyRun_SimpleString("import sys, io\nsys.stdout = io.StringIO()\nsys.stderr = sys.stdout\n");

    FILE *f = fopen([mainPy UTF8String], "r");
    int rc = f ? PyRun_SimpleFileEx(f, "main.py", 1) : -1;

    NSString *text = @"(無輸出)";
    PyObject *out = PySys_GetObject("stdout");
    PyObject *val = out ? PyObject_CallMethod(out, "getvalue", NULL) : NULL;
    const char *s = val ? PyUnicode_AsUTF8(val) : NULL;
    if (s != NULL && s[0] != '\0') text = [NSString stringWithUTF8String:s];
    if (rc != 0) text = [text stringByAppendingString:@"\n[main.py 以錯誤結束]"];
    Py_Finalize();
    return text;
}
@end

@interface AppDelegate : UIResponder <UIApplicationDelegate>
@property (nonatomic, strong) UIWindow *window;
@end

@implementation AppDelegate
- (BOOL)application:(UIApplication *)application
    didFinishLaunchingWithOptions:(NSDictionary *)launchOptions {
    self.window = [[UIWindow alloc] initWithFrame:[UIScreen mainScreen].bounds];
    self.window.rootViewController = [[ViewController alloc] init];
    [self.window makeKeyAndVisible];
    return YES;
}
@end

int main(int argc, char *argv[]) {
    @autoreleasepool {
        return UIApplicationMain(argc, argv, nil, NSStringFromClass([AppDelegate class]));
    }
}
