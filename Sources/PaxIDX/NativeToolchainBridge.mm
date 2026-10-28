// PaxIDX 工具鏈橋接（App 端）：dlopen 載入 dylib 轉發
// 啟動時不載入 LLVM，點編譯時才 dlopen Documents/Toolchain/ 下的 dylib
// dylib 由 ToolchainManager 從 release 下載
#include "NativeToolchainBridge.h"

#include <Foundation/Foundation.h>
#include <dlfcn.h>
#include <execinfo.h>
#include <signal.h>
#include <mach/mach.h>
#include <dispatch/dispatch.h>
#include <string>
#include <atomic>
#include <cstring>
#include <unistd.h>
#include <fcntl.h>

namespace {

// 最後一次 dlopen 的錯誤文字（給診斷用）
static std::string g_dlopen_error;

// dylib 路徑：優先 App bundle 的 Frameworks（跟 App 一起簽名，可 dlopen）
// 備用 Documents/Toolchain（舊下載路徑，簽名問題可能載入失敗）
void *toolchainHandle() {
    static void *handle = nullptr;
    static dispatch_once_t once;
    dispatch_once(&once, ^{
        // 1. Bundle Frameworks
        NSString *bundlePath = [[[NSBundle mainBundle] bundlePath]
            stringByAppendingPathComponent:@"Frameworks/libPaxIDXNativeToolchain.dylib"];
        dlerror();
        handle = dlopen([bundlePath UTF8String], RTLD_NOW);
        if (handle) return;
        const char *e1 = dlerror();
        // 2. Documents/Toolchain
        NSArray<NSString *> *docs = NSSearchPathForDirectoriesInDomains(
            NSDocumentDirectory, NSUserDomainMask, YES);
        NSString *docPath = [[docs[0] stringByAppendingPathComponent:@"Toolchain"]
                          stringByAppendingPathComponent:@"libPaxIDXNativeToolchain.dylib"];
        if (![[NSFileManager defaultManager] fileExistsAtPath:docPath]) {
            g_dlopen_error = "文件不存在: bundle(";
            g_dlopen_error += e1 ? e1 : "未知";
            g_dlopen_error += ")";
            return;
        }
        dlerror();
        handle = dlopen([docPath UTF8String], RTLD_NOW);
        if (!handle) {
            const char *e2 = dlerror();
            g_dlopen_error = "bundle: ";
            g_dlopen_error += e1 ? e1 : "未知";
            g_dlopen_error += "; documents: ";
            g_dlopen_error += e2 ? e2 : "未知";
        }
    });
    return handle;
}

// Swift dylib：優先 App 內 Frameworks（跟 App 一起簽名，可 dlopen），
// 其次 Documents/Toolchain 下載版（可獨立更新）。
// 注意：不用 dispatch_once——失敗不能緩存，否則「先按編譯、後下載」就永遠失敗。
void *swiftToolchainHandle() {
    static void *handle = nullptr;
    if (handle) return handle;
    dlerror();
    // 1. App bundle Frameworks
    NSString *fw = [[[NSBundle mainBundle] privateFrameworksPath]
                    stringByAppendingPathComponent:@"libPaxIDXSwiftToolchain.dylib"];
    if ([[NSFileManager defaultManager] fileExistsAtPath:fw]) {
        handle = dlopen([fw UTF8String], RTLD_NOW);
        if (handle) return handle;
    }
    // 2. Documents 下載版
    NSArray<NSString *> *docs = NSSearchPathForDirectoriesInDomains(
        NSDocumentDirectory, NSUserDomainMask, YES);
    NSString *docPath = [[docs[0] stringByAppendingPathComponent:@"Toolchain"]
                      stringByAppendingPathComponent:@"libPaxIDXSwiftToolchain.dylib"];
    if (![[NSFileManager defaultManager] fileExistsAtPath:docPath]) {
        return nullptr;
    }
    handle = dlopen([docPath UTF8String], RTLD_NOW);
    if (!handle) {
        const char *e = dlerror();
        g_dlopen_error = e ? e : "Swift dylib 載入失敗";
    }
    return handle;
}

// 任一 dylib 有 Swift 編譯入口即視為 Swift 可用
// （主 dylib 是 C 版時沒有前端，走 Swift dylib；若主 dylib 換成 Swift 版也能用）
static void *swiftCapableHandle() {
    void *h = swiftToolchainHandle();
    if (h && dlsym(h, "paxidx_dylib_swift_compile")) return h;
    h = toolchainHandle();
    if (h && dlsym(h, "paxidx_dylib_swift_compile")) return h;
    return nullptr;
}

void copyDiag(const char *value, char *buffer, size_t capacity) {
    if (!buffer || capacity == 0) return;
    size_t n = strlen(value);
    if (n > capacity - 1) n = capacity - 1;
    memcpy(buffer, value, n);
    buffer[n] = '\0';
}

} // namespace

extern "C" int paxidx_toolchain_available(void) {
    return toolchainHandle() ? 1 : 0;
}

extern "C" int paxidx_swift_toolchain_available(void) {
    return swiftToolchainHandle() ? 1 : 0;
}

extern "C" int paxidx_swift_available(void) {
    return swiftCapableHandle() ? 1 : 0;
}

extern "C" int paxidx_toolchain_error(char *buffer, size_t capacity) {
    // 觸發一次載入（確保 g_dlopen_error 已填）
    toolchainHandle();
    copyDiag(g_dlopen_error.c_str(), buffer, capacity);
    return 0;
}

extern "C" int paxidx_clang_compile(int argc, const char * const *argv,
                                    char *diagnostics, size_t diagnostics_capacity) {
    void *h = toolchainHandle();
    if (!h) {
        copyDiag("工具鏈未下載（到設定頁下載工具鏈）", diagnostics, diagnostics_capacity);
        return 1;
    }
    typedef int (*fn_t)(int, const char * const *, char *, size_t);
    fn_t f = (fn_t)dlsym(h, "paxidx_dylib_clang_compile");
    if (!f) {
        copyDiag("dylib 缺 paxidx_dylib_clang_compile", diagnostics, diagnostics_capacity);
        return 1;
    }
    return f(argc, argv, diagnostics, diagnostics_capacity);
}

extern "C" int paxidx_ld_link(int argc, const char * const *argv,
                              char *diagnostics, size_t diagnostics_capacity) {
    void *h = toolchainHandle();
    if (!h) {
        copyDiag("工具鏈未下載（到設定頁下載工具鏈）", diagnostics, diagnostics_capacity);
        return 1;
    }
    typedef int (*fn_t)(int, const char * const *, char *, size_t);
    fn_t f = (fn_t)dlsym(h, "paxidx_dylib_ld_link");
    if (!f) {
        copyDiag("dylib 缺 paxidx_dylib_ld_link", diagnostics, diagnostics_capacity);
        return 1;
    }
    return f(argc, argv, diagnostics, diagnostics_capacity);
}

extern "C" int paxidx_swift_compile(int argc, const char * const *argv,
                                    char *diagnostics, size_t diagnostics_capacity) {
    void *h = swiftCapableHandle();
    if (!h) {
        copyDiag("Swift 工具鏈未下載（到設定頁下載 Swift 工具鏈）", diagnostics, diagnostics_capacity);
        return 1;
    }
    typedef int (*fn_t)(int, const char * const *, char *, size_t);
    fn_t f = (fn_t)dlsym(h, "paxidx_dylib_swift_compile");
    if (!f) {
        copyDiag("dylib 不是 Swift 版（缺 paxidx_dylib_swift_compile）", diagnostics, diagnostics_capacity);
        return 1;
    }
    // 抓 stderr：performFrontend 的真診斷寫到 stderr，不是我們的 buffer
    int pipefd[2];
    if (pipe(pipefd) != 0) {
        return f(argc, argv, diagnostics, diagnostics_capacity);
    }
    // 設非阻塞，防讀卡住
    fcntl(pipefd[0], F_SETFL, O_NONBLOCK);
    int saved_stderr = dup(STDERR_FILENO);
    dup2(pipefd[1], STDERR_FILENO);

    int rc = f(argc, argv, diagnostics, diagnostics_capacity);

    // 恢復 stderr
    fflush(stderr);
    dup2(saved_stderr, STDERR_FILENO);
    close(saved_stderr);
    close(pipefd[1]);

    // 讀 pipe
    std::string captured;
    char buf[4096];
    ssize_t n;
    while ((n = read(pipefd[0], buf, sizeof(buf) - 1)) > 0) {
        buf[n] = '\0';
        captured += buf;
        if (captured.size() > 8192) break;
    }
    close(pipefd[0]);

    if (!captured.empty() && diagnostics && diagnostics_capacity > 0) {
        // 拼到診斷後面
        size_t cur = strlen(diagnostics);
        size_t remain = diagnostics_capacity > cur + 1 ? diagnostics_capacity - cur - 1 : 0;
        if (remain > 0) {
            strncat(diagnostics, "\n[stderr]\n", remain);
            cur = strlen(diagnostics);
            remain = diagnostics_capacity > cur + 1 ? diagnostics_capacity - cur - 1 : 0;
            strncat(diagnostics, captured.c_str(), remain);
        }
    }
    return rc;
}

// Nyxian CoreCompiler 載入實測（實驗，2026-10-26）：把 nyx_test 實驗包
// 內嵌的 CoreCompiler.framework（minos 已由 CI 改戳記為 15.0）用
// dlopen(RTLD_NOW) 真載入一次，驗證 dyld 在 iOS 15 上的接受程度與
// 全體初始化是否跑得完；再讀它導出的版本符號、並試載一支附屬
// SwiftSyntax dylib。結果以多行文字寫入 buffer（換行分隔）。
extern "C" int paxidx_nyx_dlopen_test(char *buffer, size_t capacity) {
    std::string report;
    auto line = [&](const std::string &t) { report += t; report += "\n"; };
    NSString *fwPath = [[[NSBundle mainBundle] bundlePath]
        stringByAppendingPathComponent:@"Frameworks/CoreCompiler.framework/CoreCompiler"];
    if (![[NSFileManager defaultManager] fileExistsAtPath:fwPath]) {
        line("未內嵌 CoreCompiler.framework（這不是 nyx_test 實驗包）");
        copyDiag(report.c_str(), buffer, capacity);
        return 2;
    }
    line("目標：" + std::string(fwPath.UTF8String));
    dlerror();
    void *h = dlopen(fwPath.UTF8String, RTLD_NOW | RTLD_GLOBAL);
    if (!h) {
        const char *e = dlerror();
        line(std::string("dlopen 失敗：") + (e ? e : "(無錯誤文字)"));
        copyDiag(report.c_str(), buffer, capacity);
        return 1;
    }
    line("dlopen 成功：CoreCompiler 已載入並完成初始化");
    if (const char *vs = (const char *)dlsym(h, "_CoreCompilerVersionString"))
        line(std::string("CoreCompilerVersionString = ") + vs);
    else
        line("_CoreCompilerVersionString 未找到");
    if (double *vn = (double *)dlsym(h, "_CoreCompilerVersionNumber"))
        line("CoreCompilerVersionNumber = " + std::to_string(*vn));
    line(dlsym(h, "_LLVMInitializeAArch64Target") ? "_LLVMInitializeAArch64Target 在位"
                                                  : "_LLVMInitializeAArch64Target 未找到");
    NSString *syntaxPath = [[fwPath stringByDeletingLastPathComponent]
        stringByAppendingPathComponent:@"Frameworks/lib_CompilerSwiftSyntax.dylib"];
    dlerror();
    void *h2 = dlopen(syntaxPath.UTF8String, RTLD_NOW | RTLD_GLOBAL);
    if (h2)
        line("附屬 lib_CompilerSwiftSyntax.dylib dlopen 成功");
    else {
        const char *e = dlerror();
        line(std::string("附屬 lib_CompilerSwiftSyntax.dylib dlopen 失敗：") + (e ? e : "(無錯誤文字)"));
    }
    copyDiag(report.c_str(), buffer, capacity);
    return 0;
}

// Nyxian CoreCompiler 試編（實驗，2026-10-27）：介面照 emexlab/Nyxian
// 開源源碼（Frameworks/CoreCompiler 的 CCJob.h／CCDriver.h／
// CCDiagnostic.h 與 MobileDevelopmentKit 的 MDKJob.m 用法）：
// dlopen 後以 dlsym（Darwin 不帶底線）取 C API，建 clang driver
// （引數比照一般 clang 命令行），由 driver 產 job 後逐個執行，
// 診斷以 CCDiagnostic 存取器讀出。範例 C 檔寫入 App 暫存目錄，
// SDK 用 App 已下載的那份（Documents/SDK/iPhoneOS.sdk）。

// 試編步驟進度（崩潰定位）：每過一步就把標記 append 到
// Documents/nyx-progress.txt 並 fflush；若中途閃退，App 重開後
// 由實測頁讀出，即可知死在哪一步。
static NSString *nyxProgressPath(void) {
    return [NSHomeDirectory() stringByAppendingPathComponent:@"Documents/nyx-progress.txt"];
}
static void nyxMark(const char *step) {
    FILE *f = fopen(nyxProgressPath().UTF8String, "a");
    if (f) { fputs(step, f); fputc('\n', f); fflush(f); fclose(f); }
}
extern "C" int paxidx_nyx_progress(char *buffer, size_t capacity) {
    NSString *content = [NSString stringWithContentsOfFile:nyxProgressPath()
                                                  encoding:NSUTF8StringEncoding error:nil];
    copyDiag(content ? content.UTF8String : "（無進度記錄）", buffer, capacity);
    return 0;
}


// 訊號捕捉（崩潰定位）：在試編開始時裝上，命中時把訊號編號與
// backtrace 直接寫進進度檔再退出，讓下一次開 App 就能讀到死點。
static char g_nyxProgressCPath[1024] = {0};
static void nyxSigHandler(int sig, siginfo_t *info, void *uctx) {
    (void)uctx;
    int fd = open(g_nyxProgressCPath, O_WRONLY | O_APPEND | O_CREAT, 0644);
    if (fd >= 0) {
        char line[160];
        int n = snprintf(line, sizeof(line), "SIGNAL %d addr=%p\n", sig,
                         info ? info->si_addr : nullptr);
        if (n > 0) (void)!write(fd, line, (size_t)n);
        void *bt[48];
        int frames = backtrace(bt, 48);
        if (frames > 0) backtrace_symbols_fd(bt, frames, fd);
        close(fd);
    }
    _exit(128 + sig);
}
static void nyxInstallSigHandlers(void) {
    strncpy(g_nyxProgressCPath, nyxProgressPath().UTF8String, sizeof(g_nyxProgressCPath) - 1);
    struct sigaction sa;
    memset(&sa, 0, sizeof(sa));
    sa.sa_sigaction = nyxSigHandler;
    sa.sa_flags = SA_SIGINFO;
    sigemptyset(&sa.sa_mask);
    const int sigs[] = {SIGSEGV, SIGABRT, SIGBUS, SIGILL, SIGTRAP};
    for (size_t i = 0; i < sizeof(sigs) / sizeof(sigs[0]); i++) sigaction(sigs[i], &sa, nullptr);
}


// 零初始化分配器（對付 CoreCompiler 的 CCDriverInit 未構建
// argStorage/argPtr 的原廠 bug）：CCDriverCreate 用我們傳入的
// allocator 分配 driver 物件，改用 calloc 後物件記憶體全零，
// 未構建的 SmallVector 以零狀態被 move-assign／grow 時行為正常。
static void *nyxCallocAllocate(CFIndex size, CFOptionFlags hint, void *info) {
    (void)hint; (void)info;
    return calloc(1, size > 0 ? (size_t)size : 1);
}
static void *nyxRealloc(void *ptr, CFIndex newSize, CFOptionFlags hint, void *info) {
    (void)hint; (void)info;
    return realloc(ptr, newSize > 0 ? (size_t)newSize : 1);
}
static void nyxFree(void *ptr, void *info) { (void)info; free(ptr); }
static CFIndex nyxPreferredSize(CFIndex size, CFOptionFlags hint, void *info) {
    (void)hint; (void)info;
    return size;
}
static CFAllocatorRef nyxZeroAllocator(void) {
    CFAllocatorContext ctx;
    memset(&ctx, 0, sizeof(ctx));
    ctx.version = 0;
    ctx.allocate = nyxCallocAllocate;
    ctx.reallocate = nyxRealloc;
    ctx.deallocate = nyxFree;
    ctx.preferredSize = nyxPreferredSize;
    return CFAllocatorCreate(kCFAllocatorSystemDefault, &ctx);
}

typedef struct __CCJob *CCJobRef2;
typedef struct __CCDriver *CCDriverRef2;
typedef struct __CCDiagnostic *CCDiagnosticRef2;
typedef CCDriverRef2 (*CCDriverCreateFn)(CFAllocatorRef, CFArrayRef, uint8_t);
typedef CFArrayRef (*CCDriverCreateJobsFn)(CFAllocatorRef, CCDriverRef2);
typedef Boolean (*CCJobExecuteJobFn)(CCJobRef2, CFArrayRef *, CFStringRef *);
typedef uint8_t (*CCDiagnosticGetLevelFn)(CCDiagnosticRef2);
typedef CFStringRef (*CCDiagnosticGetMessageFn)(CCDiagnosticRef2);
typedef CFURLRef (*CCJobGetOutputFileURLFn)(CCJobRef2);
typedef CCJobRef2 (*CCJobCreateFn)(CFAllocatorRef, uint8_t, CFArrayRef);
typedef CFURLRef (*CCDriverCopySysrootURLFn)(CCDriverRef2);
typedef CFArrayRef (*CCJobCreateArgumentsFn)(CFAllocatorRef, CCJobRef2);
typedef CFArrayRef (*CCJobGetBaseArgumentsFn)(CCJobRef2);
typedef CFArrayRef (*CCJobGetInputFileURLsFn)(CCJobRef2);
typedef uint8_t (*CCJobGetTypeFn)(CCJobRef2);

extern "C" int paxidx_nyx_compile_test(char *buffer, size_t capacity) {
    static std::atomic<bool> s_running{false};
    if (s_running.exchange(true)) {
        const char *msg = "已有一次試編正在執行，本次點擊已忽略\n";
        size_t n = strlen(msg);
        if (n >= capacity) n = capacity - 1;
        memcpy(buffer, msg, n);
        buffer[n] = '\0';
        return 2;
    }
    struct RunningGuard { std::atomic<bool> &f; ~RunningGuard() { f.store(false); } } guard{s_running};
    std::string report;
    auto line = [&](const std::string &t) { report += t; report += "\n"; };
    { FILE *f = fopen(nyxProgressPath().UTF8String, "w"); if (f) fclose(f); }
    nyxInstallSigHandlers();
    // 把 stderr 直接接到進度檔（O_APPEND）：LLVM 的 fatal error 訊息
    // （bad_alloc 的原因字串）會在 abort 前寫到 errs()，落盤才看得到
    {
        int fd = open(nyxProgressPath().UTF8String, O_WRONLY | O_APPEND | O_CREAT, 0644);
        if (fd >= 0) { dup2(fd, 2); close(fd); }
    }
    nyxMark("start");
    NSFileManager *fm = [NSFileManager defaultManager];
    NSString *fwPath = [[[NSBundle mainBundle] bundlePath]
        stringByAppendingPathComponent:@"Frameworks/CoreCompiler.framework/CoreCompiler"];
    if (![fm fileExistsAtPath:fwPath]) {
        line("未內嵌 CoreCompiler.framework（這不是 nyx_test 實驗包）");
        copyDiag(report.c_str(), buffer, capacity);
        return 2;
    }
    void *h = dlopen(fwPath.UTF8String, RTLD_NOW | RTLD_GLOBAL);
    if (!h) {
        const char *e = dlerror();
        line(std::string("dlopen 失敗：") + (e ? e : "(無錯誤文字)"));
        copyDiag(report.c_str(), buffer, capacity);
        return 1;
    }
    nyxMark("dlopen ok");
    auto sym = [&](const char *name) -> void * {
        void *p = dlsym(h, name);
        if (!p) line(std::string("缺符號：") + name);
        return p;
    };
    auto pDriverCreate = (CCDriverCreateFn)sym("CCDriverCreate");
    auto pDriverJobs = (CCDriverCreateJobsFn)sym("CCDriverCreateJobs");
    auto pJobExecute = (CCJobExecuteJobFn)sym("CCJobExecuteJob");
    auto pDiagLevel = (CCDiagnosticGetLevelFn)sym("CCDiagnosticGetLevel");
    auto pDiagMessage = (CCDiagnosticGetMessageFn)sym("CCDiagnosticGetMessage");
    auto pJobOutput = (CCJobGetOutputFileURLFn)sym("CCJobGetOutputFileURL");
    auto pJobCreate = (CCJobCreateFn)sym("CCJobCreate");
    auto pDriverSysroot = (CCDriverCopySysrootURLFn)sym("CCDriverCopySysrootURL");
    auto pJobArgs = (CCJobCreateArgumentsFn)sym("CCJobCreateArguments");
    auto pJobBase = (CCJobGetBaseArgumentsFn)sym("CCJobGetBaseArguments");
    auto pJobInputs = (CCJobGetInputFileURLsFn)sym("CCJobGetInputFileURLs");
    auto pJobType = (CCJobGetTypeFn)sym("CCJobGetType");
    nyxMark("symbols ok");
    if (!pDriverCreate || !pDriverJobs || !pJobExecute) {
        copyDiag(report.c_str(), buffer, capacity);
        return 1;
    }
    NSString *sdk = [NSHomeDirectory() stringByAppendingPathComponent:@"Documents/SDK/iPhoneOS.sdk"];
    if (![fm fileExistsAtPath:sdk]) {
        line("SDK 未安裝（Documents/SDK/iPhoneOS.sdk 不存在），先到設定頁下載 SDK");
        copyDiag(report.c_str(), buffer, capacity);
        return 1;
    }
    NSString *dir = [NSTemporaryDirectory() stringByAppendingPathComponent:@"nyxtest"];
    [fm createDirectoryAtPath:dir withIntermediateDirectories:YES attributes:nil error:nil];
    NSString *src = [dir stringByAppendingPathComponent:@"test.c"];
    NSString *obj = [dir stringByAppendingPathComponent:@"test.o"];
    [fm removeItemAtPath:obj error:nil];
    NSString *code = @"#include <stdio.h>\nint main(void) { printf(\"nyx ok\\n\"); return 42; }\n";
    [code writeToFile:src atomically:YES encoding:NSUTF8StringEncoding error:nil];
    {
        NSDictionary *attr = [fm attributesOfItemAtPath:src error:nil];
        char b[96];
        snprintf(b, sizeof(b), "src size=%lld stdioInSdk=%d", attr ? [attr fileSize] : -1LL,
                 [fm fileExistsAtPath:[sdk stringByAppendingPathComponent:@"usr/include/stdio.h"]] ? 1 : 0);
        nyxMark(b);
    }
    line("源文件：" + std::string(src.UTF8String));
    line("SDK：" + std::string(sdk.UTF8String));
    // driver 層已移除：CCDriverCreateJobs 對我們的參數恆產 0 job，
    // 且其未構建 SmallVector bug 有機率在 CreateJobs 內 abort
    // （#106 真機在 CreateJobs+124 閃退實證）。直打 CCJob 路徑已證明
    // 完整可用（C/ObjC 皆可編），driver 層不再碰。
    nyxMark("driver skipped");
    line("driver 層已略過（恆 0 job 且有閃退風險），直接走 CCJob");
    static const char *kLevelNames[] = {"note", "remark", "warning", "error", "fatal", "unknown"};
    bool ok = false;
    // 直打 CCJob 探針 v2：A=帶 -cc1＋故意寫錯的源碼（驗前端是否真解析，
    // 真解析必回錯誤診斷）；B=不帶 -cc1＋正確源碼（驗 CreateFromArgs 契約
    // 與 .o 產出）。兩邊都先印出 CCJobCreateArguments 組出的最終 argv。
    if (pJobCreate) {
        nyxMark("direct v2 start");
        NSString *errSrc = [dir stringByAppendingPathComponent:@"testerr.c"];
        [@"int main(void) { return oops }\n" writeToFile:errSrc atomically:YES encoding:NSUTF8StringEncoding error:nil];
        auto runJob = [&](NSArray *fullArgs, const char *tag) {
            // 0.11.4 契約：job 只存一份完整 argv（就是 driver 命令的原樣，
            // 含 -o 與輸入檔），CCJobGetArguments 原樣交給 CreateFromArgs。
            CCJobRef2 job = pJobCreate(nyxZeroAllocator(), 0, (__bridge CFArrayRef)fullArgs);
            if (!job) { line(std::string(tag) + "：CCJobCreate 回傳空"); return; }
            if (pJobType) { char b[32]; snprintf(b, sizeof(b), "%s type=%d", tag, (int)pJobType(job)); line(b); }
            CFArrayRef diags = NULL;
            CFStringRef mainSrc = NULL;
            CFAbsoluteTime t0 = CFAbsoluteTimeGetCurrent();
            Boolean success = pJobExecute(job, &diags, &mainSrc);
            CFAbsoluteTime dt = CFAbsoluteTimeGetCurrent() - t0;
            line(std::string(tag) + " 執行結果：" + (success ? "成功" : "失敗"));
            { char b[64]; snprintf(b, sizeof(b), "%s 耗時 %.0f ms", tag, dt * 1000.0); line(b); }
            if (mainSrc) {
                line(std::string(tag) + " mainSource=" + ((__bridge NSString *)mainSrc).UTF8String);
            } else {
                line(std::string(tag) + " mainSource=(null)");
            }
            line(std::string(tag) + (diags ? " diag 數：" + std::to_string((long)CFArrayGetCount(diags)) : " diag 陣列=NULL"));
            if (diags && pDiagLevel && pDiagMessage) {
                CFIndex nd = CFArrayGetCount(diags);
                for (CFIndex d = 0; d < nd; d++) {
                    CCDiagnosticRef2 dg = (CCDiagnosticRef2)CFArrayGetValueAtIndex(diags, d);
                    uint8_t lv = pDiagLevel(dg);
                    CFStringRef msg = pDiagMessage(dg);
                    std::string m = msg ? ([(__bridge NSString *)msg UTF8String] ?: "") : "";
                    line(std::string("  diag[") + kLevelNames[lv <= 5 ? lv : 5] + "] " + m);
                }
            }
            if (diags) CFRelease(diags);
            if (mainSrc) CFRelease(mainSrc);
            CFRelease(job);
        };
        auto cArgs = [&](NSString *srcPath, NSString *objPath) {
            return @[@"-cc1", @"-triple", @"arm64-apple-ios15.0", @"-emit-obj",
                @"-main-file-name", [srcPath lastPathComponent], @"-isysroot", sdk,
                @"-internal-isystem", [sdk stringByAppendingPathComponent:@"usr/include"],
                @"-internal-externc-isystem", [sdk stringByAppendingPathComponent:@"usr/include"],
                @"-o", objPath, @"-x", @"c", srcPath];
        };
        runJob(cArgs(errSrc, [dir stringByAppendingPathComponent:@"testerr.o"]), "A(錯誤源碼)");
        runJob(cArgs([dir stringByAppendingPathComponent:@"nope_missing.c"], [dir stringByAppendingPathComponent:@"nope.o"]), "C(不存在的輸入檔)");
        runJob(cArgs(src, obj), "B(正確源碼)");
        // D：ObjC＋Foundation 頭——-x objective-c、-F 框架搜尋路徑、objc runtime
        NSString *msrc = [dir stringByAppendingPathComponent:@"test.m"];
        NSString *mobj = [dir stringByAppendingPathComponent:@"testobjc.o"];
        [@"#import <Foundation/Foundation.h>\nint main(void) { @autoreleasepool { NSString *s = @\"hi\"; NSLog(@\"%@\", s); } return 0; }\n"
            writeToFile:msrc atomically:YES encoding:NSUTF8StringEncoding error:nil];
        NSString *fw = [sdk stringByAppendingPathComponent:@"System/Library/Frameworks"];
        // resource-dir 實地探測：列出 usr/lib/clang 下的版本目錄，找第一個
        // include/stdarg.h 真實存在的；也探 swift 鏡像佈局。印出來對帳。
        NSString *resourceDir = nil;
        {
            NSString *clangBase = [sdk stringByAppendingPathComponent:@"usr/lib/clang"];
            NSArray *vers = [fm contentsOfDirectoryAtPath:clangBase error:nil];
            line("usr/lib/clang 目錄內容：" + std::string(vers ? [[vers componentsJoinedByString:@", "] UTF8String] : "(讀不到)"));
            for (NSString *v in vers ?: @[]) {
                NSString *cand = [clangBase stringByAppendingPathComponent:v];
                if ([fm fileExistsAtPath:[cand stringByAppendingPathComponent:@"include/stdarg.h"]]) { resourceDir = cand; break; }
            }
            if (!resourceDir) {
                NSString *mirror = [sdk stringByAppendingPathComponent:@"usr/lib/swift/clang"];
                if ([fm fileExistsAtPath:[mirror stringByAppendingPathComponent:@"include/stdarg.h"]]) resourceDir = mirror;
            }
            line("resource-dir 選用：" + std::string(resourceDir ? resourceDir.UTF8String : "(無可用內建頭)"));
        }
        NSArray *objcArgs = @[@"-cc1", @"-triple", @"arm64-apple-ios15.0", @"-emit-obj",
            @"-main-file-name", @"test.m", @"-isysroot", sdk,
            @"-internal-isystem", [sdk stringByAppendingPathComponent:@"usr/include"],
            @"-internal-externc-isystem", [sdk stringByAppendingPathComponent:@"usr/include"],
            [@"-F" stringByAppendingString:fw],
            @"-resource-dir", resourceDir ?: [sdk stringByAppendingPathComponent:@"usr/lib/clang/19.1.5"],
            @"-internal-isystem", [(resourceDir ?: [sdk stringByAppendingPathComponent:@"usr/lib/clang/19.1.5"]) stringByAppendingPathComponent:@"include"],
            @"-D__GNUC__=4", @"-D__GNUC_MINOR__=2", @"-D__GNUC_PATCHLEVEL__=1",
            @"-fblocks",
            @"-fobjc-runtime=ios-15.0",
            @"-o", mobj, @"-x", @"objective-c", msrc];
        runJob(objcArgs, "D(ObjC+Foundation)");
        if ([fm fileExistsAtPath:mobj]) {
            unsigned long long sz = [[fm attributesOfItemAtPath:mobj error:nil] fileSize];
            line("產物 testobjc.o 已生成，大小 " + std::to_string(sz) + " 位元組");
        } else {
            line("產物 testobjc.o 不存在");
        }
        // ---- 探針 E：預定義宏實況（#error 標記，diag 直接拼出缺哪個宏） ----
    {
        NSString *esrc = [dir stringByAppendingPathComponent:@"probe.m"];
        NSString *eobj = [dir stringByAppendingPathComponent:@"probe.o"];
        NSString *es = @"#ifndef __GNUC__\n#error PROBE_GNUC_MISSING\n#elif __GNUC__ < 4\n#error PROBE_GNUC_LT4\n#endif\n"
                       @"#ifndef __clang__\n#error PROBE_CLANG_MISSING\n#endif\n"
                       @"#ifndef __APPLE__\n#error PROBE_APPLE_MISSING\n#endif\n"
                       @"#ifndef __MACH__\n#error PROBE_MACH_MISSING\n#endif\n"
                       @"#ifndef __OBJC__\n#error PROBE_OBJC_MISSING\n#endif\n"
                       @"int probe_dummy;\n";
        [es writeToFile:esrc atomically:YES encoding:NSUTF8StringEncoding error:nil];
        NSArray *probeArgs = @[@"-cc1", @"-triple", @"arm64-apple-ios15.0", @"-emit-obj",
            @"-main-file-name", @"probe.m", @"-isysroot", sdk,
            @"-internal-isystem", [sdk stringByAppendingPathComponent:@"usr/include"],
            @"-internal-externc-isystem", [sdk stringByAppendingPathComponent:@"usr/include"],
            @"-fobjc-runtime=ios-15.0",
            @"-o", eobj, @"-x", @"objective-c", esrc];
        runJob(probeArgs, "E(預定義宏探針)");
        }
        // ---- F：連結 job（type=4，CCLinkerJobExecute -> lld::lldMain Darwin） ----
        // 0.11.4 契約：argv 是 ld64.lld 參數（argv[0] 由對方注入），診斷是
        // 一條裝著整份 lld stderr 的 CCDiagnostic。
        {
            auto runLinkJob = [&](NSArray *fullArgs, const char *tag) {
                CCJobRef2 job = pJobCreate(nyxZeroAllocator(), 4, (__bridge CFArrayRef)fullArgs);
                if (!job) { line(std::string(tag) + "：CCJobCreate 回傳空"); return; }
                if (pJobType) { char b[32]; snprintf(b, sizeof(b), "%s type=%d", tag, (int)pJobType(job)); line(b); }
                CFArrayRef diags = NULL;
                CFStringRef mainSrc = NULL;
                CFAbsoluteTime t0 = CFAbsoluteTimeGetCurrent();
                Boolean success = pJobExecute(job, &diags, &mainSrc);
                CFAbsoluteTime dt = CFAbsoluteTimeGetCurrent() - t0;
                line(std::string(tag) + " 執行結果：" + (success ? "成功" : "失敗"));
                { char b[64]; snprintf(b, sizeof(b), "%s 耗時 %.0f ms", tag, dt * 1000.0); line(b); }
                line(std::string(tag) + (diags ? " diag 數：" + std::to_string((long)CFArrayGetCount(diags)) : " diag 陣列=NULL"));
                if (diags && pDiagLevel && pDiagMessage) {
                    CFIndex nd = CFArrayGetCount(diags);
                    for (CFIndex d = 0; d < nd; d++) {
                        CCDiagnosticRef2 dg = (CCDiagnosticRef2)CFArrayGetValueAtIndex(diags, d);
                        uint8_t lv = pDiagLevel(dg);
                        CFStringRef msg = pDiagMessage(dg);
                        std::string m = msg ? ([(__bridge NSString *)msg UTF8String] ?: "") : "";
                        line(std::string("  diag[") + kLevelNames[lv <= 5 ? lv : 5] + "] " + m);
                    }
                }
                if (diags) CFRelease(diags);
                if (mainSrc) CFRelease(mainSrc);
                CFRelease(job);
            };
            NSString *fwDir = [sdk stringByAppendingPathComponent:@"System/Library/Frameworks"];
            NSString *cApp = [dir stringByAppendingPathComponent:@"testc_app"];
            runLinkJob(@[@"-arch", @"arm64", @"-platform_version", @"ios", @"15.0", @"18.5",
                @"-syslibroot", sdk, @"-o", cApp, obj, @"-lSystem"], "F-C(純C連結)");
            if ([fm fileExistsAtPath:cApp]) {
                unsigned long long sz = [[fm attributesOfItemAtPath:cApp error:nil] fileSize];
                line("產物 testc_app 已生成，大小 " + std::to_string(sz) + " 位元組");
            } else {
                line("產物 testc_app 不存在");
            }
            NSString *mApp = [dir stringByAppendingPathComponent:@"testapp"];
            NSString *mo = [dir stringByAppendingPathComponent:@"testobjc.o"];
            runLinkJob(@[@"-arch", @"arm64", @"-platform_version", @"ios", @"15.0", @"18.5",
                @"-syslibroot", sdk, @"-o", mApp, mo,
                [@"-F" stringByAppendingString:fwDir],
                @"-framework", @"Foundation", @"-lobjc", @"-lSystem"], "F-ObjC(Foundation連結)");
            if ([fm fileExistsAtPath:mApp]) {
                unsigned long long sz = [[fm attributesOfItemAtPath:mApp error:nil] fileSize];
                line("產物 testapp 已生成，大小 " + std::to_string(sz) + " 位元組");
            } else {
                line("產物 testapp 不存在");
            }
            // ---- G：產出代碼真執行——C 編成 dylib、dlopen 後呼叫驗返回值 ----
            // 兩條線（自家／Nyxian）都從未驗過「產出的代碼能在裝置上跑」，
            // 這段補上：編譯（B 同款）→連結 dylib（lld 加 -adhoc_codesign）
            // →dlopen→dlsym→呼叫，返回值對上 42 才算數。
            {
                nyxMark("G start");
                NSString *gsrc = [dir stringByAppendingPathComponent:@"probe_g.c"];
                NSString *gobj = [dir stringByAppendingPathComponent:@"probe_g.o"];
                NSString *glib = [dir stringByAppendingPathComponent:@"libprobe_g.dylib"];
                [@"int paxidx_g_answer(void) { return 42; }\n" writeToFile:gsrc atomically:YES encoding:NSUTF8StringEncoding error:nil];
                runJob(cArgs(gsrc, gobj), "G-C(編譯dylib源)");
                if ([fm fileExistsAtPath:gobj]) {
                    runLinkJob(@[@"-arch", @"arm64", @"-platform_version", @"ios", @"15.0", @"18.5",
                        @"-syslibroot", sdk, @"-dylib", @"-adhoc_codesign", @"-o", glib, gobj, @"-lSystem"], "G-L(連結dylib)");
                } else {
                    line("G：probe_g.o 不存在，跳過連結");
                }
                if ([fm fileExistsAtPath:glib]) {
                    void *h = dlopen(glib.UTF8String, RTLD_NOW);
                    if (!h) {
                        line(std::string("G：dlopen 產出 dylib 失敗：") + (dlerror() ?: "(null)"));
                    } else {
                        typedef int (*AnswerFn)(void);
                        AnswerFn fn = (AnswerFn)dlsym(h, "paxidx_g_answer");
                        if (!fn) {
                            line("G：dlsym 找不到 paxidx_g_answer");
                        } else {
                            int v = fn();
                            line(std::string("G：產出函數已執行，返回值 ") + std::to_string(v) + (v == 42 ? "（正確）" : "（不符預期）"));
                        }
                    }
                } else {
                    line("G：libprobe_g.dylib 不存在");
                }
                nyxMark("G done");
            }
        }
        // ---- S：Swift 探針（本案關鍵票） ----
        // Nyxian 0.11.4 內嵌前端為 Swift 6.3.3；其 App 的正式路是
        // SwiftDriver（type=3）＋專案 swiftFlags（-target／-sdk／
        // -resource-dir <BSROOT>/swift／-module-cache-path／App 類加
        // -parse-as-library，照 NXCodeTemplate 預設）。本裝置沒有
        // BSROOT，先以既有 SDK 的 usr/lib/swift（介面集）當 resource-dir
        // 試：S1 走 driver、S2 直打前端（type=2）。源碼刻意 import
        // Foundation 並用到 Data——自家線從未編成過這一级別的 Swift。
        {
            nyxMark("S start");
            NSString *ssrc = [dir stringByAppendingPathComponent:@"probe.swift"];
            NSString *sobj = [dir stringByAppendingPathComponent:@"probe_swift.o"];
            NSString *scache = [dir stringByAppendingPathComponent:@"ModuleCache"];
            [fm createDirectoryAtPath:scache withIntermediateDirectories:YES attributes:nil error:nil];
            [@"import Foundation\npublic func paxidxSwiftProbe() -> Int {\n    let parts = [\"nyx\", \"swift\"].joined(separator: \"-\")\n    let data = Data(parts.utf8)\n    return data.count + parts.count\n}\n"
                writeToFile:ssrc atomically:YES encoding:NSUTF8StringEncoding error:nil];
            NSString *swiftRes = [sdk stringByAppendingPathComponent:@"usr/lib/swift"];
            {
                NSArray *mods = [fm contentsOfDirectoryAtPath:swiftRes error:nil];
                NSMutableArray *head = [NSMutableArray array];
                for (NSUInteger k = 0; k < (mods ? mods.count : 0) && k < 12; k++) [head addObject:mods[k]];
                line("S：SDK usr/lib/swift 內容（前 12）：" + std::string([[head componentsJoinedByString:@", "] UTF8String] ?: ""));
            }
            auto runJobT = [&](uint8_t type, NSArray *fullArgs, const char *tag) {
                CCJobRef2 job = pJobCreate(nyxZeroAllocator(), type, (__bridge CFArrayRef)fullArgs);
                if (!job) { line(std::string(tag) + "：CCJobCreate 回傳空"); return; }
                CFArrayRef diags = NULL;
                CFStringRef mainSrc = NULL;
                CFAbsoluteTime t0 = CFAbsoluteTimeGetCurrent();
                // Swift job（type 2/3）的 invocation 級錯誤走預設 printing
                // consumer 寫進 stderr、不進捕獲陣列（前兩輪皆零診斷之因）。
                // 執行前把 fd 1/2 轉到檔案，執行後整段讀回報告。
                NSString *errFile = nil;
                int savedOut = -1, savedErr = -1;
                FILE *errFp = NULL;
                if (type == 2 || type == 3) {
                    errFile = [dir stringByAppendingPathComponent:@"swift_stderr.txt"];
                    [fm removeItemAtPath:errFile error:nil];
                    fflush(stdout); fflush(stderr);
                    savedOut = dup(1); savedErr = dup(2);
                    errFp = fopen(errFile.UTF8String, "w");
                    if (errFp) { dup2(fileno(errFp), 1); dup2(fileno(errFp), 2); }
                }
                Boolean success = pJobExecute(job, &diags, &mainSrc);
                if (errFp) {
                    fflush(stdout); fflush(stderr);
                    dup2(savedOut, 1); dup2(savedErr, 2);
                    close(savedOut); close(savedErr);
                    fclose(errFp);
                    NSString *cap = [NSString stringWithContentsOfFile:errFile encoding:NSUTF8StringEncoding error:nil];
                    if (cap.length > 3000) cap = [cap substringToIndex:3000];
                    line(std::string(tag) + " stderr：" + (cap ? std::string(cap.UTF8String) : std::string("(空)")));
                }
                CFAbsoluteTime dt = CFAbsoluteTimeGetCurrent() - t0;
                line(std::string(tag) + " 執行結果：" + (success ? "成功" : "失敗"));
                { char b[64]; snprintf(b, sizeof(b), "%s 耗時 %.0f ms", tag, dt * 1000.0); line(b); }
                line(std::string(tag) + (diags ? " diag 數：" + std::to_string((long)CFArrayGetCount(diags)) : " diag 陣列=NULL"));
                if (diags && pDiagLevel && pDiagMessage) {
                    CFIndex nd = CFArrayGetCount(diags);
                    for (CFIndex d = 0; d < nd && d < 12; d++) {
                        CCDiagnosticRef2 dg = (CCDiagnosticRef2)CFArrayGetValueAtIndex(diags, d);
                        uint8_t lv = pDiagLevel(dg);
                        CFStringRef msg = pDiagMessage(dg);
                        std::string m = msg ? ([(__bridge NSString *)msg UTF8String] ?: "") : "";
                        line(std::string("  diag[") + kLevelNames[lv <= 5 ? lv : 5] + "] " + m);
                    }
                }
                if (diags) CFRelease(diags);
                if (mainSrc) CFRelease(mainSrc);
                CFRelease(job);
            };
            runJobT(3, @[ssrc, @"-c", @"-o", sobj, @"-sdk", sdk, @"-target", @"arm64-apple-ios15.0",
                @"-module-name", @"PaxProbe", @"-resource-dir", swiftRes,
                @"-module-cache-path", scache, @"-parse-as-library", @"-aarch64-use-tbi"], "S1(SwiftDriver)");
            if ([fm fileExistsAtPath:sobj]) {
                unsigned long long sz = [[fm attributesOfItemAtPath:sobj error:nil] fileSize];
                line("S1 產物 probe_swift.o 已生成，大小 " + std::to_string(sz) + " 位元組");
            } else {
                line("S1 無產物，接著試 S2 直打前端");
                // S2 第一輪（136ms／零診斷／無產物）參數形狀有誤：輸入檔只掛在
                // -primary-file 後面、沒有以普通輸入出現（真 swiftc 的前端命令行
                // 兩處都有）。S2a 補回普通輸入；S2b 再砍到最小集對照。
                runJobT(2, @[@"-frontend", @"-c", ssrc, @"-primary-file", ssrc, @"-target", @"arm64-apple-ios15.0",
                    @"-sdk", sdk, @"-resource-dir", swiftRes, @"-module-cache-path", scache,
                    @"-o", sobj, @"-module-name", @"PaxProbe", @"-enable-objc-interop", @"-parse-as-library"], "S2a(前端直打+普通輸入)");
                if (![fm fileExistsAtPath:sobj]) {
                    runJobT(2, @[@"-frontend", @"-c", ssrc, @"-primary-file", ssrc, @"-target", @"arm64-apple-ios15.0",
                        @"-sdk", sdk, @"-o", sobj, @"-module-name", @"PaxProbe"], "S2b(前端直打最小集)");
                }
                if ([fm fileExistsAtPath:sobj]) {
                    unsigned long long sz = [[fm attributesOfItemAtPath:sobj error:nil] fileSize];
                    line("S2a/b 產物 probe_swift.o 已生成，大小 " + std::to_string(sz) + " 位元組");
                } else {
                    line("S2a/b 亦無產物");
                }
            }
            nyxMark("S done");
        }
        nyxMark("direct v2 done");
    }
    if ([fm fileExistsAtPath:obj]) {
        unsigned long long sz = [[fm attributesOfItemAtPath:obj error:nil] fileSize];
        line("產物 test.o 已生成，大小 " + std::to_string(sz) + " 位元組");
        ok = true;
    } else {
        line("產物 test.o 不存在");
    }
    nyxMark("finished");
    copyDiag(report.c_str(), buffer, capacity);
    return ok ? 0 : 1;
}
