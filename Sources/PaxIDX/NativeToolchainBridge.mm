// PaxIDX 工具鏈橋接（App 端）：dlopen 載入 dylib 轉發
// 啟動時不載入 LLVM，點編譯時才 dlopen Documents/Toolchain/ 下的 dylib
// dylib 由 ToolchainManager 從 release 下載
#include "NativeToolchainBridge.h"

#include <Foundation/Foundation.h>
#include <dlfcn.h>
#include <mach-o/dyld.h>
#include <execinfo.h>
#include <signal.h>
#include <mach/mach.h>
#include <dispatch/dispatch.h>
#include <string>
#include <atomic>
#include <cstring>
#include <unistd.h>
#include <fcntl.h>
#include <cstdio>
#include <vector>
#include <CommonCrypto/CommonDigest.h>
#include <libkern/OSByteOrder.h>

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
typedef struct __CCDriver *CCDriverRef2;
typedef CFStringRef (*CCOutputPathCallbackFn)(const char *baseInput, bool *skip, void *context);
typedef CCDriverRef2 (*CCDriverCreateFn)(CFAllocatorRef, CFArrayRef, uint8_t);
typedef CFArrayRef (*PaxCCDriverCreateJobsFn)(CCDriverRef2);
typedef void (*CCDriverSetOutputPathCallbackFn)(CCDriverRef2, CCOutputPathCallbackFn, void *);
typedef CFArrayRef (*CCJobGetArgumentsFn)(CCJobRef2);
typedef CFURLRef (*CCDriverCopySysrootURLFn)(CCDriverRef2);
typedef CFArrayRef (*CCJobCreateArgumentsFn)(CFAllocatorRef, CCJobRef2);
typedef CFArrayRef (*CCJobGetBaseArgumentsFn)(CCJobRef2);
typedef CFArrayRef (*CCJobGetInputFileURLsFn)(CCJobRef2);
typedef uint8_t (*CCJobGetTypeFn)(CCJobRef2);

// 打包 SDK 解析：Documents/PaxSDK/sdk/iphoneos-<主版>.sdk 取最高版，
// 找不到才退回舊佈局 Documents/PaxSDK/iPhoneOS.sdk。
static NSString *nyxPackagedSDKPath(void) {
    NSFileManager *fm = [NSFileManager defaultManager];
    NSString *docs = NSSearchPathForDirectoriesInDomains(NSDocumentDirectory, NSUserDomainMask, YES).firstObject;
    NSString *store = [[docs stringByAppendingPathComponent:@"PaxSDK"] stringByAppendingPathComponent:@"sdk"];
    NSString *best = nil;
    int bestMajor = -1;
    for (NSString *name in [fm contentsOfDirectoryAtPath:store error:nil] ?: @[]) {
        if (![name hasPrefix:@"iphoneos-"] || ![name hasSuffix:@".sdk"]) continue;
        NSString *num = [[name stringByReplacingOccurrencesOfString:@"iphoneos-" withString:@""]
            stringByReplacingOccurrencesOfString:@".sdk" withString:@""];
        int v = num.intValue;
        if (v > bestMajor) { bestMajor = v; best = [store stringByAppendingPathComponent:name]; }
    }
    if (best) return best;
    NSString *legacy = [[docs stringByAppendingPathComponent:@"PaxSDK"] stringByAppendingPathComponent:@"iPhoneOS.sdk"];
    return [fm fileExistsAtPath:legacy] ? legacy : nil;
}



// ---- JIT／除錯狀態讀數 ----
// 「有沒有 JIT」不能靠 UI 感覺，要量進程自己的 csflags：
// CS_DEBUGGED(0x10000000) 有亮才算真掛上除錯器；
// 另以 sysctl 的 P_TRACED(0x800) 交叉確認。
extern "C" int csops(pid_t pid, unsigned int ops, void *useraddr, size_t usersize);
#include <sys/sysctl.h>
static void paxReportJitState(const char *tag, std::string &out) {
    uint32_t flags = 0;
    int rc = csops(getpid(), 0, &flags, sizeof(flags)); // CS_OPS_STATUS = 0
    bool traced = false;
    int mib[4] = {CTL_KERN, KERN_PROC, KERN_PROC_PID, 0};
    mib[3] = getpid();
    struct kinfo_proc kp; size_t klen = sizeof(kp);
    if (sysctl(mib, 4, &kp, &klen, NULL, 0) == 0) traced = (kp.kp_proc.p_flag & 0x800) != 0; // P_TRACED
    char buf[220];
    snprintf(buf, sizeof(buf), "%s：csops rc=%d csflags=0x%08x CS_DEBUGGED=%s P_TRACED=%s",
        tag, rc, flags, (flags & 0x10000000) ? "有" : "無", traced ? "有" : "無");
    out += buf; out += "\n";
}

// ---- App 內 adhoc 簽名器（ldid 形狀的正規 superblob）----
// lld -adhoc_codesign 產的簽名 iOS 15 dyld 不接受（G 段實證）；
// 這裡在 lld 已預留的 LC_CODE_SIGNATURE 區間內，原地換上自組的
// superblob：CodeDirectory(SHA-256)＋空白 requirements＋空白 CMS。
static void paxReportEntitlements(std::string &out) {
    static std::vector<uint8_t> buf(32768, 0);
    int rc = csops(getpid(), 7, buf.data(), buf.size());
    bool has = false;
    if (rc == 0) { std::string s((const char *)buf.data(), buf.size()); has = s.find("can-load-cdhash") != std::string::npos; }
    out += std::string("PaxIDX entitlements check: csops rc=") + std::to_string(rc) + " can-load-cdhash=" + (has ? "YES" : "NO") + "\n";
}
static bool paxAdhocSignMachO(const char *path, std::string &detail) {
    FILE *f = fopen(path, "rb");
    if (!f) { detail = "開啟產物失敗"; return false; }
    fseek(f, 0, SEEK_END); long fsize = ftell(f); fseek(f, 0, SEEK_SET);
    if (fsize <= 0) { fclose(f); detail = "產物為空"; return false; }
    std::vector<uint8_t> img((size_t)fsize);
    if (fread(img.data(), 1, img.size(), f) != img.size()) { fclose(f); detail = "讀取產物失敗"; return false; }
    fclose(f);
    auto rd32 = [&](size_t off) -> uint32_t { uint32_t v; memcpy(&v, img.data() + off, 4); return v; };
    if (img.size() < 32 || rd32(0) != 0xfeedfacf) { detail = "不是 64 位 Mach-O"; return false; }
    uint32_t ncmds = rd32(16);
    uint32_t sizeofcmds = rd32(20);
    size_t lcOff = 32;
    size_t lcEnd = 32 + (size_t)sizeofcmds;
    uint32_t sigOff = 0, sigSize = 0;
    uint64_t textFileSize = 0;
    for (uint32_t i = 0; i < ncmds && lcOff + 8 <= lcEnd; i++) {
        uint32_t cmd = rd32(lcOff), csize = rd32(lcOff + 4);
        if (csize < 8) break;
        if (cmd == 0x1d && csize >= 16) { // LC_CODE_SIGNATURE
            sigOff = rd32(lcOff + 8); sigSize = rd32(lcOff + 12);
        } else if (cmd == 0x19) { // LC_SEGMENT_64
            char name[17] = {0}; memcpy(name, img.data() + lcOff + 8, 16);
            if (strcmp(name, "__TEXT") == 0) { uint64_t fs; memcpy(&fs, img.data() + lcOff + 48, 8); textFileSize = fs; }
        }
        lcOff += csize;
    }
    if (!sigOff || !sigSize) { detail = "無 LC_CODE_SIGNATURE 預留區（連結須帶 -adhoc_codesign）"; return false; }
    for (int attempt = 0; attempt < 3; attempt++) {
        uint32_t pageExp = attempt == 2 ? 14 : 12;
        uint32_t pageSize = 1u << pageExp;
        uint32_t codeLimit = sigOff;
        uint32_t nCode = (codeLimit + pageSize - 1) / pageSize;
        const uint32_t nSpecial = attempt == 1 ? 0 : 2;
        const uint32_t cdHeader = 88;
        const uint32_t identLen = 2; // "-\0"
        const uint32_t teamLen = 1;  // "\0"
        uint32_t hashOff = cdHeader + identLen + teamLen + nSpecial * 32;
        uint32_t cdLen = hashOff + nCode * 32;
        const uint32_t reqLen = 12;
        const uint32_t cmsLen = 8;
        auto align16 = [](uint32_t v) { return (v + 15) & ~(uint32_t)15; };
        uint32_t cdOff = attempt == 1 ? 20 : 36; // superblob header 12 + index 條目 * 8
        uint32_t reqOff = align16(cdOff + cdLen);
        uint32_t cmsOff = align16(reqOff + reqLen);
        uint32_t total = cmsOff + cmsLen;
        if (attempt == 1) total = cdOff + cdLen;
        if (total > sigSize) continue;
        std::vector<uint8_t> blob(total, 0);
        auto wr32 = [&](size_t off, uint32_t v) { uint32_t be = OSSwapHostToBigInt32(v); memcpy(blob.data() + off, &be, 4); };
        auto wr64 = [&](size_t off, uint64_t v) { uint64_t be = OSSwapHostToBigInt64(v); memcpy(blob.data() + off, &be, 8); };
        wr32(0, 0xfade0cc0); wr32(4, total); wr32(8, attempt == 1 ? 1 : 3);
        wr32(12, 0); wr32(16, cdOff);
        if (attempt != 1) {
            wr32(20, 2); wr32(24, reqOff);
            wr32(28, 0x10000); wr32(32, cmsOff);
            wr32(reqOff, 0xfade0c01); wr32(reqOff + 4, reqLen); wr32(reqOff + 8, 0);
            wr32(cmsOff, 0xfade0b01); wr32(cmsOff + 4, cmsLen);
        }
        size_t cd = cdOff;
        wr32(cd + 0, 0xfade0c02); wr32(cd + 4, cdLen); wr32(cd + 8, 0x20400);
        wr32(cd + 12, 0x2); // flags = CS_ADHOC
        wr32(cd + 16, hashOff);
        wr32(cd + 20, cdHeader);
        wr32(cd + 24, nSpecial); wr32(cd + 28, nCode);
        wr32(cd + 32, codeLimit);
        blob[cd + 36] = 32; blob[cd + 37] = 2; blob[cd + 38] = 0; blob[cd + 39] = (uint8_t)pageExp;
        wr32(cd + 40, 0);
        wr32(cd + 44, 0);
        wr32(cd + 48, cdHeader + identLen);
        wr32(cd + 52, 0);
        wr64(cd + 56, 0);
        wr64(cd + 64, 0);
        wr64(cd + 72, textFileSize);
        wr64(cd + 80, 0);
        memcpy(blob.data() + cd + cdHeader, "-", identLen);
        size_t specialBase = cd + hashOff - nSpecial * 32;
        if (nSpecial > 0) CC_SHA256(blob.data() + reqOff, reqLen, blob.data() + specialBase); // slot -2 = requirements
        for (uint32_t s = 0; s < nCode; s++) {
            uint32_t start = s * pageSize;
            uint32_t len = pageSize < (codeLimit - start) ? pageSize : (codeLimit - start);
            CC_SHA256(img.data() + start, len, blob.data() + cd + hashOff + s * 32);
        }
        FILE *o = fopen(path, "r+b");
        if (!o) { detail = "重開產物寫入失敗"; return false; }
        fseek(o, (long)sigOff, SEEK_SET);
        fwrite(blob.data(), 1, total, o);
        if (total < sigSize) { std::vector<uint8_t> z(sigSize - total, 0); fwrite(z.data(), 1, z.size(), o); }
        fclose(o);
        char buf[160];
        snprintf(buf, sizeof(buf), "補簽完成（superblob %u／預留 %u 位元組、頁 %u、代碼槽 %u）", total, sigSize, pageSize, nCode);
        detail = buf;
        if (attempt == 1) detail += "［緊湊模式］";
        return true;
    }
    detail = "簽名預留區太小，三種模式都不夠";
    return false;
}

static void paxDumpSuperblob(const char *path, const char *tag, std::string &out) {
    auto be32 = [](const uint8_t *p) -> uint32_t {
        return ((uint32_t)p[0] << 24) | ((uint32_t)p[1] << 16) | ((uint32_t)p[2] << 8) | (uint32_t)p[3];
    };
    auto hex8 = [](const uint8_t *p) {
        char b[20]; snprintf(b, sizeof(b), "%02x%02x%02x%02x%02x%02x%02x%02x", p[0], p[1], p[2], p[3], p[4], p[5], p[6], p[7]); return std::string(b);
    };
    FILE *fp = fopen(path, "rb");
    if (!fp) { out += std::string("DUMP[") + tag + "] 開檔失敗\n"; return; }
    fseek(fp, 0, SEEK_END); long fsz = ftell(fp); fseek(fp, 0, SEEK_SET);
    std::vector<uint8_t> f((size_t)fsz);
    if (fsz <= 0 || fread(f.data(), 1, (size_t)fsz, fp) != (size_t)fsz) { fclose(fp); out += std::string("DUMP[") + tag + "] 讀檔失敗\n"; return; }
    fclose(fp);
    if (fsz < 32 || !(f[0] == 0xcf && f[1] == 0xfa)) { out += std::string("DUMP[") + tag + "] 非 thin Mach-O\n"; return; }
    const uint8_t *mh = f.data();
    uint32_t ncmds = *(const uint32_t *)(mh + 16);
    const uint8_t *p = mh + 32;
    uint32_t sigOff = 0, sigSize = 0;
    for (uint32_t i = 0; i < ncmds; i++) {
        uint32_t cmd = *(const uint32_t *)p, csize = *(const uint32_t *)(p + 4);
        if (cmd == 0x1d) { sigOff = *(const uint32_t *)(p + 8); sigSize = *(const uint32_t *)(p + 12); }
        if (csize == 0) break;
        p += csize;
    }
    char line1[512];
    const uint8_t *sb = mh + sigOff;
    uint32_t cnt = sigOff ? be32(sb + 8) : 0;
    std::string idx;
    for (uint32_t k = 0; k < cnt && k < 6; k++) {
        uint32_t t = be32(sb + 12 + k * 8), o = be32(sb + 12 + k * 8 + 4);
        char tb[96];
        snprintf(tb, sizeof(tb), "[t%u m%x L%u]", t, be32(sb + o), be32(sb + o + 4));
        idx += tb;
    }
    snprintf(line1, sizeof(line1), "DUMP[%s] size=%ld LC=0x%x+0x%x SBcnt=%u %s\n", tag, fsz, sigOff, sigSize, cnt, idx.c_str());
    out += line1;
    for (uint32_t k = 0; k < cnt; k++) {
        uint32_t t = be32(sb + 12 + k * 8), o = be32(sb + 12 + k * 8 + 4);
        if (be32(sb + o) != 0xfade0c02) continue;
        const uint8_t *cd = sb + o;
        uint32_t ver = be32(cd + 8), fl = be32(cd + 12), hOff = be32(cd + 16);
        uint32_t nSp = be32(cd + 24), nCode = be32(cd + 28), cLim = be32(cd + 32);
        uint32_t hSize = cd[36], hType = cd[37], pExp = cd[39];
        uint32_t iOff = be32(cd + 20), tOff = be32(cd + 48);
        uint64_t esLim = 0; memcpy(&esLim, cd + 72, 8); esLim = OSSwapBigToHostInt64(esLim);
        std::string ident = iOff ? (const char *)(cd + iOff) : "";
        char line2[768];
        std::string s2 = (nSp >= 2 && nCode > 0) ? hex8(cd + hOff - 2 * hSize) : "-";
        std::string c0 = nCode > 0 ? hex8(cd + hOff) : "-";
        std::string cN = nCode > 0 ? hex8(cd + hOff + (nCode - 1) * hSize) : "-";
        snprintf(line2, sizeof(line2), "DUMP[%s] CD[t%u] ver=0x%x fl=0x%x hOff=%u nSp=%u nCode=%u cLim=0x%x hSz=%u hT=%u pE=%u idOff=%u tmOff=%u esLim=0x%llx ident=%s s-2=%s c0=%s cN=%s\n",
                 tag, t, ver, fl, hOff, nSp, nCode, cLim, hSize, hType, pExp, iOff, tOff, (unsigned long long)esLim, ident.c_str(), s2.c_str(), c0.c_str(), cN.c_str());
        out += line2;
    }
}

static bool gGraftTrueReq = false;
static bool gGraftLdidStyle = false;
static void paxDumpReq(const char *path, const char *label, std::string &out) {
    FILE *f = fopen(path, "rb"); if (!f) { out = std::string(label) + "：開檔失敗"; return; }
    fseek(f, 0, SEEK_END); long fs = ftell(f); fseek(f, 0, SEEK_SET);
    std::vector<uint8_t> m((size_t)(fs > 0 ? fs : 0));
    if (fs <= 0 || fread(m.data(), 1, m.size(), f) != m.size()) { fclose(f); out = std::string(label) + "：讀檔失敗"; return; }
    fclose(f);
    auto be32 = [](const uint8_t *p) -> uint32_t { return ((uint32_t)p[0] << 24) | ((uint32_t)p[1] << 16) | ((uint32_t)p[2] << 8) | (uint32_t)p[3]; };
    uint32_t ncmds; memcpy(&ncmds, m.data() + 16, 4);
    size_t lc = 32; uint32_t so = 0, ss = 0;
    for (uint32_t i = 0; i < ncmds && lc + 8 <= m.size(); i++) { uint32_t c, cs; memcpy(&c, m.data() + lc, 4); memcpy(&cs, m.data() + lc + 4, 4); if (cs < 8) break; if (c == 0x1d) { memcpy(&so, m.data() + lc + 8, 4); memcpy(&ss, m.data() + lc + 12, 4); } lc += cs; }
    if (!so || (uint64_t)so + ss > m.size()) { out = std::string(label) + "：無簽名區"; return; }
    const uint8_t *sb = m.data() + so;
    uint32_t cnt = be32(sb + 8);
    char buf[256];
    out = std::string(label) + " req/特殊槽：";
    for (uint32_t k = 0; k < cnt; k++) {
        uint32_t t = be32(sb + 12 + k * 8), o = be32(sb + 12 + k * 8 + 4);
        if ((uint64_t)o + 8 > ss) continue;
        uint32_t len = be32(sb + o + 4);
        if (t == 2) {
            snprintf(buf, sizeof(buf), "\nreq L%u hex:", len); out += buf;
            for (uint32_t i = 0; i < len; i += 24) {
                out += "\n  ";
                for (uint32_t j = i; j < i + 24 && j < len; j++) { snprintf(buf, sizeof(buf), "%02x", sb[o + j]); out += buf; }
            }
        } else if (t == 0 || t == 4096) {
            const uint8_t *cd = sb + o;
            uint32_t hOff = be32(cd + 16), nSp = be32(cd + 24), hSz = cd[36];
            if (hOff > len || nSp > 8 || hSz == 0 || hSz > 64) continue;
            const uint8_t *h0 = cd + hOff - (size_t)nSp * hSz;
            out += (t == 0 ? "\n主CD特殊槽 " : "\naltCD特殊槽 ");
            for (uint32_t s = 1; s <= nSp && s <= 7; s++) {
                const uint8_t *h = h0 + (size_t)(nSp - s) * hSz;
                snprintf(buf, sizeof(buf), "s-%u=", s); out += buf;
                for (int j = 0; j < 8 && j < (int)hSz; j++) { snprintf(buf, sizeof(buf), "%02x", h[j]); out += buf; }
                out += " ";
            }
        }
    }
}
static void paxDumpGeo(const char *path, const char *label, std::string &out) {
    FILE *f = fopen(path, "rb"); if (!f) { out = std::string(label) + " GEO：開檔失敗"; return; }
    fseek(f, 0, SEEK_END); long fs = ftell(f); fseek(f, 0, SEEK_SET);
    std::vector<uint8_t> m((size_t)(fs > 0 ? fs : 0));
    if (fs <= 0 || fread(m.data(), 1, m.size(), f) != m.size()) { fclose(f); out = std::string(label) + " GEO：讀檔失敗"; return; }
    fclose(f);
    uint32_t nc; memcpy(&nc, m.data() + 16, 4);
    size_t lc = 32; int sigIdx = -1; uint64_t leFO = 0, leFS = 0, leVS = 0;
    for (uint32_t i = 0; i < nc && lc + 8 <= m.size(); i++) {
        uint32_t c, cs; memcpy(&c, m.data() + lc, 4); memcpy(&cs, m.data() + lc + 4, 4); if (cs < 8) break;
        if (c == 0x1d) sigIdx = (int)i;
        else if (c == 0x19) { char nm[17] = {0}; memcpy(nm, m.data() + lc + 8, 16); if (strcmp(nm, "__LINKEDIT") == 0) { memcpy(&leFO, m.data() + lc + 40, 8); memcpy(&leFS, m.data() + lc + 48, 8); memcpy(&leVS, m.data() + lc + 32, 8); } }
        lc += cs;
    }
    char buf[320];
    snprintf(buf, sizeof(buf), "%s GEO size=%ld ncmds=%u sigIdx=%d LINKEDIT fo=0x%llx fs=0x%llx vs=0x%llx", label, fs, nc, sigIdx, (unsigned long long)leFO, (unsigned long long)leFS, (unsigned long long)leVS);
    out = buf;
}
static bool paxGraftSignMachO(const char *path, const char *donorPath, std::string &detail) {
    auto readFile = [](const char *p, std::vector<uint8_t> &out) -> bool {
        FILE *f = fopen(p, "rb"); if (!f) return false;
        fseek(f, 0, SEEK_END); long s = ftell(f); fseek(f, 0, SEEK_SET);
        if (s <= 0) { fclose(f); return false; }
        out.resize((size_t)s);
        bool ok = fread(out.data(), 1, out.size(), f) == out.size();
        fclose(f); return ok;
    };
    auto be32 = [](const uint8_t *p) -> uint32_t {
        return ((uint32_t)p[0] << 24) | ((uint32_t)p[1] << 16) | ((uint32_t)p[2] << 8) | (uint32_t)p[3];
    };
    std::vector<uint8_t> donor, img;
    if (!readFile(donorPath, donor)) { detail = "讀 donor 失敗"; return false; }
    if (!readFile(path, img)) { detail = "讀產物失敗"; return false; }
    auto findCS = [&](const std::vector<uint8_t> &m, uint32_t &off, uint32_t &size, uint64_t &textFS) -> bool {
        if (m.size() < 32) return false;
        uint32_t magic; memcpy(&magic, m.data(), 4);
        if (magic != 0xfeedfacf) return false;
        uint32_t ncmds; memcpy(&ncmds, m.data() + 16, 4);
        size_t lc = 32; off = 0; size = 0; textFS = 0;
        for (uint32_t i = 0; i < ncmds && lc + 8 <= m.size(); i++) {
            uint32_t cmd, csize; memcpy(&cmd, m.data() + lc, 4); memcpy(&csize, m.data() + lc + 4, 4);
            if (csize < 8) break;
            if (cmd == 0x1d) { memcpy(&off, m.data() + lc + 8, 4); memcpy(&size, m.data() + lc + 12, 4); }
            else if (cmd == 0x19) { char nm[17] = {0}; memcpy(nm, m.data() + lc + 8, 16); if (strcmp(nm, "__TEXT") == 0) memcpy(&textFS, m.data() + lc + 48, 8); }
            lc += csize;
        }
        return off && size;
    };
    uint32_t dOff, dSize; uint64_t dText;
    if (!findCS(donor, dOff, dSize, dText)) { detail = "donor 無簽名區"; return false; }
    const uint8_t *dsb = donor.data() + dOff;
    uint32_t dCnt = be32(dsb + 8);
    std::vector<uint8_t> donorCD, donorReq, donorCMS, donorAlt;
    for (uint32_t k = 0; k < dCnt; k++) {
        uint32_t t = be32(dsb + 12 + k * 8), o = be32(dsb + 12 + k * 8 + 4);
        uint32_t len = be32(dsb + o + 4);
        if (dOff + o + len > donor.size()) continue;
        std::vector<uint8_t> part(dsb + o, dsb + o + len);
        if (t == 0) donorCD = part;
        else if (t == 2) donorReq = part;
        else if (t == 65536) donorCMS = part;
        else if (t == 4096) donorAlt = part;
    }
    if (donorCD.empty() || donorReq.empty() || donorCMS.empty() || donorAlt.empty()) { detail = "donor 組件不全"; return false; }
    if (gGraftTrueReq) { donorReq.assign({0xfa, 0xde, 0x0c, 0x01, 0, 0, 0, 12, 0, 0, 0, 1}); }
    auto cdStr = [&](const std::vector<uint8_t> &cd, size_t off) -> std::string {
        if (off == 0 || off >= cd.size()) return std::string();
        return std::string((const char *)cd.data() + off);
    };
    std::string ident = cdStr(donorAlt, be32(donorAlt.data() + 20));
    std::string team = cdStr(donorAlt, be32(donorAlt.data() + 48));
    uint32_t sigOff, sigSize; uint64_t textFS;
    if (!findCS(img, sigOff, sigSize, textFS)) { detail = "產物無簽名預留區"; return false; }
    uint32_t pageSize = 4096;
    uint32_t codeLimit = sigOff;
    uint32_t nCode = (codeLimit + pageSize - 1) / pageSize;
    const uint32_t nSpecial = 2, cdHeader = 88;
    uint32_t identLen = (uint32_t)ident.size() + 1;
    uint32_t teamLen = (uint32_t)team.size() + 1;
    uint32_t hashOff = cdHeader + identLen + teamLen + nSpecial * 32;
    uint32_t cdLen = hashOff + nCode * 32;
    uint32_t hdr = 12 + 4 * 8;
    uint32_t oCD = hdr;
    uint32_t oReq = oCD + (uint32_t)donorCD.size();
    uint32_t oAlt = oReq + (uint32_t)donorReq.size();
    uint32_t oCMS = oAlt + cdLen;
    uint32_t total = oCMS + (uint32_t)donorCMS.size();
    bool grow = total > sigSize;
    if (grow) {
        size_t sigSizePos = 0, leFSPos = 0, leVSPos = 0;
        uint64_t leFO = 0, leFS = 0, leVS = 0;
        uint32_t ncmds2; memcpy(&ncmds2, img.data() + 16, 4);
        size_t lc2 = 32;
        for (uint32_t i = 0; i < ncmds2 && lc2 + 8 <= img.size(); i++) {
            uint32_t cmd, csize; memcpy(&cmd, img.data() + lc2, 4); memcpy(&csize, img.data() + lc2 + 4, 4);
            if (csize < 8) break;
            if (cmd == 0x1d) sigSizePos = lc2 + 12;
            else if (cmd == 0x19) { char nm[17] = {0}; memcpy(nm, img.data() + lc2 + 8, 16); if (strcmp(nm, "__LINKEDIT") == 0) { leVSPos = lc2 + 32; leFSPos = lc2 + 48; memcpy(&leFO, img.data() + lc2 + 40, 8); memcpy(&leFS, img.data() + lc2 + 48, 8); memcpy(&leVS, img.data() + lc2 + 32, 8); } }
            lc2 += csize;
        }
        if (!sigSizePos || !leFSPos || (uint64_t)sigOff + sigSize != leFO + leFS || (uint64_t)sigOff + sigSize != img.size()) {
            detail = "graft 放不進且簽名區不在檔尾，無法擴區"; return false;
        }
        uint32_t growBy = total - sigSize;
        uint32_t ns = total; memcpy(img.data() + sigSizePos, &ns, 4);
        uint64_t nfs = leFS + growBy; memcpy(img.data() + leFSPos, &nfs, 8);
        uint64_t nvs = leVS; uint64_t need = (nfs + 4095) & ~(uint64_t)4095; if (nvs < need) nvs = need;
        memcpy(img.data() + leVSPos, &nvs, 8);
        img.resize((size_t)sigOff + total, 0);
    }
    if (gGraftLdidStyle) {
        // ldid 式檔案層處理（在算頁雜湊之前）：__LINKEDIT vmsize 以
        // 16K 對齊；LC_CODE_SIGNATURE 移到 load commands 末尾
        uint32_t nc3; memcpy(&nc3, img.data() + 16, 4);
        uint32_t soc3; memcpy(&soc3, img.data() + 20, 4);
        size_t lc3 = 32; size_t sigPos3 = 0; uint32_t sigIdx3 = 0;
        for (uint32_t i = 0; i < nc3 && lc3 + 8 <= img.size(); i++) {
            uint32_t cmd, csize; memcpy(&cmd, img.data() + lc3, 4); memcpy(&csize, img.data() + lc3 + 4, 4);
            if (csize < 8) break;
            if (cmd == 0x19) { char nm[17] = {0}; memcpy(nm, img.data() + lc3 + 8, 16); if (strcmp(nm, "__LINKEDIT") == 0) { uint64_t fs; memcpy(&fs, img.data() + lc3 + 48, 8); uint64_t vs; memcpy(&vs, img.data() + lc3 + 32, 8); uint64_t nvs = (fs + 16383) & ~(uint64_t)16383; if (nvs > vs) memcpy(img.data() + lc3 + 32, &nvs, 8); } }
            else if (cmd == 0x1d) { sigPos3 = lc3; sigIdx3 = i; }
            lc3 += csize;
        }
        if (sigPos3 && sigIdx3 != nc3 - 1) {
            uint8_t tmpSig[16]; memcpy(tmpSig, img.data() + sigPos3, 16);
            size_t cmdsEnd = 32 + soc3;
            memmove(img.data() + sigPos3, img.data() + sigPos3 + 16, cmdsEnd - (sigPos3 + 16));
            memcpy(img.data() + cmdsEnd - 16, tmpSig, 16);
        }
    }
    std::vector<uint8_t> blob(total, 0);
    auto wr32 = [&](size_t o, uint32_t v) { uint32_t b = OSSwapHostToBigInt32(v); memcpy(blob.data() + o, &b, 4); };
    auto wr64 = [&](size_t o, uint64_t v) { uint64_t b = OSSwapHostToBigInt64(v); memcpy(blob.data() + o, &b, 8); };
    wr32(0, 0xfade0cc0); wr32(4, total); wr32(8, 4);
    wr32(12, 0); wr32(16, oCD);
    wr32(20, 2); wr32(24, oReq);
    wr32(28, 4096); wr32(32, oAlt);
    wr32(36, 65536); wr32(40, oCMS);
    memcpy(blob.data() + oCD, donorCD.data(), donorCD.size());
    memcpy(blob.data() + oReq, donorReq.data(), donorReq.size());
    memcpy(blob.data() + oCMS, donorCMS.data(), donorCMS.size());
    size_t cd = oAlt;
    wr32(cd + 0, 0xfade0c02); wr32(cd + 4, cdLen); wr32(cd + 8, 0x20400);
    wr32(cd + 12, 0);
    wr32(cd + 16, hashOff);
    wr32(cd + 20, cdHeader);
    wr32(cd + 24, nSpecial); wr32(cd + 28, nCode);
    wr32(cd + 32, codeLimit);
    blob[cd + 36] = 32; blob[cd + 37] = 2; blob[cd + 38] = 0; blob[cd + 39] = 12;
    wr32(cd + 48, cdHeader + identLen);
    wr64(cd + 72, textFS);
    memcpy(blob.data() + cd + cdHeader, ident.c_str(), identLen);
    memcpy(blob.data() + cd + cdHeader + identLen, team.c_str(), teamLen);
    size_t specialBase = cd + hashOff - nSpecial * 32;
    CC_SHA256(donorReq.data(), (CC_LONG)donorReq.size(), blob.data() + specialBase);
    for (uint32_t s = 0; s < nCode; s++) {
        uint32_t start = s * pageSize;
        uint32_t len = pageSize < (codeLimit - start) ? pageSize : (codeLimit - start);
        CC_SHA256(img.data() + start, len, blob.data() + cd + hashOff + s * 32);
    }
    memcpy(img.data() + sigOff, blob.data(), total);
    if (!grow && total < sigSize) memset(img.data() + sigOff + total, 0, sigSize - total);
    FILE *o = fopen(path, "wb");
    if (!o) { detail = "重寫產物失敗"; return false; }
    fwrite(img.data(), 1, img.size(), o);
    fclose(o);
    char buf[260];
    if (grow) snprintf(buf, sizeof(buf), "graft 補簽完成（已擴區，superblob %u、alt ident=%s）", total, ident.c_str());
    else snprintf(buf, sizeof(buf), "graft 補簽完成（superblob %u／預留 %u、alt ident=%s）", total, sigSize, ident.c_str());
    detail = buf;
    return true;
}

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
        // 打包 SDK 已解壓在 Documents/PaxSDK 就直接用它（新鏈不依賴舊下載路徑）
        NSString *bundled = nyxPackagedSDKPath();
        if (bundled && [fm fileExistsAtPath:bundled]) {
            sdk = bundled;
            line("S：舊路徑 SDK 不在，改用打包 SDK（Documents/PaxSDK）");
        } else {
            line("SDK 未安裝（Documents/SDK 與 Documents/PaxSDK 皆不存在）");
            copyDiag(report.c_str(), buffer, capacity);
            return 1;
        }
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
            // A/B 對照：同一顆 dylib，甲本用 lld 的 -adhoc_codesign（舊路，
            // 預期被 dyld 拒），乙本在 lld 預留的簽名區換上 App 內簽名器
            // 自組的 ldid 形狀 superblob——乙本過了，產出補簽路線即成立。
            {
                nyxMark("G start");
                paxReportJitState("G 段執行當下", report);
                paxReportEntitlements(report);
                NSString *gsrc = [dir stringByAppendingPathComponent:@"probe_g.c"];
                NSString *gobj = [dir stringByAppendingPathComponent:@"probe_g.o"];
                [@"int paxidx_g_answer(void) { return 42; }\n" writeToFile:gsrc atomically:YES encoding:NSUTF8StringEncoding error:nil];
                runJob(cArgs(gsrc, gobj), "G-C(編譯dylib源)");
                auto tryLoad = [&](NSString *libPath, const char *tag) {
                    if (![fm fileExistsAtPath:libPath]) { line(std::string(tag) + "：dylib 不存在"); return; }
                    void *h = dlopen(libPath.UTF8String, RTLD_NOW);
                    if (!h) {
                        line(std::string(tag) + "：dlopen 失敗：" + (dlerror() ?: "(null)"));
                        return;
                    }
                    typedef int (*AnswerFn)(void);
                    AnswerFn fn = (AnswerFn)dlsym(h, "paxidx_g_answer");
                    if (!fn) { line(std::string(tag) + "：dlsym 找不到 paxidx_g_answer"); return; }
                    int v = fn();
                    line(std::string(tag) + "：產出函數已執行，返回值 " + std::to_string(v) + (v == 42 ? "（正確）" : "（不符預期）"));
                };
                if ([fm fileExistsAtPath:gobj]) {
                    NSString *glibA = [dir stringByAppendingPathComponent:@"libprobe_g_lld.dylib"];
                    runLinkJob(@[@"-arch", @"arm64", @"-platform_version", @"ios", @"15.0", @"18.5",
                        @"-syslibroot", sdk, @"-dylib", @"-adhoc_codesign", @"-o", glibA, gobj, @"-lSystem"], "G-L(甲·lld簽名)");
                    tryLoad(glibA, "G[甲 lld adhoc]");
                    NSString *glibB = [dir stringByAppendingPathComponent:@"libprobe_g_own.dylib"];
                    runLinkJob(@[@"-arch", @"arm64", @"-platform_version", @"ios", @"15.0", @"18.5",
                        @"-syslibroot", sdk, @"-dylib", @"-adhoc_codesign", @"-o", glibB, gobj, @"-lSystem"], "G-L(乙·待補簽)");
                    if ([fm fileExistsAtPath:glibB]) {
                        std::string sdetail;
                        bool sok = paxAdhocSignMachO(glibB.UTF8String, sdetail);
                        line(std::string("G[乙 自家簽名器]：") + sdetail);
                        if (sok) tryLoad(glibB, "G[乙 自家補簽]");
                    {
                        NSString *donorP = [[[NSBundle mainBundle] bundlePath] stringByAppendingPathComponent:@"Frameworks/CoreCompiler.framework/Frameworks/lib_CompilerSwiftSyntax.dylib"];
                        NSString *glibG = [dir stringByAppendingPathComponent:@"libprobe_g_graft.dylib"];
                        [fm removeItemAtPath:glibG error:nil];
                        if ([fm copyItemAtPath:glibA toPath:glibG error:nil]) {
                            std::string kdetail;
                            bool kok = paxGraftSignMachO(glibG.UTF8String, donorP.UTF8String, kdetail);
                            line(std::string("G8[癸 graft@自產probe]：") + kdetail);
                            if (kok) { tryLoad(glibG, "G8[癸 graft自產]"); { std::string d; paxDumpSuperblob(glibG.UTF8String, "癸產出", d); line(d); } }
                        } else {
                            line("G8[癸]：複製 lld 產出失敗");
                        }
                    }
                    {
                        NSString *gsrc2 = [dir stringByAppendingPathComponent:@"probe_g2.c"];
                        NSString *gobj2 = [dir stringByAppendingPathComponent:@"probe_g2.o"];
                        [@"__attribute__((used, section(\"__DATA,__paxpad\"))) static const char paxPad[3500000] = {1};\nint paxidx_g_answer(void) { return 42 + (int)(paxPad[0] - 1); }\n" writeToFile:gsrc2 atomically:YES encoding:NSUTF8StringEncoding error:nil];
                        runJob(cArgs(gsrc2, gobj2), "G10-C(編譯填充probe)");
                        if ([fm fileExistsAtPath:gobj2]) {
                            NSString *glibP = [dir stringByAppendingPathComponent:@"libprobe_g_pad.dylib"];
                            runLinkJob(@[@"-arch", @"arm64", @"-platform_version", @"ios", @"15.0", @"18.5",
                                @"-syslibroot", sdk, @"-dylib", @"-adhoc_codesign", @"-o", glibP, gobj2, @"-lSystem"], "G10-L(癸2·填充版)");
                            NSString *donorP2 = [[[NSBundle mainBundle] bundlePath] stringByAppendingPathComponent:@"Frameworks/CoreCompiler.framework/Frameworks/lib_CompilerSwiftSyntax.dylib"];
                            std::string pdetail;
                            bool pok = paxGraftSignMachO(glibP.UTF8String, donorP2.UTF8String, pdetail);
                            line(std::string("G10[癸2 graft@填充probe]：") + pdetail);
                            if (pok) tryLoad(glibP, "G10[癸2 graft填充自產]");
                        }
                    }
                    {
                        NSString *donorWu = [[[NSBundle mainBundle] bundlePath] stringByAppendingPathComponent:@"probe_ldid.dylib"];
                        NSString *glibW = [dir stringByAppendingPathComponent:@"libprobe_g_wu.dylib"];
                        [fm removeItemAtPath:glibW error:nil];
                        if ([fm copyItemAtPath:glibA toPath:glibW error:nil]) {
                            std::string wdetail;
                            bool wok = paxGraftSignMachO(glibW.UTF8String, donorWu.UTF8String, wdetail);
                            line(std::string("G11[癸3 graft@自產·donor戊]：") + wdetail);
                            if (wok) tryLoad(glibW, "G11[癸3 donor戊自產]");
                        } else {
                            line("G11[癸3]：複製 lld 產出失敗");
                        }
                        NSString *donorExe = [[NSBundle mainBundle] executablePath];
                        NSString *glibE = [dir stringByAppendingPathComponent:@"libprobe_g_exe.dylib"];
                        [fm removeItemAtPath:glibE error:nil];
                        if (donorExe && [fm copyItemAtPath:glibA toPath:glibE error:nil]) {
                            std::string edetail;
                            bool eok = paxGraftSignMachO(glibE.UTF8String, donorExe.UTF8String, edetail);
                            line(std::string("G11[癸4 graft@自產·donor主程式]：") + edetail);
                            if (eok) tryLoad(glibE, "G11[癸4 donor主程式自產]");
                        } else {
                            line("G11[癸4]：複製 lld 產出失敗");
                        }
                        NSString *glibT = [dir stringByAppendingPathComponent:@"libprobe_g_truereq.dylib"];
                        [fm removeItemAtPath:glibT error:nil];
                        if ([fm copyItemAtPath:glibA toPath:glibT error:nil]) {
                            gGraftTrueReq = true;
                            std::string tdetail;
                            bool tok2 = paxGraftSignMachO(glibT.UTF8String, donorWu.UTF8String, tdetail);
                            gGraftTrueReq = false;
                            line(std::string("G12[癸5 graft@自產·donor戊·恆真req]：") + tdetail);
                            if (tok2) tryLoad(glibT, "G12[癸5 恆真req自產]");
                        } else {
                            line("G12[癸5]：複製 lld 產出失敗");
                        }
                    }
                    {
                        NSString *fwDir13 = [[[NSBundle mainBundle] bundlePath] stringByAppendingPathComponent:@"Frameworks/CoreCompiler.framework/Frameworks"];
                        NSString *syntax13 = [fwDir13 stringByAppendingPathComponent:@"lib_CompilerSwiftSyntax.dylib"];
                        NSString *macros13 = [fwDir13 stringByAppendingPathComponent:@"lib_CompilerSwiftSyntaxMacros.dylib"];
                        NSString *wu13 = [[[NSBundle mainBundle] bundlePath] stringByAppendingPathComponent:@"probe_ldid.dylib"];
                        { std::string d; paxDumpGeo(glibA.UTF8String, "GEO[自產probe]", d); line(d); }
                        { std::string d; paxDumpGeo(syntax13.UTF8String, "GEO[syntax]", d); line(d); }
                        { std::string d; paxDumpGeo(macros13.UTF8String, "GEO[Macros]", d); line(d); }
                        { std::string d; paxDumpGeo(wu13.UTF8String, "GEO[戊]", d); line(d); }
                        NSString *e1 = [dir stringByAppendingPathComponent:@"libmacros_orig.dylib"];
                        [fm removeItemAtPath:e1 error:nil];
                        if ([fm copyItemAtPath:macros13 toPath:e1 error:nil]) {
                            tryLoad(e1, "G13[E1 Macros原簽直載]");
                        } else { line("G13[E1]：複製 Macros 失敗"); }
                        NSString *g6 = [dir stringByAppendingPathComponent:@"libprobe_g_ldid.dylib"];
                        [fm removeItemAtPath:g6 error:nil];
                        if ([fm copyItemAtPath:glibA toPath:g6 error:nil]) {
                            gGraftLdidStyle = true;
                            std::string d6;
                            bool ok6 = paxGraftSignMachO(g6.UTF8String, syntax13.UTF8String, d6);
                            gGraftLdidStyle = false;
                            line(std::string("G13[癸6 graft@自產·ldid式]：") + d6);
                            if (ok6) tryLoad(g6, "G13[癸6 ldid式自產]");
                        } else { line("G13[癸6]：複製 lld 產出失敗"); }
                        NSString *r2 = [dir stringByAppendingPathComponent:@"libmacros_g_ldid.dylib"];
                        [fm removeItemAtPath:r2 error:nil];
                        if ([fm copyItemAtPath:macros13 toPath:r2 error:nil]) {
                            gGraftLdidStyle = true;
                            std::string d2;
                            bool ok2 = paxGraftSignMachO(r2.UTF8String, syntax13.UTF8String, d2);
                            gGraftLdidStyle = false;
                            line(std::string("G13[壬2 graft@Macros·ldid式]：") + d2);
                            if (ok2) tryLoad(r2, "G13[壬2 ldid式Macros]");
                        } else { line("G13[壬2]：複製 Macros 失敗"); }
                        NSString *x2 = [dir stringByAppendingPathComponent:@"libsyntax_g_ldid.dylib"];
                        [fm removeItemAtPath:x2 error:nil];
                        if ([fm copyItemAtPath:syntax13 toPath:x2 error:nil]) {
                            gGraftLdidStyle = true;
                            std::string dx;
                            bool okx = paxGraftSignMachO(x2.UTF8String, syntax13.UTF8String, dx);
                            gGraftLdidStyle = false;
                            line(std::string("G13[辛2 graft@良品·ldid式]：") + dx);
                            if (okx) tryLoad(x2, "G13[辛2 ldid式良品]");
                        } else { line("G13[辛2]：複製良品失敗"); }
                    }
                    } else {
                        line("G[乙]：dylib 不存在，跳過補簽");
                    }
                // ---- G2 判別：分離「blob 形狀」與「路徑／信任政策」 ----
                // 丙＝bundle 內已知良品（lib_CompilerSwiftSyntax）的 tmp 副本直載；
                // 丁＝同一良品複本經自家簽名器重簽後載。四格矩陣定病根。
                {
                    nyxMark("G2 start");
                    NSString *fwDir = [[[NSBundle mainBundle] bundlePath]
                        stringByAppendingPathComponent:@"Frameworks/CoreCompiler.framework/Frameworks"];
                    NSString *fwSyntax = [fwDir stringByAppendingPathComponent:@"lib_CompilerSwiftSyntax.dylib"];
                    if (![fm fileExistsAtPath:fwSyntax]) {
                        for (NSString *n in [fm contentsOfDirectoryAtPath:fwDir error:nil] ?: @[]) {
                            if ([n hasSuffix:@".dylib"]) { fwSyntax = [fwDir stringByAppendingPathComponent:n]; break; }
                        }
                    }
                    auto tryLoadRaw = [&](NSString *p, const char *tag) {
                        void *h = dlopen(p.UTF8String, RTLD_NOW);
                        if (!h) {
                            line(std::string(tag) + "：dlopen 失敗：" + (dlerror() ?: "(null)"));
                        } else {
                            line(std::string(tag) + "：dlopen 成功");
                        }
                    };
                    if ([fm fileExistsAtPath:fwSyntax]) {
                        { std::string d; paxDumpSuperblob(fwSyntax.UTF8String, "丙原簽", d); line(d); }
                        { std::string d; paxDumpReq(fwSyntax.UTF8String, "丙req", d); line(d); }
                        NSString *copyC = [dir stringByAppendingPathComponent:@"libcopy_syntax.dylib"];
                        if (![fm fileExistsAtPath:copyC]) [fm copyItemAtPath:fwSyntax toPath:copyC error:nil];
                        tryLoadRaw(copyC, "G2[丙 良品tmp副本]");
                        NSString *copyD = [dir stringByAppendingPathComponent:@"libresign_syntax.dylib"];
                        [fm removeItemAtPath:copyD error:nil];
                        if ([fm copyItemAtPath:fwSyntax toPath:copyD error:nil]) {
                            std::string ddetail;
                            bool dok = paxAdhocSignMachO(copyD.UTF8String, ddetail);
                            line(std::string("G2[丁 簽名器@良品]：") + ddetail);
                            if (dok) { tryLoadRaw(copyD, "G2[丁 良品重簽]"); { std::string d; paxDumpSuperblob(copyD.UTF8String, "丁產出", d); line(d); } }
                        {
                            NSString *copyX = [dir stringByAppendingPathComponent:@"libgraft_syntax.dylib"];
                            [fm removeItemAtPath:copyX error:nil];
                            if ([fm copyItemAtPath:fwSyntax toPath:copyX error:nil]) {
                                std::string xdetail;
                                bool xok = paxGraftSignMachO(copyX.UTF8String, fwSyntax.UTF8String, xdetail);
                                line(std::string("G7[辛 graft@良品]：") + xdetail);
                                if (xok) { tryLoadRaw(copyX, "G7[辛 graft重簽良品]"); { std::string d; paxDumpSuperblob(copyX.UTF8String, "辛產出", d); line(d); } }
                        {
                            NSString *fwDir2 = [[[NSBundle mainBundle] bundlePath] stringByAppendingPathComponent:@"Frameworks/CoreCompiler.framework/Frameworks"];
                            NSArray *subs = [fm contentsOfDirectoryAtPath:fwDir2 error:nil];
                            NSString *smallest = nil; unsigned long long best = ~0ULL;
                            for (NSString *s in subs) {
                                if (![s hasSuffix:@".dylib"]) continue;
                                NSString *p = [fwDir2 stringByAppendingPathComponent:s];
                                unsigned long long sz = [[fm attributesOfItemAtPath:p error:nil] fileSize];
                                if (sz < best) { best = sz; smallest = p; }
                            }
                            if (smallest) {
                                NSString *g4 = [dir stringByAppendingPathComponent:@"libprobe_g_small.dylib"];
                                [fm removeItemAtPath:g4 error:nil];
                                if ([fm copyItemAtPath:smallest toPath:g4 error:nil]) {
                                    line(std::string("G9[壬]：最小 bundle dylib = ") + smallest.lastPathComponent.UTF8String + "（" + std::to_string(best) + "B）");
                                    { std::string d; paxDumpSuperblob(smallest.UTF8String, "壬原簽", d); line(d); }
                                    std::string jdetail;
                                    bool jok = paxGraftSignMachO(g4.UTF8String, fwSyntax.UTF8String, jdetail);
                                    line(std::string("G9[壬 graft@小良品]：") + jdetail);
                                    if (jok) {
                                        void *jh = dlopen(g4.UTF8String, RTLD_NOW);
                                        line(std::string("G9[壬 graft小良品]：") + (jh ? "dlopen 成功" : std::string("dlopen 失敗：") + (dlerror() ?: "(null)")));
                                        { std::string d; paxDumpSuperblob(g4.UTF8String, "壬產出", d); line(d); }
                                    }
                                }
                            }
                        }
                            } else {
                                line("G7[辛]：複製良品失敗");
                            }
                        }

                        } else {
                            line("G2[丁]：複製良品失敗");
                        }
                    } else {
                        line("G2：bundle 內找不到 lib_CompilerSwiftSyntax.dylib");
                    }
                    nyxMark("G2 done");
                }
                } else {
                    line("G：probe_g.o 不存在，跳過連結");
                }
                nyxMark("G done");
            }
        }
        // ---- G4：真工具簽名判別＋自身 CD execSegFlags 實查 ----
        {
            nyxMark("G4 start");
            auto be32 = [](const uint8_t *p) -> uint32_t {
                return ((uint32_t)p[0] << 24) | ((uint32_t)p[1] << 16) | ((uint32_t)p[2] << 8) | (uint32_t)p[3];
            };
            {
                char exeBuf[1024]; uint32_t exeSize = sizeof(exeBuf);
                std::string info = "G4[自身CD]：";
                if (_NSGetExecutablePath(exeBuf, &exeSize) != 0) {
                    info += "取主程式路徑失敗";
                } else if (FILE *fp = fopen(exeBuf, "rb")) {
                    fseek(fp, 0, SEEK_END); long fsz = ftell(fp); fseek(fp, 0, SEEK_SET);
                    std::vector<uint8_t> f((size_t)fsz);
                    if (fsz <= 0 || fread(f.data(), 1, (size_t)fsz, fp) != (size_t)fsz) info += "讀主程式失敗";
                    fclose(fp);
                    if ((long)f.size() == fsz && fsz > 32) {
                        uint32_t base = 0; bool ok = false;
                        if (f[0] == 0xcf && f[1] == 0xfa) { base = 0; ok = true; }
                        else if (be32(f.data()) == 0xcafebabe) {
                            uint32_t n = be32(f.data() + 4);
                            for (uint32_t i = 0; i < n; i++) {
                                const uint8_t *a = f.data() + 8 + i * 20;
                                if (be32(a) == 0x0100000c) { base = be32(a + 8); ok = true; break; }
                            }
                        }
                        if (!ok) info += "主程式格式未識";
                        else {
                            const uint8_t *mh = f.data() + base;
                            uint32_t ncmds = *(const uint32_t *)(mh + 16);
                            const uint8_t *p = mh + 32;
                            bool found = false;
                            for (uint32_t i = 0; i < ncmds; i++) {
                                uint32_t cmd = *(const uint32_t *)p;
                                uint32_t csize = *(const uint32_t *)(p + 4);
                                if (cmd == 0x1d) {
                                    const uint8_t *sb = mh + *(const uint32_t *)(p + 8);
                                    uint32_t cnt = be32(sb + 8);
                                    for (uint32_t k = 0; k < cnt; k++) {
                                        if (be32(sb + 12 + k * 8) == 0) {
                                            const uint8_t *cd = sb + be32(sb + 12 + k * 8 + 4);
                                            uint32_t ver = be32(cd + 8);
                                            uint32_t fl = be32(cd + 12);
                                            uint32_t es = ver >= 0x20100 ? be32(cd + 80) : 0;
                                            char tmp[220];
                                            snprintf(tmp, sizeof(tmp), "ver=0x%x flags=0x%x execSegFlags=0x%x CAN_LOAD=%s CAN_EXEC=%s", ver, fl, es, (es & 0x100) ? "有" : "無", (es & 0x200) ? "有" : "無");
                                            info += tmp; found = true;
                                        }
                                    }
                                }
                                if (csize == 0) break;
                                p += csize;
                            }
                            if (!found) info += "無 CodeDirectory";
                        }
                    }
                } else info += "開主程式失敗";
                line(info);
            }
            NSString *bundleDir = [[NSBundle mainBundle] bundlePath];
            {
                NSString *srcP = [bundleDir stringByAppendingPathComponent:@"probe_ldid.dylib"];
                NSString *dstP = [dir stringByAppendingPathComponent:@"probe_ldid.dylib"];
                { std::string d; paxDumpSuperblob(srcP.UTF8String, "戊原簽（裝機版）", d); line(d); }
                { std::string d; paxDumpReq(srcP.UTF8String, "戊req", d); line(d); }
                { std::string d; paxDumpReq([[NSBundle mainBundle] executablePath].UTF8String, "主程式req", d); line(d); }
                [fm removeItemAtPath:dstP error:nil];
                if ([fm copyItemAtPath:srcP toPath:dstP error:nil]) {
                    void *h = dlopen(dstP.UTF8String, RTLD_NOW);
                    if (!h) line(std::string("G4[戊 ldid簽探針]：dlopen 失敗：") + (dlerror() ?: "(null)"));
                    else {
                        auto fn = (int (*)(void))dlsym(h, "paxidx_g_answer");
                        line(std::string("G4[戊 ldid簽探針]：dlopen 成功，answer=") + (fn ? std::to_string(fn()) : std::string("dlsym失敗")));
                    }
                } else line("G4[戊]：bundle 內找不到 probe_ldid.dylib");
            }
            {
                NSString *srcP = [bundleDir stringByAppendingPathComponent:@"syntax_codesign.dylib"];
                NSString *dstP = [dir stringByAppendingPathComponent:@"syntax_codesign.dylib"];
                [fm removeItemAtPath:dstP error:nil];
                if ([fm copyItemAtPath:srcP toPath:dstP error:nil]) {
                    void *h = dlopen(dstP.UTF8String, RTLD_NOW);
                    line(std::string("G4[己 codesign重簽良品]：dlopen ") + (h ? "成功" : std::string("失敗：") + (dlerror() ?: "(null)")));
                } else line("G4[己]：bundle 內找不到 syntax_codesign.dylib");
            {
                NSString *srcP = [bundleDir stringByAppendingPathComponent:@"syntax_codesign.dylib"];
                NSString *dstP = [dir stringByAppendingPathComponent:@"syntax_ours2.dylib"];
                [fm removeItemAtPath:dstP error:nil];
                if ([fm copyItemAtPath:srcP toPath:dstP error:nil]) {
                    std::string gdetail;
                    bool gok = paxAdhocSignMachO(dstP.UTF8String, gdetail);
                    line(std::string("G6[庚 簽名器@codesign良品]：") + gdetail);
                    { std::string d; paxDumpSuperblob(dstP.UTF8String, "庚產出", d); line(d); }
                    if (gok) {
                        void *h = dlopen(dstP.UTF8String, RTLD_NOW);
                        line(std::string("G6[庚 簽名器重簽codesign良品]：dlopen ") + (h ? "成功" : std::string("失敗：") + (dlerror() ?: "(null)")));
                    }
                } else line("G6[庚]：複製 codesign 良品失敗");
            }

            }
            nyxMark("G4 done");
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
            // ---- S 影子介面集 ----
            // #131 stderr 定案：裝置 SDK 的 Swift.swiftmodule 是自家 6.2.4 疊加的
            // 二進制模塊，6.3.3 前端拒收（cannot be imported）；二進制在場會遮住
            // 可跨版讀的 .swiftinterface。把 usr/lib/swift 複製到 tmp、剝掉所有
            // 二進制 .swiftmodule「檔案」（同名目錄保留），-I 與 -resource-dir
            // 改指影子集。
            NSString *shadow = [dir stringByAppendingPathComponent:@"swiftshadow"];
            {
                [fm removeItemAtPath:shadow error:nil];
                [fm createDirectoryAtPath:shadow withIntermediateDirectories:YES attributes:nil error:nil];
                NSUInteger stripped = 0, copied = 0;
                NSDirectoryEnumerator *en = [fm enumeratorAtPath:swiftRes];
                NSString *rel;
                while ((rel = [en nextObject])) {
                    NSString *from = [swiftRes stringByAppendingPathComponent:rel];
                    NSString *to = [shadow stringByAppendingPathComponent:rel];
                    BOOL isDir = NO;
                    [fm fileExistsAtPath:from isDirectory:&isDir];
                    if (isDir) {
                        [fm createDirectoryAtPath:to withIntermediateDirectories:YES attributes:nil error:nil];
                    } else if ([rel.pathExtension isEqualToString:@"swiftmodule"]) {
                        stripped++;
                    } else {
                        [fm copyItemAtPath:from toPath:to error:nil];
                        copied++;
                    }
                }
                line("S：影子介面集已建（複製 " + std::to_string(copied) + " 檔、剝二進制模塊 " + std::to_string(stripped) + " 檔）");
            }
            if ([fm fileExistsAtPath:sobj]) {
                unsigned long long sz = [[fm attributesOfItemAtPath:sobj error:nil] fileSize];
                line("S1 產物 probe_swift.o 已生成，大小 " + std::to_string(sz) + " 位元組");
            } else {
                line("S1 無產物，接著試 S2 直打前端");
                // S2 第一輪（136ms／零診斷／無產物）參數形狀有誤：輸入檔只掛在
                // -primary-file 後面、沒有以普通輸入出現（真 swiftc 的前端命令行
                // 兩處都有）。S2a 補回普通輸入；S2b 再砍到最小集對照。
                // 輸入只掛 -primary-file（S2a 證實加普通輸入會 duplicate）；
                // 模塊改吃影子介面集：-I 影子在前、-resource-dir 亦指影子。
                // S3 證實：stdlib 走 -sdk 寫死的路徑載入，-I／-resource-dir 壓不過。
                // 改建「影子 SDK」：目錄骨架用符號連結回原 SDK、只有 usr/lib/swift
                // 換成介面影子集，-sdk 改指影子 SDK。
                // 包內若有原始介面集（CI 內嵌的 NyxInterfaces，原始 SDK 未疊加版，
                // 只有 .swiftinterface）優先用它當影子來源；裝置 SDK 那份被自家
                // 6.2.4 疊加換成純二進制包、剝完沒東西可讀（S4 定案）。
                NSString *pristine = [[NSBundle mainBundle] pathForResource:@"NyxInterfaces" ofType:nil];
                NSString *swiftForSDK = pristine ?: shadow;
                if (pristine) line("S：改用包內原始介面集 NyxInterfaces");
                NSString *ssdk = [dir stringByAppendingPathComponent:@"shadowSDK"];
                {
                    [fm removeItemAtPath:ssdk error:nil];
                    [fm createDirectoryAtPath:ssdk withIntermediateDirectories:YES attributes:nil error:nil];
                    for (NSString *name in [fm contentsOfDirectoryAtPath:sdk error:nil] ?: @[]) {
                        if ([name isEqualToString:@"usr"] || [name isEqualToString:@"System"]) continue;
                        [fm createSymbolicLinkAtPath:[ssdk stringByAppendingPathComponent:name]
                            withDestinationPath:[sdk stringByAppendingPathComponent:name] error:nil];
                    }
                    NSString *sdkUsr = [sdk stringByAppendingPathComponent:@"usr"];
                    NSString *ssdkUsr = [ssdk stringByAppendingPathComponent:@"usr"];
                    [fm createDirectoryAtPath:ssdkUsr withIntermediateDirectories:YES attributes:nil error:nil];
                    for (NSString *name in [fm contentsOfDirectoryAtPath:sdkUsr error:nil] ?: @[]) {
                        if ([name isEqualToString:@"lib"]) continue;
                        [fm createSymbolicLinkAtPath:[ssdkUsr stringByAppendingPathComponent:name]
                            withDestinationPath:[sdkUsr stringByAppendingPathComponent:name] error:nil];
                    }
                    NSString *sdkLib = [sdkUsr stringByAppendingPathComponent:@"lib"];
                    NSString *ssdkLib = [ssdkUsr stringByAppendingPathComponent:@"lib"];
                    [fm createDirectoryAtPath:ssdkLib withIntermediateDirectories:YES attributes:nil error:nil];
                    for (NSString *name in [fm contentsOfDirectoryAtPath:sdkLib error:nil] ?: @[]) {
                        if ([name isEqualToString:@"swift"]) continue;
                        [fm createSymbolicLinkAtPath:[ssdkLib stringByAppendingPathComponent:name]
                            withDestinationPath:[sdkLib stringByAppendingPathComponent:name] error:nil];
                    }
                    [fm createSymbolicLinkAtPath:[ssdkLib stringByAppendingPathComponent:@"swift"]
                        withDestinationPath:swiftForSDK error:nil];
                    // S8：框架的 .swiftmodule 同樣被自家 6.2.4 疊加成二進制
                    // （S7 實證 Foundation 段同錯）。System 改實目錄逐層建：
                    // Frameworks 逐個框架換上包內原始 Modules（NyxFwModules）。
                    NSString *fwPristine = [[NSBundle mainBundle] pathForResource:@"NyxFwModules" ofType:nil];
                    {
                        NSString *sdkSys = [sdk stringByAppendingPathComponent:@"System"];
                        NSString *ssdkSys = [ssdk stringByAppendingPathComponent:@"System"];
                        [fm createDirectoryAtPath:ssdkSys withIntermediateDirectories:YES attributes:nil error:nil];
                        for (NSString *name in [fm contentsOfDirectoryAtPath:sdkSys error:nil] ?: @[]) {
                            if ([name isEqualToString:@"Library"]) continue;
                            [fm createSymbolicLinkAtPath:[ssdkSys stringByAppendingPathComponent:name]
                                withDestinationPath:[sdkSys stringByAppendingPathComponent:name] error:nil];
                        }
                        NSString *sdkSL = [sdkSys stringByAppendingPathComponent:@"Library"];
                        NSString *ssdkSL = [ssdkSys stringByAppendingPathComponent:@"Library"];
                        [fm createDirectoryAtPath:ssdkSL withIntermediateDirectories:YES attributes:nil error:nil];
                        for (NSString *name in [fm contentsOfDirectoryAtPath:sdkSL error:nil] ?: @[]) {
                            if ([name isEqualToString:@"Frameworks"]) continue;
                            [fm createSymbolicLinkAtPath:[ssdkSL stringByAppendingPathComponent:name]
                                withDestinationPath:[sdkSL stringByAppendingPathComponent:name] error:nil];
                        }
                        NSString *sdkFw = [sdkSL stringByAppendingPathComponent:@"Frameworks"];
                        NSString *ssdkFw = [ssdkSL stringByAppendingPathComponent:@"Frameworks"];
                        [fm createDirectoryAtPath:ssdkFw withIntermediateDirectories:YES attributes:nil error:nil];
                        int fwSwapped = 0;
                        for (NSString *name in [fm contentsOfDirectoryAtPath:sdkFw error:nil] ?: @[]) {
                            NSString *pfwModules = fwPristine ? [[fwPristine stringByAppendingPathComponent:name] stringByAppendingPathComponent:@"Modules"] : nil;
                            if (pfwModules && [fm fileExistsAtPath:pfwModules]) {
                                NSString *ofw = [sdkFw stringByAppendingPathComponent:name];
                                NSString *sfw = [ssdkFw stringByAppendingPathComponent:name];
                                [fm createDirectoryAtPath:sfw withIntermediateDirectories:YES attributes:nil error:nil];
                                for (NSString *sub in [fm contentsOfDirectoryAtPath:ofw error:nil] ?: @[]) {
                                    if ([sub isEqualToString:@"Modules"]) continue;
                                    [fm createSymbolicLinkAtPath:[sfw stringByAppendingPathComponent:sub]
                                        withDestinationPath:[ofw stringByAppendingPathComponent:sub] error:nil];
                                }
                                [fm createSymbolicLinkAtPath:[sfw stringByAppendingPathComponent:@"Modules"]
                                    withDestinationPath:pfwModules error:nil];
                                fwSwapped++;
                            } else {
                                [fm createSymbolicLinkAtPath:[ssdkFw stringByAppendingPathComponent:name]
                                    withDestinationPath:[sdkFw stringByAppendingPathComponent:name] error:nil];
                            }
                        }
                        line("S：影子 SDK 已建（usr/lib/swift→原始介面集，Frameworks 換原始 Modules " + std::to_string(fwSwapped) + " 個，其餘符號連結回原 SDK）");
                    }
                }
                // S7：SwiftShims 是靠 resource-dir 頂層 module.modulemap 的 extern
                // module 宣告登記的（Nyxian 的 BSROOT/swift 有這張表）；SDK 的
                // usr/lib/swift 只有 shims/ 本體、沒有頂層表，指哪個 SDK 目錄都
                // 登記不到（S5／S6 實證同錯）。以介面集的 shims 在 tmp 現場組
                // 一個合規 resource-dir。
                NSString *resDir = [dir stringByAppendingPathComponent:@"nyxres"];
                {
                    [fm removeItemAtPath:resDir error:nil];
                    [fm createDirectoryAtPath:resDir withIntermediateDirectories:YES attributes:nil error:nil];
                    NSString *nyxRes = [[NSBundle mainBundle] pathForResource:@"NyxRes" ofType:nil];
                    NSString *shimsSrc = nyxRes ? [nyxRes stringByAppendingPathComponent:@"shims"]
                                                 : [swiftForSDK stringByAppendingPathComponent:@"shims"];
                    [fm copyItemAtPath:shimsSrc
                        toPath:[resDir stringByAppendingPathComponent:@"shims"] error:nil];
                    if (nyxRes) {
                        // S9：clang 內建頭（stddef.h 等）也進 resource-dir——缺它時
                        // SDK 的 c_standard_library.modulemap 守衛模塊 _stddef 會以
                        // found_incompatible_headers__check_search_paths 報錯（S8 實證）
                        [fm copyItemAtPath:[nyxRes stringByAppendingPathComponent:@"clang"]
                            toPath:[resDir stringByAppendingPathComponent:@"clang"] error:nil];
                        line("S：resource-dir 併入 NyxRes 的 shims＋clang 內建頭（BSROOT 本尊）");
                    }
                    NSString *topMap = @"extern module SwiftShims             \"shims/module.modulemap\"\nextern module _SwiftConcurrencyShims \"shims/module.modulemap\"\nextern module SwiftOverlayShims      \"shims/module.modulemap\"\n";
                    [topMap writeToFile:[resDir stringByAppendingPathComponent:@"module.modulemap"] atomically:YES encoding:NSUTF8StringEncoding error:nil];
                    line("S：合規 resource-dir 已組（shims 複製＋頂層 module.modulemap 已寫）");
                }
                // S10：他們的打包法——App 自帶 PaxSDK.zip（完整乾淨 SDK＋
                // BSROOT res），Swift 側 bootstrap 已解壓到 Documents/PaxSDK。
                // 就位就直指（不走影子／拼裝），缺位才退回 S9 影子配方。
                NSString *docsDir = NSSearchPathForDirectoriesInDomains(NSDocumentDirectory, NSUserDomainMask, YES).firstObject;
                NSString *paxSDKRoot = [docsDir stringByAppendingPathComponent:@"PaxSDK"];
                NSString *bundledSDK = nyxPackagedSDKPath() ?: [paxSDKRoot stringByAppendingPathComponent:@"iPhoneOS.sdk"];
                NSString *bundledRes = [paxSDKRoot stringByAppendingPathComponent:@"res"];
                BOOL bundledOK = ([fm fileExistsAtPath:[bundledSDK stringByAppendingPathComponent:@"usr/lib/swift/Swift.swiftmodule/arm64-apple-ios.swiftinterface"]]
                               || [fm fileExistsAtPath:[bundledSDK stringByAppendingPathComponent:@"usr/lib/swift/Swift.swiftmodule/arm64e-apple-ios.swiftinterface"]])
                               && [fm fileExistsAtPath:[bundledRes stringByAppendingPathComponent:@"module.modulemap"]]
                               && [fm fileExistsAtPath:[bundledRes stringByAppendingPathComponent:@"clang/include/stddef.h"]];
                if (bundledOK) {
                    line("S：包內 SDK 已就位（Documents/PaxSDK），S10 直指打包 SDK");
                    runJobT(2, @[@"-frontend", @"-c", @"-primary-file", ssrc, @"-target", @"arm64-apple-ios15.0",
                        @"-sdk", bundledSDK, @"-resource-dir", bundledRes, @"-module-cache-path", scache,
                        @"-o", sobj, @"-module-name", @"PaxProbe", @"-enable-objc-interop", @"-parse-as-library"], "S10(打包SDK直指)");
                } else {
                    line("S：包內 SDK 未就位，退回 S9 影子配方");
                    runJobT(2, @[@"-frontend", @"-c", @"-primary-file", ssrc, @"-target", @"arm64-apple-ios15.0",
                        @"-sdk", ssdk, @"-resource-dir", resDir, @"-module-cache-path", scache,
                        @"-o", sobj, @"-module-name", @"PaxProbe", @"-enable-objc-interop", @"-parse-as-library"], "S9(影子配方)");
                }
                if (![fm fileExistsAtPath:sobj]) {
                    runJobT(2, @[@"-frontend", @"-c", @"-primary-file", ssrc, @"-target", @"arm64-apple-ios15.0",
                        @"-sdk", sdk, @"-resource-dir", swiftRes, @"-module-cache-path", scache,
                        @"-o", sobj, @"-module-name", @"PaxProbe", @"-enable-objc-interop", @"-parse-as-library"], "S2(前端直打原形對照)");
                }
                if ([fm fileExistsAtPath:sobj]) {
                    unsigned long long sz = [[fm attributesOfItemAtPath:sobj error:nil] fileSize];
                    line("S10/S9/S2 產物 probe_swift.o 已生成，大小 " + std::to_string(sz) + " 位元組");
                } else {
                    line("S10/S9/S2 亦無產物");
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

// ---- 整合正式路：通用 CCJob 執行（專案編譯用）----
static void *paxCCHandle = NULL;
static CCJobCreateFn paxCCJobCreate = NULL;
static CCJobExecuteJobFn paxCCJobExecute = NULL;
static CCDiagnosticGetLevelFn paxCCDiagLevel = NULL;
static CCDiagnosticGetMessageFn paxCCDiagMessage = NULL;
static CCDriverCreateFn paxCCDriverCreate = NULL;
static PaxCCDriverCreateJobsFn paxCCDriverCreateJobs = NULL;
static CCDriverSetOutputPathCallbackFn paxCCDriverSetCallback = NULL;
static CCJobGetTypeFn paxCCJobGetType = NULL;
static CCJobGetArgumentsFn paxCCJobGetArguments = NULL;
static int paxCCState = 0; // 0 未試、1 可用、2 未內嵌、3 載入失敗

static int paxCCEnsureLoaded(void) {
    if (paxCCState != 0) return paxCCState;
    NSFileManager *fm = [NSFileManager defaultManager];
    NSString *fwPath = [[[NSBundle mainBundle] bundlePath]
        stringByAppendingPathComponent:@"Frameworks/CoreCompiler.framework/CoreCompiler"];
    if (![fm fileExistsAtPath:fwPath]) { paxCCState = 2; return paxCCState; }
    void *h = dlopen(fwPath.UTF8String, RTLD_NOW | RTLD_GLOBAL);
    if (!h) { paxCCState = 3; return paxCCState; }
    paxCCHandle = h;
    paxCCJobCreate = (CCJobCreateFn)dlsym(h, "CCJobCreate");
    paxCCJobExecute = (CCJobExecuteJobFn)dlsym(h, "CCJobExecuteJob");
    paxCCDiagLevel = (CCDiagnosticGetLevelFn)dlsym(h, "CCDiagnosticGetLevel");
    paxCCDiagMessage = (CCDiagnosticGetMessageFn)dlsym(h, "CCDiagnosticGetMessage");
    paxCCDriverCreate = (CCDriverCreateFn)dlsym(h, "CCDriverCreate");
    paxCCDriverCreateJobs = (PaxCCDriverCreateJobsFn)dlsym(h, "CCDriverCreateJobs");
    paxCCDriverSetCallback = (CCDriverSetOutputPathCallbackFn)dlsym(h, "CCDriverSetOutputPathCallback");
    paxCCJobGetType = (CCJobGetTypeFn)dlsym(h, "CCJobGetType");
    paxCCJobGetArguments = (CCJobGetArgumentsFn)dlsym(h, "CCJobGetArguments");
    paxCCState = (paxCCJobCreate && paxCCJobExecute) ? 1 : 3;
    return paxCCState;
}

extern "C" int paxidx_cc_job(int type, int argc, const char * const *argv,
                             char *report, size_t capacity) {
    static const char *kCCLevelNames[] = {"note", "remark", "warning", "error", "fatal", "unknown"};
    int st = paxCCEnsureLoaded();
    if (st == 2) { copyDiag("未內嵌 CoreCompiler.framework", report, capacity); return 2; }
    if (st != 1) { copyDiag("CoreCompiler 載入失敗", report, capacity); return 1; }
    NSMutableArray *args = [NSMutableArray arrayWithCapacity:(NSUInteger)argc];
    for (int i = 0; i < argc; i++) [args addObject:[NSString stringWithUTF8String:argv[i]]];
    CCJobRef2 job = paxCCJobCreate(nyxZeroAllocator(), (uint8_t)type, (__bridge CFArrayRef)args);
    if (!job) { copyDiag("CCJobCreate 回傳空", report, capacity); return 1; }
    // 前端／連結器的 invocation 級錯誤走 stderr、不進診斷陣列：執行期間把
    // fd 1/2 轉到暫存檔，結束後讀回（照實測頁 runJobT 的做法）
    NSString *errFile = [NSTemporaryDirectory() stringByAppendingPathComponent:@"paxcc_stderr.txt"];
    NSFileManager *fm = [NSFileManager defaultManager];
    [fm removeItemAtPath:errFile error:nil];
    fflush(stdout); fflush(stderr);
    int savedOut = dup(1), savedErr = dup(2);
    FILE *errFp = fopen(errFile.UTF8String, "w");
    if (errFp) { dup2(fileno(errFp), 1); dup2(fileno(errFp), 2); }
    CFArrayRef diags = NULL;
    CFStringRef mainSrc = NULL;
    Boolean success = paxCCJobExecute(job, &diags, &mainSrc);
    if (errFp) {
        fflush(stdout); fflush(stderr);
        dup2(savedOut, 1); dup2(savedErr, 2);
        fclose(errFp);
    }
    if (savedOut >= 0) close(savedOut);
    if (savedErr >= 0) close(savedErr);
    std::string out;
    if (diags && paxCCDiagLevel && paxCCDiagMessage) {
        CFIndex nd = CFArrayGetCount(diags);
        for (CFIndex d = 0; d < nd; d++) {
            CCDiagnosticRef2 dg = (CCDiagnosticRef2)CFArrayGetValueAtIndex(diags, d);
            uint8_t lv = paxCCDiagLevel(dg);
            CFStringRef msg = paxCCDiagMessage(dg);
            std::string m = msg ? ([(__bridge NSString *)msg UTF8String] ?: "") : "";
            out += std::string("diag[") + kCCLevelNames[lv <= 5 ? lv : 5] + "] " + m + "\n";
        }
    }
    NSString *cap = [NSString stringWithContentsOfFile:errFile encoding:NSUTF8StringEncoding error:nil];
    if (cap.length > 0) {
        if (cap.length > 6000) cap = [cap substringToIndex:6000];
        out += cap.UTF8String;
    }
    if (diags) CFRelease(diags);
    if (mainSrc) CFRelease(mainSrc);
    CFRelease(job);
    copyDiag(out.c_str(), report, capacity);
    return success ? 0 : 1;
}

// MARK: - clang driver 組裝路（CCDriver）

// .o 導向 buildDir：回傳字串按 Create 規則（框架端用完 CFRelease）
static CFStringRef paxDriverOutputPath(const char *baseInput, bool *skip, void *context) {
    (void)skip;
    if (!baseInput || !context) return NULL;
    NSString *input = [NSString stringWithUTF8String:baseInput];
    NSString *stem = [[input lastPathComponent] stringByDeletingPathExtension];
    NSString *dir = [NSString stringWithUTF8String:(const char *)context];
    NSString *out = [dir stringByAppendingPathComponent:[stem stringByAppendingPathExtension:@"o"]];
    return CFStringCreateWithCString(NULL, [out UTF8String], kCFStringEncodingUTF8);
}

// 執行單個已存在的 CCJob，診斷與 stderr 併入 out（做法照 paxidx_cc_job）
static Boolean paxRunOneJob(CCJobRef2 job, std::string &out) {
    static const char *kLv[] = {"note", "remark", "warning", "error", "fatal", "unknown"};
    NSString *errFile = [NSTemporaryDirectory() stringByAppendingPathComponent:@"paxdrv_stderr.txt"];
    NSFileManager *fm = [NSFileManager defaultManager];
    [fm removeItemAtPath:errFile error:nil];
    fflush(stdout); fflush(stderr);
    int savedOut = dup(1), savedErr = dup(2);
    FILE *errFp = fopen([errFile UTF8String], "w");
    if (errFp) { dup2(fileno(errFp), 1); dup2(fileno(errFp), 2); }
    CFArrayRef diags = NULL;
    CFStringRef mainSrc = NULL;
    Boolean success = paxCCJobExecute(job, &diags, &mainSrc);
    if (errFp) {
        fflush(stdout); fflush(stderr);
        dup2(savedOut, 1); dup2(savedErr, 2);
        fclose(errFp);
    }
    if (savedOut >= 0) close(savedOut);
    if (savedErr >= 0) close(savedErr);
    if (diags && paxCCDiagLevel && paxCCDiagMessage) {
        CFIndex nd = CFArrayGetCount(diags);
        for (CFIndex d = 0; d < nd; d++) {
            CCDiagnosticRef2 dg = (CCDiagnosticRef2)CFArrayGetValueAtIndex(diags, d);
            uint8_t lv = paxCCDiagLevel(dg);
            CFStringRef msg = paxCCDiagMessage(dg);
            std::string m = msg ? ([(__bridge NSString *)msg UTF8String] ?: "") : "";
            out += std::string("diag[") + kLv[lv <= 5 ? lv : 5] + "] " + m + "\n";
        }
    }
    NSString *cap = [NSString stringWithContentsOfFile:errFile encoding:NSUTF8StringEncoding error:nil];
    if (cap.length > 0) {
        if (cap.length > 6000) cap = [cap substringToIndex:6000];
        out += [cap UTF8String];
    }
    if (diags) CFRelease(diags);
    if (mainSrc) CFRelease(mainSrc);
    return success;
}

extern "C" int paxidx_cc_driver(const char *buildDir, int argc, const char * const *argv,
                                char *report, size_t capacity) {
    int st = paxCCEnsureLoaded();
    if (st == 2) { copyDiag("未內嵌 CoreCompiler.framework", report, capacity); return 2; }
    if (st != 1) { copyDiag("CoreCompiler 載入失敗", report, capacity); return 1; }
    if (!paxCCDriverCreate || !paxCCDriverCreateJobs) {
        copyDiag("框架缺 CCDriver 符號", report, capacity); return 1;
    }
    NSMutableArray *args = [NSMutableArray arrayWithCapacity:(NSUInteger)argc];
    for (int i = 0; i < argc; i++) [args addObject:[NSString stringWithUTF8String:argv[i]]];
    CCDriverRef2 driver = paxCCDriverCreate(nyxZeroAllocator(), (__bridge CFArrayRef)args, 0);
    if (!driver) { copyDiag("CCDriverCreate 回傳空", report, capacity); return 1; }
    if (paxCCDriverSetCallback) {
        paxCCDriverSetCallback(driver, paxDriverOutputPath, (void *)buildDir);
    }
    CFArrayRef jobs = paxCCDriverCreateJobs(driver);
    if (!jobs) {
        CFRelease(driver);
        copyDiag("CCDriverCreateJobs 回傳空（driver 展開失敗）", report, capacity);
        return 1;
    }
    std::string out;
    CFIndex n = CFArrayGetCount(jobs);
    out += "driver 展開 " + std::to_string((long)n) + " 個 job\n";
    int rc = 0;
    for (CFIndex i = 0; i < n; i++) {
        CCJobRef2 job = (CCJobRef2)CFArrayGetValueAtIndex(jobs, i);
        uint8_t jt = paxCCJobGetType ? paxCCJobGetType(job) : 255;
        out += "job[" + std::to_string((long)i) + "] type=" + std::to_string(jt) + "\n";
        std::string one;
        Boolean ok = paxRunOneJob(job, one);
        out += one;
        if (!ok) {
            out += "job[" + std::to_string((long)i) + "] 失敗，其展開參數：\n";
            if (paxCCJobGetArguments) {
                CFArrayRef ja = paxCCJobGetArguments(job);
                if (ja) {
                    CFIndex nj = CFArrayGetCount(ja);
                    for (CFIndex j = 0; j < nj; j++) {
                        CFStringRef s = (CFStringRef)CFArrayGetValueAtIndex(ja, j);
                        const char *cs = s ? [(__bridge NSString *)s UTF8String] : NULL;
                        out += "  ";
                        out += cs ? cs : "?";
                        out += "\n";
                    }
                }
            }
            rc = 1;
            break;
        }
    }
    CFRelease(jobs);
    CFRelease(driver);
    copyDiag(out.c_str(), report, capacity);
    return rc;
}

// ==== 證書簽名模塊（2026-10-30，照 ZSign 作法：真 CMS 簽名，非 graft）====
#include <Security/Security.h>
#include <algorithm>
#include <initializer_list>
#include <ctime>
namespace {

// ---------- ASN.1 DER 讀寫 ----------
struct DerNode { uint8_t tag; size_t hdr; size_t len; size_t total; };
bool derRead(const uint8_t* b, size_t n, size_t off, DerNode& nd) {
    if (off + 2 > n) return false;
    nd.tag = b[off];
    uint8_t lb = b[off + 1];
    if (!(lb & 0x80)) { nd.len = lb; nd.hdr = 2; }
    else {
        int nb = lb & 0x7f;
        if (nb == 0 || nb > 4 || off + 2 + nb > n) return false;
        nd.len = 0; nd.hdr = 2 + nb;
        for (int i = 0; i < nb; i++) nd.len = (nd.len << 8) | b[off + 2 + i];
    }
    nd.total = nd.hdr + nd.len;
    return off + nd.total <= n;
}
const uint8_t* derVal(const uint8_t* b, size_t off, const DerNode& nd) { return b + off + nd.hdr; }
bool derChild(const uint8_t* b, size_t n, size_t parentOff, const DerNode& parent, int idx, size_t& childOff, DerNode& child) {
    size_t cur = parentOff + parent.hdr;
    size_t end = cur + parent.len;
    for (int i = 0; i <= idx; i++) {
        if (cur >= end) return false;
        if (!derRead(b, n, cur, child)) return false;
        if (i == idx) { childOff = cur; return true; }
        cur += child.total;
    }
    return false;
}
bool oidEq(const uint8_t* b, size_t off, const DerNode& nd, const uint8_t* oidDer, size_t oidLen) {
    return nd.tag == 0x06 && nd.total == oidLen && memcmp(b + off, oidDer, oidLen) == 0;
}
std::string oidToString(const uint8_t* v, size_t n) {
    if (n == 0) return "";
    std::string s = std::to_string(v[0] / 40) + "." + std::to_string(v[0] % 40);
    uint64_t val = 0;
    for (size_t i = 1; i < n; i++) {
        val = (val << 7) | (v[i] & 0x7f);
        if (!(v[i] & 0x80)) { s += "." + std::to_string(val); val = 0; }
    }
    return s;
}

struct DerBuf {
    std::vector<uint8_t> d;
    void u8(uint8_t v) { d.push_back(v); }
    void bytes(const void* p, size_t n) { const uint8_t* q = (const uint8_t*)p; d.insert(d.end(), q, q + n); }
    void bytes(const std::vector<uint8_t>& v) { d.insert(d.end(), v.begin(), v.end()); }
    void len(size_t n) {
        if (n < 128) { u8((uint8_t)n); return; }
        uint8_t tmp[8]; int c = 0; size_t x = n;
        while (x) { tmp[7 - c] = (uint8_t)(x & 0xff); x >>= 8; c++; }
        u8(0x80 | c); bytes(tmp + 8 - c, c);
    }
    void tlv(uint8_t tag, const std::vector<uint8_t>& content) { u8(tag); len(content.size()); bytes(content); }
    std::vector<uint8_t> tlvv(uint8_t tag, const std::vector<uint8_t>& content) {
        DerBuf b; b.tlv(tag, content); return b.d;
    }
};
std::vector<uint8_t> derOID(std::initializer_list<uint8_t> content) {
    DerBuf b; b.u8(0x06); b.len(content.size()); for (uint8_t c : content) b.u8(c); return b.d;
}
std::vector<uint8_t> derInt(long v) {
    uint8_t tmp[8]; int c = 0; long x = v;
    do { tmp[7 - c] = (uint8_t)(x & 0xff); x >>= 8; c++; } while (x > 0 && c < 8);
    if (tmp[8 - c] & 0x80) { c++; tmp[8 - c] = 0; }
    DerBuf b; b.u8(0x02); b.len(c); b.bytes(tmp + 8 - c, c); return b.d;
}
std::vector<uint8_t> derCat(std::initializer_list<std::vector<uint8_t>> parts) {
    DerBuf b; for (auto& p : parts) b.bytes(p); return b.d;
}

// ---------- 身份全域狀態 ----------
static NSData* gCertDER = nil;        // leaf 證書 DER
static SecKeyRef gPrivKey = NULL;     // 私鑰
static std::string gLeafCN, gLeafOU, gLeafUID, gLeafIssuerStr, gLeafValidStr;
static std::vector<uint8_t> gLeafIssuerTLV, gLeafSerialTLV;
static NSData* gProfileData = nil;    // 描述檔原始檔
static std::string gProfileInfo, gProfileTeam, gProfileAppId; // appId = 完整 application-identifier
static std::vector<uint8_t> gProfileEntXML; // 從 profile 取出的 Entitlements 字典 XML（round 2 用）

std::string fmtTime(const uint8_t* v, size_t n, bool gen) {
    std::string s((const char*)v, n);
    if (!gen && n >= 13) return "20" + s.substr(0, 2) + "-" + s.substr(2, 2) + "-" + s.substr(4, 2) + " " + s.substr(6, 2) + ":" + s.substr(8, 2) + " UTC";
    if (gen && n >= 15) return s.substr(0, 4) + "-" + s.substr(4, 2) + "-" + s.substr(6, 2) + " " + s.substr(9, 2) + ":" + s.substr(11, 2) + " UTC";
    return s;
}

// 解析 X.509：抽 serial/issuer/subject/validity TLV 與 RDN 值
bool parseCert(const uint8_t* b, size_t n, std::string& err) {
    DerNode cert, tbs, nd; size_t off;
    if (!derRead(b, n, 0, cert) || cert.tag != 0x30) { err = "cert 非 SEQUENCE"; return false; }
    if (!derChild(b, n, 0, cert, 0, off, nd) || nd.tag != 0x30) { err = "tbs 缺失"; return false; }
    size_t tbsOff = off; DerNode t = nd;
    int idx = 0; size_t co; DerNode c;
    if (!derChild(b, n, tbsOff, t, 0, co, c)) { err = "tbs 空"; return false; }
    if (c.tag == 0xa0) idx = 1; // version [0]
    if (!derChild(b, n, tbsOff, t, idx, co, c) || c.tag != 0x02) { err = "serial 缺失"; return false; }
    gLeafSerialTLV.assign(b + co, b + co + c.total);
    if (!derChild(b, n, tbsOff, t, idx + 2, co, c) || c.tag != 0x30) { err = "issuer 缺失"; return false; }
    gLeafIssuerTLV.assign(b + co, b + co + c.total);
    // issuer RDN 字串
    {
        std::string s; size_t cur = co + c.hdr, end = cur + c.len; DerNode setNd; size_t vo0 = 0;
        while (cur < end && derRead(b, n, cur, setNd)) {
            size_t sc = cur + setNd.hdr, se = sc + setNd.len; DerNode av;
            while (sc < se && derRead(b, n, sc, av)) {
                size_t vo; DerNode ov, vv;
                if (derChild(b, n, sc, av, 0, vo0, ov) && derChild(b, n, sc, av, 1, vo, vv)) {
                    const uint8_t* val = derVal(b, vo, vv);
                    if (vv.tag == 0x0c || vv.tag == 0x13 || vv.tag == 0x16) {
                        if (!s.empty()) s += ", ";
                        s += oidToString(derVal(b, vo0, ov), ov.len) + "=" + std::string((const char*)val, vv.len);
                    }
                }
                sc += av.total;
            }
            cur += setNd.total;
        }
        gLeafIssuerStr = s;
    }
    if (!derChild(b, n, tbsOff, t, idx + 3, co, c) || c.tag != 0x30) { err = "validity 缺失"; return false; }
    {
        size_t vo, vo0; DerNode f, u;
        if (derChild(b, n, co, c, 0, vo0, f) && derChild(b, n, co, c, 1, vo, u)) {
            gLeafValidStr = fmtTime(derVal(b, vo0, f), f.len, f.tag == 0x18) + " ~ " + fmtTime(derVal(b, vo, u), u.len, u.tag == 0x18);
        }
    }
    if (!derChild(b, n, tbsOff, t, idx + 4, co, c) || c.tag != 0x30) { err = "subject 缺失"; return false; }
    {
        gLeafCN.clear(); gLeafOU.clear(); gLeafUID.clear();
        size_t cur = co + c.hdr, end = cur + c.len; DerNode setNd; size_t vo0 = 0;
        while (cur < end && derRead(b, n, cur, setNd)) {
            size_t sc = cur + setNd.hdr, se = sc + setNd.len; DerNode av;
            while (sc < se && derRead(b, n, sc, av)) {
                size_t vo; DerNode ov, vv;
                if (derChild(b, n, sc, av, 0, vo0, ov) && derChild(b, n, sc, av, 1, vo, vv)) {
                    std::string oidS = oidToString(derVal(b, vo0, ov), ov.len);
                    const uint8_t* val = derVal(b, vo, vv);
                    std::string valS;
                    if (vv.tag == 0x0c || vv.tag == 0x13 || vv.tag == 0x16 || vv.tag == 0x14) valS.assign((const char*)val, vv.len);
                    if (oidS == "2.5.4.3") gLeafCN = valS;
                    else if (oidS == "2.5.4.11") gLeafOU = valS;
                    else if (oidS == "0.9.2342.19200300.100.1.1") gLeafUID = valS;
                }
                sc += av.total;
            }
            cur += setNd.total;
        }
    }
    return true;
}

// 解析未加密 PKCS#12（CodeSignKit/EiliStore 導出格式）：抽 cert DER + PKCS#8
bool parseP12(const uint8_t* b, size_t n, std::vector<uint8_t>& certOut, std::vector<uint8_t>& keyOut, std::string& err) {
    static const uint8_t OID_DATA[]   = {0x06,0x09,0x2a,0x86,0x48,0x86,0xf7,0x0d,0x01,0x07,0x01};
    static const uint8_t OID_CERTBAG[]= {0x06,0x0b,0x2a,0x86,0x48,0x86,0xf7,0x0d,0x01,0x0c,0x0a,0x01,0x03};
    static const uint8_t OID_KEYBAG[] = {0x06,0x0b,0x2a,0x86,0x48,0x86,0xf7,0x0d,0x01,0x0c,0x0a,0x01,0x01};
    static const uint8_t OID_SHROUDED[]={0x06,0x0b,0x2a,0x86,0x48,0x86,0xf7,0x0d,0x01,0x0c,0x0a,0x01,0x02};
    DerNode pfx, ci; size_t off;
    if (!derRead(b, n, 0, pfx) || pfx.tag != 0x30) { err = "PFX 非 SEQUENCE"; return false; }
    if (!derChild(b, n, 0, pfx, 1, off, ci) || ci.tag != 0x30) { err = "AuthenticatedSafe ContentInfo 缺失"; return false; }
    size_t co; DerNode oidNd, a0;
    if (!derChild(b, n, off, ci, 0, co, oidNd) || !oidEq(b, co, oidNd, OID_DATA, sizeof(OID_DATA))) { err = "外層非 data"; return false; }
    if (!derChild(b, n, off, ci, 1, co, a0) || a0.tag != 0xa0) { err = "data [0] 缺失"; return false; }
    size_t osOff; DerNode os;
    if (!derRead(b, n, co + a0.hdr, os) || os.tag != 0x04) { err = "OCTET STRING 缺失"; return false; }
    const uint8_t* asBase = derVal(b, co + a0.hdr, os);
    size_t asLen = os.len, asOff = 0; DerNode as;
    if (!derRead(asBase, asLen, 0, as) || as.tag != 0x30) { err = "AuthenticatedSafe 非 SEQUENCE"; return false; }
    bool sawEncrypted = false;
    size_t cur = as.hdr, end = as.hdr + as.len; DerNode sub;
    while (cur < end && derRead(asBase, asLen, cur, sub)) {
        if (sub.tag == 0x30) {
            size_t so, so0; DerNode soid, sa0;
            if (derChild(asBase, asLen, cur, sub, 0, so0, soid) && derChild(asBase, asLen, cur, sub, 1, so, sa0) && sa0.tag == 0xa0) {
                if (oidEq(asBase, so0, soid, OID_DATA, sizeof(OID_DATA))) {
                    size_t io; DerNode ios;
                    if (derRead(asBase, asLen, so + sa0.hdr, ios) && ios.tag == 0x04) {
                        const uint8_t* bags = derVal(asBase, so + sa0.hdr, ios);
                        size_t bl = ios.len; DerNode bagsSeq;
                        if (derRead(bags, bl, 0, bagsSeq) && bagsSeq.tag == 0x30) {
                            size_t bc = bagsSeq.hdr, be = bc + bagsSeq.len; DerNode bag;
                            while (bc < be && derRead(bags, bl, bc, bag)) {
                                size_t bo, bo0; DerNode boid, bv;
                                if (derChild(bags, bl, bc, bag, 0, bo0, boid) && derChild(bags, bl, bc, bag, 1, bo, bv) && bv.tag == 0xa0) {
                                    if (oidEq(bags, bo0, boid, OID_CERTBAG, sizeof(OID_CERTBAG))) {
                                        size_t vo; DerNode cbv, cos2;
                                        if (derRead(bags, bl, bo + bv.hdr, cbv) && cbv.tag == 0x30 &&
                                            derChild(bags, bl, bo + bv.hdr, cbv, 1, vo, cos2) && cos2.tag == 0xa0) {
                                            size_t xo; DerNode xos;
                                            if (derRead(bags, bl, vo + cos2.hdr, xos) && xos.tag == 0x04)
                                                certOut.assign(derVal(bags, vo + cos2.hdr, xos), derVal(bags, vo + cos2.hdr, xos) + xos.len);
                                        }
                                    } else if (oidEq(bags, bo0, boid, OID_KEYBAG, sizeof(OID_KEYBAG))) {
                                        keyOut.assign(bags + bo + bv.hdr, bags + bo + bv.hdr + bv.len);
                                    } else if (oidEq(bags, bo0, boid, OID_SHROUDED, sizeof(OID_SHROUDED))) {
                                        sawEncrypted = true;
                                    }
                                }
                                bc += bag.total;
                            }
                        }
                    }
                } else {
                    sawEncrypted = true; // encryptedData ContentInfo
                }
            }
        }
        cur += sub.total;
    }
    if (certOut.empty()) { err = "找不到證書（CertBag）"; return false; }
    if (keyOut.empty()) { err = sawEncrypted ? "私鑰有加密（shrouded），第一版未支援" : "找不到私鑰（KeyBag）"; return false; }
    return true;
}

std::string certSummary() {
    std::string s = "CN: " + gLeafCN + "\nOU(team): " + gLeafOU + "\nUID: " + gLeafUID +
                    "\nIssuer: " + gLeafIssuerStr + "\nValid: " + gLeafValidStr;
    return s;
}
} // namespace

extern "C" {

int paxidx_cert_import_p12(const char* path, const char* password, char* info, size_t cap) {
    (void)password; // 未加密格式不需密碼；加密格式第一版會在 parse 階段回錯
    NSData* data = [NSData dataWithContentsOfFile:[NSString stringWithUTF8String:path]];
    if (!data) { if (info && cap) snprintf(info, cap, "讀不到檔案"); return 1; }
    std::vector<uint8_t> cert, key; std::string err;
    if (!parseP12((const uint8_t*)data.bytes, data.length, cert, key, err)) {
        if (info && cap) snprintf(info, cap, "P12 解析失敗: %s", err.c_str());
        return 1;
    }
    if (!parseCert(cert.data(), cert.size(), err)) {
        if (info && cap) snprintf(info, cap, "證書解析失敗: %s", err.c_str());
        return 1;
    }
    // SecKey 私鑰建立要 PKCS#1 本體；key 是 PKCS#8（SEQ{ver, alg, OCTET{PKCS#1}}），先剝殼（本機 openssl 對照驗證逐位元組相符；真機 -50 定案）
    std::vector<uint8_t> keyForSec = key;
    {
        DerNode p8, oct; size_t oo;
        if (derRead(key.data(), key.size(), 0, p8) && p8.tag == 0x30 &&
            derChild(key.data(), key.size(), 0, p8, 2, oo, oct) && oct.tag == 0x04) {
            keyForSec.assign(key.begin() + (oo + oct.hdr), key.begin() + (oo + oct.hdr + oct.len));
        }
    }
    NSDictionary* attrs = @{ (id)kSecAttrKeyType: (id)kSecAttrKeyTypeRSA,
                             (id)kSecAttrKeyClass: (id)kSecAttrKeyClassPrivate };
    CFErrorRef cfErr = NULL;
    SecKeyRef sk = SecKeyCreateWithData((__bridge CFDataRef)[NSData dataWithBytes:keyForSec.data() length:keyForSec.size()],
                                        (__bridge CFDictionaryRef)attrs, &cfErr);
    if (!sk) {
        NSString* msg = cfErr ? [(__bridge NSError*)cfErr localizedDescription] : @"?";
        if (info && cap) snprintf(info, cap, "私鑰建立失敗: %s", [msg UTF8String]);
        if (cfErr) CFRelease(cfErr);
        return 1;
    }
    // 核對私鑰與證書公鑰相符
    SecKeyRef pub = SecKeyCopyPublicKey(sk);
    bool match = false;
    if (pub) {
        CFDataRef ext = SecKeyCopyExternalRepresentation(pub, NULL);
        if (ext) {
            // 從證書 SPKI 取 BIT STRING 內容比對
            DerNode c0, tbs, nd; size_t off;
            const uint8_t* cb = cert.data(); size_t cn = cert.size();
            if (derRead(cb, cn, 0, c0) && derChild(cb, cn, 0, c0, 0, off, tbs)) {
                int idx = 0; size_t co; DerNode f;
                if (derChild(cb, cn, off, tbs, 0, co, f) && f.tag == 0xa0) idx = 1;
                if (derChild(cb, cn, off, tbs, idx + 5, co, f) && f.tag == 0x30) {
                    size_t bo; DerNode bit;
                    if (derChild(cb, cn, co, f, 1, bo, bit) && bit.tag == 0x03 && bit.len > 1) {
                        const uint8_t* bv = derVal(cb, bo, bit);
                        match = ((size_t)CFDataGetLength(ext) == bit.len - 1) &&
                                memcmp(CFDataGetBytePtr(ext), bv + 1, bit.len - 1) == 0;
                    }
                }
            }
            CFRelease(ext);
        }
        CFRelease(pub);
    }
    if (!match) {
        if (info && cap) snprintf(info, cap, "私鑰與證書公鑰不相符（不是同一張證書的 p12）");
        CFRelease(sk);
        return 1;
    }
    if (gPrivKey) CFRelease(gPrivKey);
    gPrivKey = sk;
    gCertDER = [NSData dataWithBytes:cert.data() length:cert.size()];
    if (info && cap) snprintf(info, cap, "%s", certSummary().c_str());
    return 0;
}

int paxidx_cert_import_profile(const char* path, char* info, size_t cap) {
    NSData* data = [NSData dataWithContentsOfFile:[NSString stringWithUTF8String:path]];
    if (!data) { if (info && cap) snprintf(info, cap, "讀不到檔案"); return 1; }
    const uint8_t* b = (const uint8_t*)data.bytes; size_t n = data.length;
    const uint8_t* start = NULL; const uint8_t* stop = NULL;
    for (size_t i = 0; i + 5 < n; i++) if (!memcmp(b + i, "<?xml", 5)) { start = b + i; break; }
    if (n >= 8) { for (size_t i = n - 8;; i--) { if (!memcmp(b + i, "</plist>", 8)) { stop = b + i + 8; break; } if (i == 0) break; } }
    if (!start || !stop || stop <= start) { if (info && cap) snprintf(info, cap, "描述檔內找不到 plist"); return 1; }
    NSData* plistData = [NSData dataWithBytes:start length:(size_t)(stop - start)];
    NSError* e = nil;
    id obj = [NSPropertyListSerialization propertyListWithData:plistData options:0 format:NULL error:&e];
    if (![obj isKindOfClass:[NSDictionary class]]) { if (info && cap) snprintf(info, cap, "plist 解析失敗"); return 1; }
    NSDictionary* dict = obj;
    NSDictionary* ent = dict[@"Entitlements"];
    NSString* name = dict[@"Name"] ?: @"?";
    NSString* uuid = dict[@"UUID"] ?: @"?";
    NSDate* exp = dict[@"ExpirationDate"];
    NSString* appId = ent[@"application-identifier"] ?: @"";
    NSArray* teams = dict[@"TeamIdentifier"];
    NSString* team = teams.count ? teams[0] : (ent[@"com.apple.developer.team-identifier"] ?: @"");
    gProfileData = data;
    gProfileTeam = [team UTF8String] ?: "";
    gProfileAppId = [appId UTF8String] ?: "";
    NSDateFormatter* df = [NSDateFormatter new];
    df.dateFormat = @"yyyy-MM-dd HH:mm";
    df.timeZone = [NSTimeZone timeZoneForSecondsFromGMT:0];
    NSString* expS = exp ? [df stringFromDate:exp] : @"?";
    gProfileInfo = [[NSString stringWithFormat:@"Name: %@\nUUID: %@\nTeam: %@\nAppID: %@\nExpires: %@ (UTC)", name, uuid, team, appId, expS] UTF8String];
    // 保存 Entitlements 字典 XML（重簽時用）
    if ([ent isKindOfClass:[NSDictionary class]]) {
        NSData* entData = [NSPropertyListSerialization dataWithPropertyList:ent format:NSPropertyListXMLFormat_v1_0 options:0 error:NULL];
        if (entData) gProfileEntXML.assign((const uint8_t*)entData.bytes, (const uint8_t*)entData.bytes + entData.length);
    }
    if (info && cap) snprintf(info, cap, "%s", gProfileInfo.c_str());
    return 0;
}

int paxidx_cert_status(char* info, size_t cap) {
    if (!gCertDER) { if (info && cap) snprintf(info, cap, ""); return 1; }
    std::string s = certSummary();
    if (gProfileData) s += "\n--- 描述檔 ---\n" + gProfileInfo;
    if (info && cap) snprintf(info, cap, "%s", s.c_str());
    return 0;
}

int paxidx_cert_clear(void) {
    if (gPrivKey) { CFRelease(gPrivKey); gPrivKey = NULL; }
    gCertDER = nil; gProfileData = nil; gProfileInfo.clear(); gProfileTeam.clear(); gProfileAppId.clear(); gProfileEntXML.clear();
    return 0;
}

} // extern "C"

// ---------- 簽名器（照 ZSign：雙 CD + 真 CMS）----------
// Apple WWDR intermediates + roots (DER), extracted from zsign (public Apple certs)
static const uint8_t kWWDR_G1[1062] = {48,130,4,34,48,130,3,10,160,3,2,1,2,2,8,1,222,188,196,57,109,160,16,48,13,6,9,42,134,72,134,247,13,1,1,5,5,0,48,98,49,11,48,9,6,3,85,4,6,19,2,85,83,49,19,48,17,6,3,85,4,10,19,10,65,112,112,108,101,32,73,110,99,46,49,38,48,36,6,3,85,4,11,19,29,65,112,112,108,101,32,67,101,114,116,105,102,105,99,97,116,105,111,110,32,65,117,116,104,111,114,105,116,121,49,22,48,20,6,3,85,4,3,19,13,65,112,112,108,101,32,82,111,111,116,32,67,65,48,30,23,13,49,51,48,50,48,55,50,49,52,56,52,55,90,23,13,50,51,48,50,48,55,50,49,52,56,52,55,90,48,129,150,49,11,48,9,6,3,85,4,6,19,2,85,83,49,19,48,17,6,3,85,4,10,12,10,65,112,112,108,101,32,73,110,99,46,49,44,48,42,6,3,85,4,11,12,35,65,112,112,108,101,32,87,111,114,108,100,119,105,100,101,32,68,101,118,101,108,111,112,101,114,32,82,101,108,97,116,105,111,110,115,49,68,48,66,6,3,85,4,3,12,59,65,112,112,108,101,32,87,111,114,108,100,119,105,100,101,32,68,101,118,101,108,111,112,101,114,32,82,101,108,97,116,105,111,110,115,32,67,101,114,116,105,102,105,99,97,116,105,111,110,32,65,117,116,104,111,114,105,116,121,48,130,1,34,48,13,6,9,42,134,72,134,247,13,1,1,1,5,0,3,130,1,15,0,48,130,1,10,2,130,1,1,0,202,56,84,166,203,86,170,200,36,57,72,233,140,238,236,95,184,127,38,145,188,52,83,122,206,124,99,128,97,119,100,94,165,7,35,182,57,254,80,45,21,86,88,112,45,126,196,110,193,74,133,62,47,240,222,132,26,161,87,201,175,123,24,255,106,250,21,18,73,21,8,25,172,170,219,42,50,237,150,99,104,82,21,61,140,138,236,191,107,24,149,224,3,172,1,125,151,5,103,206,14,133,149,55,106,237,9,182,174,103,205,81,100,159,198,92,209,188,87,110,103,53,128,118,54,164,135,129,110,56,143,216,43,21,78,123,37,216,90,191,78,131,193,141,210,147,213,26,113,181,96,156,157,51,78,85,249,18,88,12,134,184,22,13,193,229,119,69,141,80,72,186,43,45,228,148,133,225,232,196,157,198,104,165,176,163,252,103,126,112,186,2,89,75,119,66,145,57,185,245,205,225,76,239,192,59,72,140,166,229,33,93,253,106,106,187,167,22,53,96,210,230,173,243,70,41,201,232,195,139,233,121,192,106,97,103,21,178,240,253,229,104,188,98,95,110,207,153,221,239,27,99,254,146,101,171,2,3,1,0,1,163,129,166,48,129,163,48,29,6,3,85,29,14,4,22,4,20,136,39,23,9,169,182,24,96,139,236,235,186,246,71,89,197,82,84,163,183,48,15,6,3,85,29,19,1,1,255,4,5,48,3,1,1,255,48,31,6,3,85,29,35,4,24,48,22,128,20,43,208,105,71,148,118,9,254,244,107,141,46,64,166,247,71,77,127,8,94,48,46,6,3,85,29,31,4,39,48,37,48,35,160,33,160,31,134,29,104,116,116,112,58,47,47,99,114,108,46,97,112,112,108,101,46,99,111,109,47,114,111,111,116,46,99,114,108,48,14,6,3,85,29,15,1,1,255,4,4,3,2,1,134,48,16,6,10,42,134,72,134,247,99,100,6,2,1,4,2,5,0,48,13,6,9,42,134,72,134,247,13,1,1,5,5,0,3,130,1,1,0,79,207,239,89,190,44,245,178,108,47,143,238,19,135,50,232,5,53,168,110,139,125,201,105,12,185,217,23,188,119,44,212,103,226,253,154,109,58,89,92,223,131,1,189,178,174,42,97,114,177,175,205,195,69,48,143,163,131,13,206,29,71,180,241,147,138,163,116,155,164,195,152,114,135,59,62,175,69,11,146,84,185,50,187,144,24,83,107,10,78,16,182,217,29,80,108,33,128,10,137,78,87,140,107,91,60,61,166,253,222,247,13,35,29,11,74,38,135,63,186,145,146,76,164,25,18,25,109,87,245,122,88,135,123,104,138,228,134,140,74,235,226,73,20,170,165,221,85,0,169,174,187,75,48,174,225,160,177,188,41,128,230,9,119,229,190,52,162,1,202,127,220,226,10,230,59,184,187,236,186,98,149,243,5,99,65,130,205,15,59,29,76,149,164,219,171,249,201,149,233,79,228,77,231,38,153,129,233,188,249,180,41,210,1,122,102,225,46,140,246,33,138,197,248,120,225,129,174,191,211,144,157,169,173,243,175,253,56,26,150,103,48,28,81,165,92,236,113,138,130,180,108,15,12,21,31};
static const uint8_t kWWDR_G2[763] = {48,130,2,247,48,130,2,124,160,3,2,1,2,2,8,111,239,216,245,233,163,167,238,48,10,6,8,42,134,72,206,61,4,3,2,48,103,49,27,48,25,6,3,85,4,3,12,18,65,112,112,108,101,32,82,111,111,116,32,67,65,32,45,32,71,51,49,38,48,36,6,3,85,4,11,12,29,65,112,112,108,101,32,67,101,114,116,105,102,105,99,97,116,105,111,110,32,65,117,116,104,111,114,105,116,121,49,19,48,17,6,3,85,4,10,12,10,65,112,112,108,101,32,73,110,99,46,49,11,48,9,6,3,85,4,6,19,2,85,83,48,30,23,13,49,52,48,53,48,54,50,51,52,51,50,52,90,23,13,50,57,48,53,48,54,50,51,52,51,50,52,90,48,129,128,49,52,48,50,6,3,85,4,3,12,43,65,112,112,108,101,32,87,111,114,108,100,119,105,100,101,32,68,101,118,101,108,111,112,101,114,32,82,101,108,97,116,105,111,110,115,32,67,65,32,45,32,71,50,49,38,48,36,6,3,85,4,11,12,29,65,112,112,108,101,32,67,101,114,116,105,102,105,99,97,116,105,111,110,32,65,117,116,104,111,114,105,116,121,49,19,48,17,6,3,85,4,10,12,10,65,112,112,108,101,32,73,110,99,46,49,11,48,9,6,3,85,4,6,19,2,85,83,48,89,48,19,6,7,42,134,72,206,61,2,1,6,8,42,134,72,206,61,3,1,7,3,66,0,4,221,240,183,6,75,207,221,115,4,19,196,67,137,3,147,128,251,94,246,116,173,66,97,82,88,2,38,83,25,200,99,34,7,9,82,97,202,196,217,87,239,109,38,104,139,116,145,140,196,249,128,104,40,252,9,104,240,16,218,233,208,46,201,26,163,129,247,48,129,244,48,70,6,8,43,6,1,5,5,7,1,1,4,58,48,56,48,54,6,8,43,6,1,5,5,7,48,1,134,42,104,116,116,112,58,47,47,111,99,115,112,46,97,112,112,108,101,46,99,111,109,47,111,99,115,112,48,52,45,97,112,112,108,101,114,111,111,116,99,97,103,51,48,29,6,3,85,29,14,4,22,4,20,132,182,132,204,58,134,98,114,22,89,148,232,26,163,189,72,223,58,223,11,48,15,6,3,85,29,19,1,1,255,4,5,48,3,1,1,255,48,31,6,3,85,29,35,4,24,48,22,128,20,187,176,222,161,88,51,136,154,164,138,153,222,190,189,235,175,218,203,36,171,48,55,6,3,85,29,31,4,48,48,46,48,44,160,42,160,40,134,38,104,116,116,112,58,47,47,99,114,108,46,97,112,112,108,101,46,99,111,109,47,97,112,112,108,101,114,111,111,116,99,97,103,51,46,99,114,108,48,14,6,3,85,29,15,1,1,255,4,4,3,2,1,6,48,16,6,10,42,134,72,134,247,99,100,6,2,15,4,2,5,0,48,10,6,8,42,134,72,206,61,4,3,2,3,105,0,48,102,2,49,0,217,177,199,49,198,35,246,79,77,208,217,71,197,125,24,105,17,135,113,39,211,104,173,224,155,101,154,190,108,223,63,70,166,144,9,190,110,161,59,44,176,81,137,65,60,135,210,191,2,49,0,252,100,82,137,75,60,93,191,107,28,194,137,152,47,114,174,181,155,170,26,11,35,84,119,84,232,21,67,162,197,18,218,151,80,115,124,94,208,110,178,92,98,80,215,81,241,58,90};
static const uint8_t kWWDR_G3[1109] = {48,130,4,81,48,130,3,57,160,3,2,1,2,2,16,124,175,105,10,37,183,57,254,123,155,68,122,193,120,197,238,48,13,6,9,42,134,72,134,247,13,1,1,11,5,0,48,98,49,11,48,9,6,3,85,4,6,19,2,85,83,49,19,48,17,6,3,85,4,10,19,10,65,112,112,108,101,32,73,110,99,46,49,38,48,36,6,3,85,4,11,19,29,65,112,112,108,101,32,67,101,114,116,105,102,105,99,97,116,105,111,110,32,65,117,116,104,111,114,105,116,121,49,22,48,20,6,3,85,4,3,19,13,65,112,112,108,101,32,82,111,111,116,32,67,65,48,30,23,13,50,48,48,50,49,57,49,56,49,51,52,55,90,23,13,51,48,48,50,50,48,48,48,48,48,48,48,90,48,117,49,68,48,66,6,3,85,4,3,12,59,65,112,112,108,101,32,87,111,114,108,100,119,105,100,101,32,68,101,118,101,108,111,112,101,114,32,82,101,108,97,116,105,111,110,115,32,67,101,114,116,105,102,105,99,97,116,105,111,110,32,65,117,116,104,111,114,105,116,121,49,11,48,9,6,3,85,4,11,12,2,71,51,49,19,48,17,6,3,85,4,10,12,10,65,112,112,108,101,32,73,110,99,46,49,11,48,9,6,3,85,4,6,19,2,85,83,48,130,1,34,48,13,6,9,42,134,72,134,247,13,1,1,1,5,0,3,130,1,15,0,48,130,1,10,2,130,1,1,0,216,245,137,252,168,89,11,135,199,76,145,46,45,86,144,211,120,29,164,48,233,165,72,239,11,67,191,45,132,251,36,93,69,27,229,235,89,54,18,92,84,100,158,108,98,45,180,198,151,202,204,60,246,214,6,145,252,229,2,166,28,106,180,121,213,103,203,172,233,63,7,17,225,132,188,71,29,102,142,57,162,232,180,73,237,58,210,225,16,96,122,142,147,140,202,192,218,12,192,131,208,227,249,145,214,167,140,200,193,115,226,174,70,209,98,157,146,168,144,96,55,125,104,150,205,141,224,252,155,250,120,187,227,123,175,45,23,221,91,254,128,89,35,117,23,184,18,193,237,27,229,52,206,254,34,181,158,73,176,229,85,191,143,132,162,60,168,186,197,134,149,22,228,0,201,159,3,208,204,179,58,22,123,214,5,92,157,235,71,174,13,181,45,140,14,105,77,64,208,75,76,59,4,158,141,33,177,172,46,67,84,48,206,193,138,134,148,152,75,223,106,13,63,254,251,28,174,151,23,194,120,10,48,224,95,31,84,59,73,183,37,0,26,55,130,210,86,151,165,82,73,124,96,56,155,239,2,3,1,0,1,163,129,239,48,129,236,48,18,6,3,85,29,19,1,1,255,4,8,48,6,1,1,255,2,1,0,48,31,6,3,85,29,35,4,24,48,22,128,20,43,208,105,71,148,118,9,254,244,107,141,46,64,166,247,71,77,127,8,94,48,68,6,8,43,6,1,5,5,7,1,1,4,56,48,54,48,52,6,8,43,6,1,5,5,7,48,1,134,40,104,116,116,112,58,47,47,111,99,115,112,46,97,112,112,108,101,46,99,111,109,47,111,99,115,112,48,51,45,97,112,112,108,101,114,111,111,116,99,97,48,46,6,3,85,29,31,4,39,48,37,48,35,160,33,160,31,134,29,104,116,116,112,58,47,47,99,114,108,46,97,112,112,108,101,46,99,111,109,47,114,111,111,116,46,99,114,108,48,29,6,3,85,29,14,4,22,4,20,9,254,192,21,144,249,175,100,10,146,18,185,38,40,99,12,151,236,167,178,48,14,6,3,85,29,15,1,1,255,4,4,3,2,1,6,48,16,6,10,42,134,72,134,247,99,100,6,2,1,4,2,5,0,48,13,6,9,42,134,72,134,247,13,1,1,11,5,0,3,130,1,1,0,173,101,19,232,246,224,129,119,68,2,71,66,190,95,165,57,32,234,98,169,253,197,144,201,115,19,213,158,155,208,170,15,141,141,203,237,1,207,108,40,64,91,199,85,36,65,248,252,207,193,181,35,233,220,236,241,111,202,128,29,119,194,196,97,73,37,103,175,15,202,57,37,173,211,227,122,204,51,40,13,14,46,161,87,64,115,250,230,92,174,6,81,41,237,227,133,12,79,97,220,50,22,139,119,208,68,202,93,114,3,49,70,156,174,155,64,26,250,244,224,211,62,250,47,140,102,159,151,196,84,89,239,210,72,244,7,153,73,96,89,25,199,221,148,209,192,193,108,127,120,33,239,12,235,59,108,153,130,75,82,96,56,181,57,130,109,236,82,49,83,190,15,145,76,73,73,116,143,166,81,203,132,71,78,29,117,39,110,189,249,210,92,243,127,194,108,11,9,54,226,100,228,194,55,3,20,25,213,234,106,148,170,169,219,254,246,154,8,103,139,239,43,184,170,23,73,131,175,207,203,188,233,207,234,149,113,176,180,69,162,204,229,135,170,10,195,65,58,121,92,218,80,52,157,149,59};
static const uint8_t kWWDR_G4[1113] = {48,130,4,85,48,130,3,61,160,3,2,1,2,2,20,19,220,119,149,82,113,229,61,198,50,232,204,255,229,33,243,204,197,206,210,48,13,6,9,42,134,72,134,247,13,1,1,11,5,0,48,98,49,11,48,9,6,3,85,4,6,19,2,85,83,49,19,48,17,6,3,85,4,10,19,10,65,112,112,108,101,32,73,110,99,46,49,38,48,36,6,3,85,4,11,19,29,65,112,112,108,101,32,67,101,114,116,105,102,105,99,97,116,105,111,110,32,65,117,116,104,111,114,105,116,121,49,22,48,20,6,3,85,4,3,19,13,65,112,112,108,101,32,82,111,111,116,32,67,65,48,30,23,13,50,48,49,50,49,54,49,57,51,54,48,52,90,23,13,51,48,49,50,49,48,48,48,48,48,48,48,90,48,117,49,68,48,66,6,3,85,4,3,12,59,65,112,112,108,101,32,87,111,114,108,100,119,105,100,101,32,68,101,118,101,108,111,112,101,114,32,82,101,108,97,116,105,111,110,115,32,67,101,114,116,105,102,105,99,97,116,105,111,110,32,65,117,116,104,111,114,105,116,121,49,11,48,9,6,3,85,4,11,12,2,71,52,49,19,48,17,6,3,85,4,10,12,10,65,112,112,108,101,32,73,110,99,46,49,11,48,9,6,3,85,4,6,19,2,85,83,48,130,1,34,48,13,6,9,42,134,72,134,247,13,1,1,1,5,0,3,130,1,15,0,48,130,1,10,2,130,1,1,0,208,31,120,170,122,39,50,176,70,95,231,23,118,216,160,157,14,41,142,173,61,50,165,196,107,55,201,228,65,145,106,183,121,113,93,12,52,4,96,117,247,174,67,143,71,196,134,30,8,232,191,214,57,82,47,30,103,252,113,241,130,109,60,126,6,82,118,157,44,188,213,67,233,177,180,188,64,58,120,81,93,81,161,37,225,190,108,145,157,107,33,89,24,65,213,15,141,109,65,42,57,74,33,224,144,159,78,19,79,208,140,154,50,184,215,106,146,30,37,106,164,50,206,34,25,133,5,96,220,2,74,242,90,235,119,121,2,125,192,151,84,108,146,142,118,1,230,70,143,229,230,42,251,162,176,173,24,173,109,51,133,56,35,139,234,138,150,237,159,174,102,79,163,12,64,39,109,149,208,98,136,217,67,41,39,253,237,164,191,83,46,144,21,101,60,217,46,98,100,51,29,108,106,221,142,33,170,164,95,21,198,48,237,95,230,140,54,146,148,183,220,57,2,0,251,100,140,212,12,129,242,63,213,52,151,135,117,38,194,111,174,3,99,33,12,123,212,27,177,98,197,2,156,189,253,175,2,3,1,0,1,163,129,239,48,129,236,48,18,6,3,85,29,19,1,1,255,4,8,48,6,1,1,255,2,1,0,48,31,6,3,85,29,35,4,24,48,22,128,20,43,208,105,71,148,118,9,254,244,107,141,46,64,166,247,71,77,127,8,94,48,68,6,8,43,6,1,5,5,7,1,1,4,56,48,54,48,52,6,8,43,6,1,5,5,7,48,1,134,40,104,116,116,112,58,47,47,111,99,115,112,46,97,112,112,108,101,46,99,111,109,47,111,99,115,112,48,51,45,97,112,112,108,101,114,111,111,116,99,97,48,46,6,3,85,29,31,4,39,48,37,48,35,160,33,160,31,134,29,104,116,116,112,58,47,47,99,114,108,46,97,112,112,108,101,46,99,111,109,47,114,111,111,116,46,99,114,108,48,29,6,3,85,29,14,4,22,4,20,91,217,250,29,231,154,26,11,163,153,118,34,80,134,62,145,200,91,119,168,48,14,6,3,85,29,15,1,1,255,4,4,3,2,1,6,48,16,6,10,42,134,72,134,247,99,100,6,2,1,4,2,5,0,48,13,6,9,42,134,72,134,247,13,1,1,11,5,0,3,130,1,1,0,63,86,61,158,229,182,195,121,230,69,32,104,189,191,115,139,44,18,158,2,227,174,128,34,140,4,30,195,82,200,112,128,168,251,206,167,176,213,66,68,130,3,130,79,6,252,59,73,20,251,216,116,82,133,175,167,157,33,231,1,18,3,159,205,64,88,208,1,215,191,50,131,43,83,88,40,60,238,156,159,84,118,61,100,39,198,126,141,29,56,77,45,174,129,230,185,165,184,156,137,148,247,159,199,135,165,81,102,52,27,57,113,57,36,227,135,103,239,165,177,104,123,140,238,61,247,174,182,123,226,210,255,223,97,198,106,117,73,149,34,68,168,4,252,148,184,11,46,57,17,73,18,209,229,129,234,89,0,79,91,60,90,54,218,122,34,115,9,9,105,205,192,124,234,226,36,254,152,68,184,248,239,178,113,63,26,93,212,93,126,51,77,156,29,36,190,0,240,144,3,88,153,65,61,49,90,98,64,175,57,168,81,67,146,171,4,168,156,194,77,177,75,210,171,124,74,95,235,157,59,188,79,136,64,6,19,255,144,23,138,8,71,41,232,98,152,41,165,79,17,5,105,58,207,242,159};
static const uint8_t kWWDR_G5[1113] = {48,130,4,85,48,130,3,61,160,3,2,1,2,2,20,59,126,128,10,238,211,2,161,230,236,219,151,217,202,172,40,156,241,105,148,48,13,6,9,42,134,72,134,247,13,1,1,11,5,0,48,98,49,11,48,9,6,3,85,4,6,19,2,85,83,49,19,48,17,6,3,85,4,10,19,10,65,112,112,108,101,32,73,110,99,46,49,38,48,36,6,3,85,4,11,19,29,65,112,112,108,101,32,67,101,114,116,105,102,105,99,97,116,105,111,110,32,65,117,116,104,111,114,105,116,121,49,22,48,20,6,3,85,4,3,19,13,65,112,112,108,101,32,82,111,111,116,32,67,65,48,30,23,13,50,48,49,50,49,54,49,57,51,56,53,54,90,23,13,51,48,49,50,49,48,48,48,48,48,48,48,90,48,117,49,68,48,66,6,3,85,4,3,12,59,65,112,112,108,101,32,87,111,114,108,100,119,105,100,101,32,68,101,118,101,108,111,112,101,114,32,82,101,108,97,116,105,111,110,115,32,67,101,114,116,105,102,105,99,97,116,105,111,110,32,65,117,116,104,111,114,105,116,121,49,11,48,9,6,3,85,4,11,12,2,71,53,49,19,48,17,6,3,85,4,10,12,10,65,112,112,108,101,32,73,110,99,46,49,11,48,9,6,3,85,4,6,19,2,85,83,48,130,1,34,48,13,6,9,42,134,72,134,247,13,1,1,1,5,0,3,130,1,15,0,48,130,1,10,2,130,1,1,0,159,93,218,31,251,250,188,208,75,34,60,199,214,38,250,23,247,244,159,30,62,100,17,102,154,239,94,190,171,52,189,170,44,33,110,214,30,148,33,133,44,116,193,14,16,97,170,60,99,74,126,74,227,200,117,214,207,194,156,8,72,123,106,185,41,177,201,102,253,200,138,22,209,178,4,60,130,186,128,108,226,255,10,114,235,172,254,59,111,72,190,158,139,17,77,149,125,178,123,144,47,2,28,78,252,73,190,215,111,181,79,190,120,198,218,222,178,205,201,217,102,17,59,90,233,9,69,115,137,80,212,78,226,104,5,126,218,117,156,75,1,174,218,227,207,109,116,77,222,83,208,213,26,56,130,58,208,157,227,93,41,123,177,129,234,41,39,11,251,96,124,134,18,251,240,98,79,6,231,76,209,31,217,109,158,237,115,218,120,33,13,157,112,217,70,87,144,95,103,132,193,115,119,10,168,98,98,182,174,112,134,187,117,35,137,173,121,246,230,164,212,253,131,38,50,10,59,36,146,91,32,161,156,209,47,128,24,155,221,60,11,231,181,253,236,128,87,15,23,158,63,43,135,39,187,247,2,3,1,0,1,163,129,239,48,129,236,48,18,6,3,85,29,19,1,1,255,4,8,48,6,1,1,255,2,1,0,48,31,6,3,85,29,35,4,24,48,22,128,20,43,208,105,71,148,118,9,254,244,107,141,46,64,166,247,71,77,127,8,94,48,68,6,8,43,6,1,5,5,7,1,1,4,56,48,54,48,52,6,8,43,6,1,5,5,7,48,1,134,40,104,116,116,112,58,47,47,111,99,115,112,46,97,112,112,108,101,46,99,111,109,47,111,99,115,112,48,51,45,97,112,112,108,101,114,111,111,116,99,97,48,46,6,3,85,29,31,4,39,48,37,48,35,160,33,160,31,134,29,104,116,116,112,58,47,47,99,114,108,46,97,112,112,108,101,46,99,111,109,47,114,111,111,116,46,99,114,108,48,29,6,3,85,29,14,4,22,4,20,25,139,151,141,74,91,97,120,87,244,165,92,53,18,138,57,8,227,176,117,48,14,6,3,85,29,15,1,1,255,4,4,3,2,1,6,48,16,6,10,42,134,72,134,247,99,100,6,2,1,4,2,5,0,48,13,6,9,42,134,72,134,247,13,1,1,11,5,0,3,130,1,1,0,90,196,53,162,217,230,10,158,82,162,0,130,34,119,205,114,47,144,249,34,175,20,37,204,170,10,66,96,146,194,189,117,29,235,76,202,21,229,126,107,64,16,94,251,91,69,116,13,240,122,125,136,145,206,222,99,139,66,137,210,24,223,65,179,88,158,6,8,135,72,221,64,175,35,213,237,235,44,96,229,235,164,127,28,233,156,131,214,148,95,76,98,57,138,78,174,19,141,125,67,184,220,94,172,190,24,64,242,230,15,44,93,19,147,241,123,101,168,194,104,72,222,255,180,150,155,12,251,50,54,158,158,13,149,95,56,10,139,150,210,18,108,183,139,11,142,215,62,236,111,1,170,206,77,69,96,219,132,113,102,98,229,25,101,48,205,138,255,69,83,251,110,251,136,119,67,195,72,99,249,247,81,179,114,94,121,226,86,207,188,187,132,185,56,90,120,174,17,72,82,187,13,53,139,148,222,204,116,154,104,245,73,96,148,172,242,168,179,21,134,144,208,204,48,67,134,211,229,112,2,81,180,129,192,168,151,212,234,234,176,140,9,64,239,56,147,178,205,34,3,235,103,67,101,200,69};
static const uint8_t kWWDR_G6[794] = {48,130,3,22,48,130,2,156,160,3,2,1,2,2,20,34,193,161,71,10,116,115,105,239,83,134,18,201,198,159,61,56,243,108,215,48,10,6,8,42,134,72,206,61,4,3,3,48,103,49,27,48,25,6,3,85,4,3,12,18,65,112,112,108,101,32,82,111,111,116,32,67,65,32,45,32,71,51,49,38,48,36,6,3,85,4,11,12,29,65,112,112,108,101,32,67,101,114,116,105,102,105,99,97,116,105,111,110,32,65,117,116,104,111,114,105,116,121,49,19,48,17,6,3,85,4,10,12,10,65,112,112,108,101,32,73,110,99,46,49,11,48,9,6,3,85,4,6,19,2,85,83,48,30,23,13,50,49,48,51,49,55,50,48,51,55,49,48,90,23,13,51,54,48,51,49,57,48,48,48,48,48,48,90,48,117,49,68,48,66,6,3,85,4,3,12,59,65,112,112,108,101,32,87,111,114,108,100,119,105,100,101,32,68,101,118,101,108,111,112,101,114,32,82,101,108,97,116,105,111,110,115,32,67,101,114,116,105,102,105,99,97,116,105,111,110,32,65,117,116,104,111,114,105,116,121,49,11,48,9,6,3,85,4,11,12,2,71,54,49,19,48,17,6,3,85,4,10,12,10,65,112,112,108,101,32,73,110,99,46,49,11,48,9,6,3,85,4,6,19,2,85,83,48,118,48,16,6,7,42,134,72,206,61,2,1,6,5,43,129,4,0,34,3,98,0,4,110,196,10,11,222,15,174,85,166,101,121,215,130,220,115,117,82,75,241,61,18,25,137,224,13,17,169,158,9,247,55,163,211,240,147,4,111,177,67,139,134,193,152,248,66,157,157,255,178,174,143,23,247,6,112,165,214,176,190,111,58,215,145,135,34,120,231,29,192,72,254,220,56,31,154,106,143,116,125,202,113,74,255,196,100,86,231,136,6,205,129,145,161,34,26,72,163,129,250,48,129,247,48,18,6,3,85,29,19,1,1,255,4,8,48,6,1,1,255,2,1,0,48,31,6,3,85,29,35,4,24,48,22,128,20,187,176,222,161,88,51,136,154,164,138,153,222,190,189,235,175,218,203,36,171,48,70,6,8,43,6,1,5,5,7,1,1,4,58,48,56,48,54,6,8,43,6,1,5,5,7,48,1,134,42,104,116,116,112,58,47,47,111,99,115,112,46,97,112,112,108,101,46,99,111,109,47,111,99,115,112,48,51,45,97,112,112,108,101,114,111,111,116,99,97,103,51,48,55,6,3,85,29,31,4,48,48,46,48,44,160,42,160,40,134,38,104,116,116,112,58,47,47,99,114,108,46,97,112,112,108,101,46,99,111,109,47,97,112,112,108,101,114,111,111,116,99,97,103,51,46,99,114,108,48,29,6,3,85,29,14,4,22,4,20,63,47,148,35,81,211,80,201,154,40,61,237,176,124,229,207,165,144,98,153,48,14,6,3,85,29,15,1,1,255,4,4,3,2,1,6,48,16,6,10,42,134,72,134,247,99,100,6,2,1,4,2,5,0,48,10,6,8,42,134,72,206,61,4,3,3,3,104,0,48,101,2,48,64,94,20,170,228,140,138,162,3,2,62,220,56,247,64,90,7,174,251,9,161,6,37,123,159,64,31,196,169,145,157,232,36,163,136,43,78,158,227,19,109,117,87,155,28,92,197,249,2,49,0,211,72,252,90,173,149,239,54,185,49,83,116,228,80,194,55,223,44,239,21,85,81,79,140,49,88,144,189,247,131,172,117,198,120,249,17,141,177,128,242,71,152,38,118,189,39,12,104};
static const uint8_t kWWDR_G7[1113] = {48,130,4,85,48,130,3,61,160,3,2,1,2,2,20,52,24,88,255,1,254,6,63,142,241,159,31,233,60,1,180,193,70,255,201,48,13,6,9,42,134,72,134,247,13,1,1,5,5,0,48,98,49,11,48,9,6,3,85,4,6,19,2,85,83,49,19,48,17,6,3,85,4,10,19,10,65,112,112,108,101,32,73,110,99,46,49,38,48,36,6,3,85,4,11,19,29,65,112,112,108,101,32,67,101,114,116,105,102,105,99,97,116,105,111,110,32,65,117,116,104,111,114,105,116,121,49,22,48,20,6,3,85,4,3,19,13,65,112,112,108,101,32,82,111,111,116,32,67,65,48,30,23,13,50,50,49,49,49,55,50,48,52,48,53,51,90,23,13,50,51,49,49,49,55,50,48,52,48,53,50,90,48,117,49,11,48,9,6,3,85,4,6,19,2,85,83,49,19,48,17,6,3,85,4,10,12,10,65,112,112,108,101,32,73,110,99,46,49,11,48,9,6,3,85,4,11,12,2,71,55,49,68,48,66,6,3,85,4,3,12,59,65,112,112,108,101,32,87,111,114,108,100,119,105,100,101,32,68,101,118,101,108,111,112,101,114,32,82,101,108,97,116,105,111,110,115,32,67,101,114,116,105,102,105,99,97,116,105,111,110,32,65,117,116,104,111,114,105,116,121,48,130,1,34,48,13,6,9,42,134,72,134,247,13,1,1,1,5,0,3,130,1,15,0,48,130,1,10,2,130,1,1,0,172,174,209,211,182,138,177,27,40,149,173,222,81,81,76,63,51,225,78,92,175,179,252,2,210,101,79,42,212,116,104,140,117,23,101,207,40,228,72,9,152,113,82,50,44,22,78,120,142,146,86,100,169,221,139,205,226,212,199,59,162,18,69,55,2,25,98,100,47,127,97,198,211,89,34,191,171,249,20,163,237,182,158,153,186,47,241,177,220,48,66,79,182,182,178,198,116,170,98,86,187,237,68,54,15,209,229,32,116,147,87,58,93,158,220,1,252,120,111,105,22,53,195,110,1,194,158,114,212,113,54,177,118,9,122,190,13,42,151,241,176,94,11,27,18,173,43,171,7,223,99,45,245,136,233,50,18,162,85,88,67,118,60,61,23,128,31,41,219,177,169,159,171,150,5,157,21,220,221,219,78,15,231,19,124,90,43,46,2,65,246,238,122,106,182,115,96,247,151,25,20,139,149,51,56,147,218,0,37,54,174,85,90,124,159,249,244,98,4,7,116,233,29,167,149,87,35,172,43,36,218,100,79,40,114,233,150,176,8,60,136,27,20,99,67,215,137,174,152,193,242,45,142,227,81,37,2,3,1,0,1,163,129,239,48,129,236,48,18,6,3,85,29,19,1,1,255,4,8,48,6,1,1,255,2,1,0,48,31,6,3,85,29,35,4,24,48,22,128,20,43,208,105,71,148,118,9,254,244,107,141,46,64,166,247,71,77,127,8,94,48,68,6,8,43,6,1,5,5,7,1,1,4,56,48,54,48,52,6,8,43,6,1,5,5,7,48,1,134,40,104,116,116,112,58,47,47,111,99,115,112,46,97,112,112,108,101,46,99,111,109,47,111,99,115,112,48,51,45,97,112,112,108,101,114,111,111,116,99,97,48,46,6,3,85,29,31,4,39,48,37,48,35,160,33,160,31,134,29,104,116,116,112,58,47,47,99,114,108,46,97,112,112,108,101,46,99,111,109,47,114,111,111,116,46,99,114,108,48,29,6,3,85,29,14,4,22,4,20,93,66,16,108,27,187,199,82,151,78,68,189,19,39,185,58,18,119,131,43,48,14,6,3,85,29,15,1,1,255,4,4,3,2,1,6,48,16,6,10,42,134,72,134,247,99,100,6,2,1,4,2,5,0,48,13,6,9,42,134,72,134,247,13,1,1,5,5,0,3,130,1,1,0,82,163,8,41,19,101,183,181,31,230,52,3,237,246,24,119,188,61,202,39,181,112,236,236,108,51,75,246,153,37,148,7,158,33,51,3,106,245,125,10,46,43,223,8,169,130,222,74,127,225,231,11,75,5,184,39,152,73,221,193,12,134,215,129,100,174,130,156,196,69,241,234,143,28,34,48,227,162,37,97,68,137,254,133,122,86,240,114,146,124,12,68,84,36,183,181,164,159,38,240,50,249,87,157,106,121,108,64,237,15,52,6,6,66,255,216,14,49,101,109,230,46,1,217,6,191,197,202,13,174,71,212,5,23,136,60,233,156,228,25,100,109,138,148,173,17,220,1,246,229,120,175,173,232,112,215,13,93,129,62,70,42,44,174,36,161,199,210,224,125,191,29,245,54,107,197,222,169,10,154,128,177,17,94,178,100,126,179,193,87,204,194,108,89,153,183,244,176,221,49,218,72,214,106,129,238,178,139,80,53,22,230,231,92,113,98,110,176,242,81,226,168,109,248,42,203,104,115,198,166,196,26,67,73,1,62,169,169,0,138,134,108,131,136,210,92,112,87,122,218,248,118,204,25,213,176};
static const uint8_t kWWDR_G8[1113] = {48,130,4,85,48,130,3,61,160,3,2,1,2,2,20,84,181,11,175,121,13,141,127,140,175,104,76,86,47,80,105,10,26,186,95,48,13,6,9,42,134,72,134,247,13,1,1,5,5,0,48,98,49,11,48,9,6,3,85,4,6,19,2,85,83,49,19,48,17,6,3,85,4,10,19,10,65,112,112,108,101,32,73,110,99,46,49,38,48,36,6,3,85,4,11,19,29,65,112,112,108,101,32,67,101,114,116,105,102,105,99,97,116,105,111,110,32,65,117,116,104,111,114,105,116,121,49,22,48,20,6,3,85,4,3,19,13,65,112,112,108,101,32,82,111,111,116,32,67,65,48,30,23,13,50,51,48,54,50,48,50,51,51,55,49,53,90,23,13,50,53,48,49,50,52,48,48,48,48,48,48,90,48,117,49,11,48,9,6,3,85,4,6,19,2,85,83,49,19,48,17,6,3,85,4,10,12,10,65,112,112,108,101,32,73,110,99,46,49,11,48,9,6,3,85,4,11,12,2,71,56,49,68,48,66,6,3,85,4,3,12,59,65,112,112,108,101,32,87,111,114,108,100,119,105,100,101,32,68,101,118,101,108,111,112,101,114,32,82,101,108,97,116,105,111,110,115,32,67,101,114,116,105,102,105,99,97,116,105,111,110,32,65,117,116,104,111,114,105,116,121,48,130,1,34,48,13,6,9,42,134,72,134,247,13,1,1,1,5,0,3,130,1,15,0,48,130,1,10,2,130,1,1,0,208,64,16,212,8,249,82,33,99,79,60,104,247,212,156,130,2,140,131,104,188,183,141,127,136,231,66,77,44,239,34,165,194,137,222,189,12,215,77,97,80,45,57,228,48,115,165,210,213,104,154,51,242,239,217,42,173,46,31,3,186,248,165,241,66,11,87,46,70,198,208,88,211,112,95,247,178,55,239,106,31,62,191,137,57,194,173,254,245,5,251,88,150,49,200,135,44,213,35,186,117,176,44,245,171,160,186,242,32,12,76,235,36,99,105,233,34,64,240,142,88,91,222,100,123,137,27,81,18,4,224,23,178,89,205,223,241,231,206,175,44,50,232,105,193,208,8,126,29,162,71,115,209,75,59,253,185,133,220,71,167,40,130,121,41,72,137,2,40,226,193,236,44,31,91,134,252,216,182,203,113,192,115,1,75,252,5,17,17,108,1,3,52,90,246,129,194,94,31,124,20,14,222,63,107,33,203,79,245,215,97,230,132,3,146,188,231,37,41,158,205,91,12,193,219,227,196,58,217,118,87,172,47,56,20,25,200,183,177,162,85,79,95,78,142,25,89,169,218,253,114,218,176,4,33,5,2,3,1,0,1,163,129,239,48,129,236,48,18,6,3,85,29,19,1,1,255,4,8,48,6,1,1,255,2,1,0,48,31,6,3,85,29,35,4,24,48,22,128,20,43,208,105,71,148,118,9,254,244,107,141,46,64,166,247,71,77,127,8,94,48,68,6,8,43,6,1,5,5,7,1,1,4,56,48,54,48,52,6,8,43,6,1,5,5,7,48,1,134,40,104,116,116,112,58,47,47,111,99,115,112,46,97,112,112,108,101,46,99,111,109,47,111,99,115,112,48,51,45,97,112,112,108,101,114,111,111,116,99,97,48,46,6,3,85,29,31,4,39,48,37,48,35,160,33,160,31,134,29,104,116,116,112,58,47,47,99,114,108,46,97,112,112,108,101,46,99,111,109,47,114,111,111,116,46,99,114,108,48,29,6,3,85,29,14,4,22,4,20,181,189,188,128,196,12,227,56,164,244,183,173,35,179,239,68,206,185,90,133,48,14,6,3,85,29,15,1,1,255,4,4,3,2,1,6,48,16,6,10,42,134,72,134,247,99,100,6,2,1,4,2,5,0,48,13,6,9,42,134,72,134,247,13,1,1,5,5,0,3,130,1,1,0,76,179,235,122,57,148,74,149,102,250,22,49,234,13,138,143,93,66,56,198,7,205,232,201,34,172,252,8,66,126,95,147,95,49,42,168,34,193,118,25,43,238,174,114,233,189,86,207,73,36,146,8,247,205,25,117,195,249,26,39,13,14,220,41,141,63,182,219,165,79,76,114,196,96,145,137,17,126,36,149,67,34,96,103,188,223,255,171,229,60,22,23,157,130,20,78,157,244,117,254,80,185,173,5,178,184,121,246,149,214,16,229,246,83,244,207,35,230,119,15,236,184,75,105,248,226,158,2,49,217,142,217,202,190,99,94,95,225,160,105,206,193,205,110,73,163,120,97,175,57,60,106,75,10,52,37,100,213,48,181,60,171,221,17,129,57,113,232,192,195,88,128,17,16,26,17,210,194,188,89,240,138,217,53,115,192,230,109,228,201,125,98,20,62,130,2,169,16,105,55,121,97,111,240,70,148,62,53,245,171,172,99,208,216,94,89,87,105,209,184,75,110,93,212,95,19,156,112,78,37,17,220,36,44,30,22,158,150,90,4,237,69,238,58,238,103,93,143,195,134,176,245,76,31,104,16};
static const uint8_t kWWDR_Root[1215] = {48,130,4,187,48,130,3,163,160,3,2,1,2,2,1,2,48,13,6,9,42,134,72,134,247,13,1,1,5,5,0,48,98,49,11,48,9,6,3,85,4,6,19,2,85,83,49,19,48,17,6,3,85,4,10,19,10,65,112,112,108,101,32,73,110,99,46,49,38,48,36,6,3,85,4,11,19,29,65,112,112,108,101,32,67,101,114,116,105,102,105,99,97,116,105,111,110,32,65,117,116,104,111,114,105,116,121,49,22,48,20,6,3,85,4,3,19,13,65,112,112,108,101,32,82,111,111,116,32,67,65,48,30,23,13,48,54,48,52,50,53,50,49,52,48,51,54,90,23,13,51,53,48,50,48,57,50,49,52,48,51,54,90,48,98,49,11,48,9,6,3,85,4,6,19,2,85,83,49,19,48,17,6,3,85,4,10,19,10,65,112,112,108,101,32,73,110,99,46,49,38,48,36,6,3,85,4,11,19,29,65,112,112,108,101,32,67,101,114,116,105,102,105,99,97,116,105,111,110,32,65,117,116,104,111,114,105,116,121,49,22,48,20,6,3,85,4,3,19,13,65,112,112,108,101,32,82,111,111,116,32,67,65,48,130,1,34,48,13,6,9,42,134,72,134,247,13,1,1,1,5,0,3,130,1,15,0,48,130,1,10,2,130,1,1,0,228,145,169,9,31,145,219,30,71,80,235,5,237,94,121,132,45,235,54,162,87,76,85,236,139,25,137,222,249,75,108,245,7,171,34,48,2,232,24,62,248,80,9,211,127,65,168,152,249,209,202,102,156,36,107,17,208,163,187,228,27,42,195,31,149,158,122,12,164,71,139,91,212,22,55,51,203,196,15,77,206,20,105,209,201,25,114,245,93,14,213,127,95,155,242,37,3,186,85,143,77,93,13,241,100,53,35,21,75,21,89,29,179,148,247,246,156,158,207,80,186,193,88,80,103,143,8,180,32,247,203,172,44,32,111,112,182,63,1,48,140,183,67,207,15,157,61,243,43,73,40,26,200,254,206,181,185,14,217,94,28,214,203,61,181,58,173,244,15,14,0,146,11,177,33,22,46,116,213,60,13,219,98,22,171,163,113,146,71,83,85,193,175,47,65,179,248,251,227,112,205,230,163,76,69,126,31,76,107,80,150,65,137,196,116,98,11,16,131,65,135,51,138,129,177,48,88,236,90,4,50,140,104,179,143,29,222,101,115,255,103,94,101,188,73,216,118,159,51,20,101,161,119,148,201,45,2,3,1,0,1,163,130,1,122,48,130,1,118,48,14,6,3,85,29,15,1,1,255,4,4,3,2,1,6,48,15,6,3,85,29,19,1,1,255,4,5,48,3,1,1,255,48,29,6,3,85,29,14,4,22,4,20,43,208,105,71,148,118,9,254,244,107,141,46,64,166,247,71,77,127,8,94,48,31,6,3,85,29,35,4,24,48,22,128,20,43,208,105,71,148,118,9,254,244,107,141,46,64,166,247,71,77,127,8,94,48,130,1,17,6,3,85,29,32,4,130,1,8,48,130,1,4,48,130,1,0,6,9,42,134,72,134,247,99,100,5,1,48,129,242,48,42,6,8,43,6,1,5,5,7,2,1,22,30,104,116,116,112,115,58,47,47,119,119,119,46,97,112,112,108,101,46,99,111,109,47,97,112,112,108,101,99,97,47,48,129,195,6,8,43,6,1,5,5,7,2,2,48,129,182,26,129,179,82,101,108,105,97,110,99,101,32,111,110,32,116,104,105,115,32,99,101,114,116,105,102,105,99,97,116,101,32,98,121,32,97,110,121,32,112,97,114,116,121,32,97,115,115,117,109,101,115,32,97,99,99,101,112,116,97,110,99,101,32,111,102,32,116,104,101,32,116,104,101,110,32,97,112,112,108,105,99,97,98,108,101,32,115,116,97,110,100,97,114,100,32,116,101,114,109,115,32,97,110,100,32,99,111,110,100,105,116,105,111,110,115,32,111,102,32,117,115,101,44,32,99,101,114,116,105,102,105,99,97,116,101,32,112,111,108,105,99,121,32,97,110,100,32,99,101,114,116,105,102,105,99,97,116,105,111,110,32,112,114,97,99,116,105,99,101,32,115,116,97,116,101,109,101,110,116,115,46,48,13,6,9,42,134,72,134,247,13,1,1,5,5,0,3,130,1,1,0,92,54,153,76,45,120,183,237,140,155,220,243,119,155,242,118,210,119,48,79,193,31,133,131,133,27,153,61,71,55,242,169,155,64,142,44,212,177,144,18,216,190,244,115,155,238,210,100,15,203,121,79,52,216,162,62,249,120,255,107,200,7,236,125,57,131,139,83,32,211,56,196,177,191,154,79,10,107,255,43,252,89,167,5,9,124,23,64,86,17,30,116,211,183,139,35,59,71,163,213,111,36,226,235,209,183,112,223,15,69,225,39,202,241,109,120,237,231,181,23,23,168,220,126,34,53,202,37,213,217,15,214,107,212,162,36,35,17,247,161,172,143,115,129,96,198,27,91,9,47,146,178,248,68,72,240,96,56,158,21,245,61,38,103,32,138,51,106,247,13,130,207,222,235,163,47,249,83,106,91,100,192,99,51,119,247,58,7,44,86,235,218,15,33,14,218,186,115,25,79,181,217,54,127,193,135,85,217,167,153,185,50,66,251,216,213,113,158,126,161,82,183,27,189,147,66,36,18,42,199,15,29,182,77,156,94,99,200,75,128,23,80,170,138,213,218,228,252,208,9,7,55,176,117,117,33};
static const uint8_t kWWDR_RootG3[583] = {48,130,2,67,48,130,1,201,160,3,2,1,2,2,8,45,197,252,136,210,197,75,149,48,10,6,8,42,134,72,206,61,4,3,3,48,103,49,27,48,25,6,3,85,4,3,12,18,65,112,112,108,101,32,82,111,111,116,32,67,65,32,45,32,71,51,49,38,48,36,6,3,85,4,11,12,29,65,112,112,108,101,32,67,101,114,116,105,102,105,99,97,116,105,111,110,32,65,117,116,104,111,114,105,116,121,49,19,48,17,6,3,85,4,10,12,10,65,112,112,108,101,32,73,110,99,46,49,11,48,9,6,3,85,4,6,19,2,85,83,48,30,23,13,49,52,48,52,51,48,49,56,49,57,48,54,90,23,13,51,57,48,52,51,48,49,56,49,57,48,54,90,48,103,49,27,48,25,6,3,85,4,3,12,18,65,112,112,108,101,32,82,111,111,116,32,67,65,32,45,32,71,51,49,38,48,36,6,3,85,4,11,12,29,65,112,112,108,101,32,67,101,114,116,105,102,105,99,97,116,105,111,110,32,65,117,116,104,111,114,105,116,121,49,19,48,17,6,3,85,4,10,12,10,65,112,112,108,101,32,73,110,99,46,49,11,48,9,6,3,85,4,6,19,2,85,83,48,118,48,16,6,7,42,134,72,206,61,2,1,6,5,43,129,4,0,34,3,98,0,4,152,233,47,61,64,114,164,237,147,34,114,129,19,28,221,16,149,241,197,163,78,113,220,20,22,217,14,229,166,5,42,119,100,123,95,78,56,211,187,28,68,181,127,245,31,182,50,98,93,201,233,132,91,79,48,79,17,90,0,253,88,88,12,165,245,15,44,77,7,71,19,117,218,151,151,151,111,49,92,237,43,157,123,32,59,216,185,84,217,94,153,164,58,81,10,49,163,66,48,64,48,29,6,3,85,29,14,4,22,4,20,187,176,222,161,88,51,136,154,164,138,153,222,190,189,235,175,218,203,36,171,48,15,6,3,85,29,19,1,1,255,4,5,48,3,1,1,255,48,14,6,3,85,29,15,1,1,255,4,4,3,2,1,6,48,10,6,8,42,134,72,206,61,4,3,3,3,104,0,48,101,2,49,0,131,233,193,196,22,94,26,93,52,24,217,237,239,244,108,14,0,70,75,184,223,178,70,17,197,15,253,230,122,140,161,166,107,206,194,3,212,156,245,147,198,116,184,106,223,170,35,21,2,48,109,102,138,16,202,212,13,212,79,205,141,67,62,180,138,99,165,51,110,227,109,218,23,183,100,31,200,83,38,249,136,98,116,57,11,23,91,203,81,168,12,232,24,3,231,162,178,40};
struct PaxWWDRCert { const char *name; const uint8_t *der; size_t len; };
static const PaxWWDRCert kWWDRCerts[] = {{"G1", kWWDR_G1, sizeof(kWWDR_G1)},{"G2", kWWDR_G2, sizeof(kWWDR_G2)},{"G3", kWWDR_G3, sizeof(kWWDR_G3)},{"G4", kWWDR_G4, sizeof(kWWDR_G4)},{"G5", kWWDR_G5, sizeof(kWWDR_G5)},{"G6", kWWDR_G6, sizeof(kWWDR_G6)},{"G7", kWWDR_G7, sizeof(kWWDR_G7)},{"G8", kWWDR_G8, sizeof(kWWDR_G8)},{"Root", kWWDR_Root, sizeof(kWWDR_Root)},{"RootG3", kWWDR_RootG3, sizeof(kWWDR_RootG3)},};

namespace {
void wrBE32(uint8_t* p, uint32_t v) { p[0] = v >> 24; p[1] = v >> 16; p[2] = v >> 8; p[3] = v; }
uint32_t rdLE32(const uint8_t* p) { return p[0] | (p[1] << 8) | (p[2] << 16) | ((uint32_t)p[3] << 24); }
uint64_t rdLE64(const uint8_t* p) { return (uint64_t)rdLE32(p) | ((uint64_t)rdLE32(p + 4) << 32); }
void wrLE32(uint8_t* p, uint32_t v) { p[0] = v; p[1] = v >> 8; p[2] = v >> 16; p[3] = v >> 24; }
void wrLE64(uint8_t* p, uint64_t v) { wrLE32(p, (uint32_t)v); wrLE32(p + 4, (uint32_t)(v >> 32)); }

std::vector<uint8_t> sha1Of(const uint8_t* p, size_t n) { std::vector<uint8_t> o(20); CC_SHA1(p, (CC_LONG)n, o.data()); return o; }
std::vector<uint8_t> sha256Of(const uint8_t* p, size_t n) { std::vector<uint8_t> o(32); CC_SHA256(p, (CC_LONG)n, o.data()); return o; }
std::string hexOf(const uint8_t* p, size_t n) { static const char* h = "0123456789abcdef"; std::string s; for (size_t i = 0; i < n; i++) { s += h[p[i] >> 4]; s += h[p[i] & 15]; } return s; }

// 指定需求（ZSign 模板）：identifier "<id>" and anchor apple generic
//   and certificate leaf[subject.CN] = "<CN>" and certificate 1[field.1.2.840.113635.100.6.2.1] exists
std::vector<uint8_t> buildRequirements(const std::string& ident, const std::string& cn) {
    std::vector<uint8_t> e;
    auto w = [&e](uint32_t v) { uint8_t t[4]; wrBE32(t, v); e.insert(e.end(), t, t + 4); };
    auto data = [&e, &w](const uint8_t* p, size_t n) {
        w((uint32_t)n); e.insert(e.end(), p, p + n);
        size_t pad = (4 - (n % 4)) % 4; e.insert(e.end(), pad, 0);
    };
    w(1);            // kind = expression
    w(6); w(2); data((const uint8_t*)ident.data(), ident.size());          // and(ident, ...)
    w(6); w(15);                                                            // and(appleGenericAnchor, ...)
    w(6); w(11); w(0); data((const uint8_t*)"subject.CN", 10); w(1); data((const uint8_t*)cn.data(), cn.size()); // and(certField leaf.CN == cn, ...)
    static const uint8_t wwdr[] = {0x2a, 0x86, 0x48, 0x86, 0xf7, 0x63, 0x64, 0x06, 0x02, 0x01};
    w(14); w(1); data(wwdr, sizeof(wwdr)); w(0);                            // certGeneric(1, wwdrOID, exists)
    std::vector<uint8_t> inner(8);
    wrBE32(inner.data(), 0xfade0c00); wrBE32(inner.data() + 4, (uint32_t)(8 + e.size()));
    inner.insert(inner.end(), e.begin(), e.end());
    std::vector<uint8_t> out(20);
    wrBE32(out.data(), 0xfade0c01); wrBE32(out.data() + 4, (uint32_t)(20 + inner.size()));
    wrBE32(out.data() + 8, 1); wrBE32(out.data() + 12, 3); wrBE32(out.data() + 16, 20);
    out.insert(out.end(), inner.begin(), inner.end());
    return out;
}

// Entitlements DER（ZSign/libsecurity 格式）
bool derEntValue(id obj, DerBuf& out);
bool derEntValue(id obj, DerBuf& out) {
    if ([obj isKindOfClass:[NSDictionary class]]) {
        NSArray* keys = [[obj allKeys] sortedArrayUsingSelector:@selector(compare:)];
        DerBuf body;
        for (id k in keys) {
            DerBuf entry, ev;
            if (!derEntValue(obj[k], ev)) return false;
            NSString* ks = (NSString*)k;
            NSData* kd = [ks dataUsingEncoding:NSUTF8StringEncoding];
            entry.u8(0x0c); entry.len(kd.length); entry.bytes(kd.bytes, kd.length); entry.bytes(ev.d);
            body.tlv(0x30, entry.d);
        }
        out.u8(0xb0); out.len(body.d.size()); out.bytes(body.d);
        return true;
    }
    if ([obj isKindOfClass:[NSArray class]]) {
        DerBuf body;
        for (id v in obj) { if (!derEntValue(v, body)) return false; }
        out.u8(0x30); out.len(body.d.size()); out.bytes(body.d);
        return true;
    }
    if ([obj isKindOfClass:[NSString class]]) {
        NSData* d = [(NSString*)obj dataUsingEncoding:NSUTF8StringEncoding];
        out.u8(0x0c); out.len(d.length); out.bytes(d.bytes, d.length);
        return true;
    }
    if ([obj isKindOfClass:[NSNumber class]]) {
        NSNumber* num = (NSNumber*)obj;
        if (CFGetTypeID((__bridge CFTypeRef)num) == CFBooleanGetTypeID()) {
            out.u8(0x01); out.u8(0x01); out.u8([num boolValue] ? 0xff : 0x00);
            return true;
        }
        long long v = [num longLongValue];
        uint8_t be[8]; for (int i = 0; i < 8; i++) be[i] = (uint8_t)(v >> (56 - 8 * i));
        int s = 0;
        while (s < 7) {
            if (be[s] == 0x00 && !(be[s + 1] & 0x80)) { s++; continue; }
            if (be[s] == 0xff && (be[s + 1] & 0x80)) { s++; continue; }
            break;
        }
        out.u8(0x02); out.len(8 - s); out.bytes(be + s, 8 - s);
        return true;
    }
    return false;
}
bool buildDerEntitlements(NSDictionary* dict, std::vector<uint8_t>& blob) {
    DerBuf body; body.u8(0x02); body.u8(0x01); body.u8(0x01);
    if (!derEntValue(dict, body)) return false;
    DerBuf raw; raw.u8(0x70); raw.len(body.d.size()); raw.bytes(body.d);
    blob.assign(8, 0);
    wrBE32(blob.data(), 0xfade7172); wrBE32(blob.data() + 4, (uint32_t)(8 + raw.d.size()));
    blob.insert(blob.end(), raw.d.begin(), raw.d.end());
    return true;
}
std::vector<uint8_t> wrapEntitlementsXML(const uint8_t* xml, size_t n) {
    std::vector<uint8_t> o(8);
    wrBE32(o.data(), 0xfade7171); wrBE32(o.data() + 4, (uint32_t)(8 + n));
    o.insert(o.end(), xml, xml + n);
    return o;
}

// CodeDirectory（v0x20400；hashType 1=SHA1 主、2=SHA256 副）
struct CDSpec {
    std::string ident, team;
    uint32_t codeLimit = 0, nSpecial = 0;
    uint64_t execSegLimit = 0, execSegFlags = 0;
    std::vector<std::vector<uint8_t>> specialHashes; // 由高槽位到 -1 順序（index 0 = 槽 -nSpecial）
    std::vector<std::vector<uint8_t>> codeHashes;
};
std::vector<uint8_t> buildCD(const CDSpec& s, int hashType) {
    const uint32_t hs = hashType == 1 ? 20 : 32;
    const uint32_t hdr = 88;
    uint32_t identLen = (uint32_t)s.ident.size() + 1;
    uint32_t teamLen = s.team.empty() ? 0 : (uint32_t)s.team.size() + 1;
    uint32_t total = hdr + identLen + teamLen + s.nSpecial * hs + (uint32_t)s.codeHashes.size() * hs;
    std::vector<uint8_t> cd(total, 0);
    uint8_t* p = cd.data();
    wrBE32(p + 0, 0xfade0c02); wrBE32(p + 4, total); wrBE32(p + 8, 0x20400); wrBE32(p + 12, 0);
    wrBE32(p + 16, hdr + identLen + teamLen + s.nSpecial * hs); // hashOffset
    wrBE32(p + 20, hdr);                                        // identOffset
    wrBE32(p + 24, s.nSpecial); wrBE32(p + 28, (uint32_t)s.codeHashes.size());
    wrBE32(p + 32, s.codeLimit);
    p[36] = (uint8_t)hs; p[37] = (uint8_t)hashType; p[38] = 0; p[39] = 12; // pageSize 2^12
    if (!s.team.empty()) wrBE32(p + 48, hdr + identLen);        // teamOffset @0x20200 (44+4)
    uint8_t* q = p + hdr;
    memcpy(q, s.ident.data(), s.ident.size()); q += identLen;
    if (!s.team.empty()) { memcpy(q, s.team.data(), s.team.size()); q += teamLen; }
    for (auto& h : s.specialHashes) { memcpy(q, h.data(), hs); q += hs; }
    for (auto& h : s.codeHashes) { memcpy(q, h.data(), hs); q += hs; }
    // execSeg 欄位（0x20400）：base@64 limit@72 flags@80
    wrBE32(p + 64, 0); wrBE32(p + 68, 0);
    wrBE32(p + 72, (uint32_t)(s.execSegLimit >> 32)); wrBE32(p + 76, (uint32_t)s.execSegLimit);
    wrBE32(p + 80, (uint32_t)(s.execSegFlags >> 32)); wrBE32(p + 84, (uint32_t)s.execSegFlags);
    return cd;
}

// 取證書的 subject / issuer Name TLV
bool certNames(const uint8_t* b, size_t n, std::vector<uint8_t>& subj, std::vector<uint8_t>& iss) {
    DerNode cert, tbs, nd; size_t off;
    if (!derRead(b, n, 0, cert) || !derChild(b, n, 0, cert, 0, off, nd)) return false;
    size_t tbsOff = off; DerNode t = nd;
    int idx = 0; size_t co; DerNode f;
    if (derChild(b, n, tbsOff, t, 0, co, f) && f.tag == 0xa0) idx = 1;
    if (!derChild(b, n, tbsOff, t, idx + 2, co, f)) return false;
    iss.assign(b + co, b + co + f.total);
    if (!derChild(b, n, tbsOff, t, idx + 4, co, f)) return false;
    subj.assign(b + co, b + co + f.total);
    return true;
}

// CMS（detached，內容＝主 CD；照 ZSign/openssl 的屬性組）
bool buildCMS(const std::vector<uint8_t>& cd1, const std::vector<uint8_t>& cd256,
              std::vector<uint8_t>& out, std::string& err, std::string& chainNote) {
    auto oidSHA256 = derOID({0x60, 0x86, 0x48, 0x01, 0x65, 0x03, 0x04, 0x02, 0x01});
    auto oidData = derOID({0x2a, 0x86, 0x48, 0x86, 0xf7, 0x0d, 0x01, 0x07, 0x01});
    auto oidSignedData = derOID({0x2a, 0x86, 0x48, 0x86, 0xf7, 0x0d, 0x01, 0x07, 0x02});
    auto oidRSA = derOID({0x2a, 0x86, 0x48, 0x86, 0xf7, 0x0d, 0x01, 0x01, 0x01});
    auto oidCT = derOID({0x2a, 0x86, 0x48, 0x86, 0xf7, 0x0d, 0x01, 0x09, 0x03});
    auto oidST = derOID({0x2a, 0x86, 0x48, 0x86, 0xf7, 0x0d, 0x01, 0x09, 0x05});
    auto oidMD = derOID({0x2a, 0x86, 0x48, 0x86, 0xf7, 0x0d, 0x01, 0x09, 0x04});
    auto oid91 = derOID({0x2a, 0x86, 0x48, 0x86, 0xf7, 0x63, 0x64, 0x09, 0x01});
    auto oid92 = derOID({0x2a, 0x86, 0x48, 0x86, 0xf7, 0x63, 0x64, 0x09, 0x02});
    auto algSHA256 = DerBuf().tlvv(0x30, derCat({oidSHA256, std::vector<uint8_t>{0x05, 0x00}}));
    auto algRSA = DerBuf().tlvv(0x30, derCat({oidRSA, std::vector<uint8_t>{0x05, 0x00}}));

    // 憑證鏈：leaf + 主題==leaf.issuer 的 WWDR + 主題==WWDR.issuer 的 Root
    std::vector<std::vector<uint8_t>> certs;
    certs.push_back(std::vector<uint8_t>((const uint8_t*)gCertDER.bytes, (const uint8_t*)gCertDER.bytes + gCertDER.length));
    chainNote = "leaf";
    std::vector<uint8_t> interIssuer;
    for (auto& wc : kWWDRCerts) {
        std::vector<uint8_t> subj, iss;
        if (certNames(wc.der, wc.len, subj, iss) && subj == gLeafIssuerTLV) {
            certs.push_back(std::vector<uint8_t>(wc.der, wc.der + wc.len));
            interIssuer = iss;
            chainNote += std::string("+") + wc.name;
            break;
        }
    }
    if (!interIssuer.empty()) {
        for (auto& wc : kWWDRCerts) {
            std::vector<uint8_t> subj, iss;
            if (certNames(wc.der, wc.len, subj, iss) && subj == interIssuer) {
                certs.push_back(std::vector<uint8_t>(wc.der, wc.der + wc.len));
                chainNote += std::string("+") + wc.name;
                break;
            }
        }
    } else {
        chainNote += "+(WWDR 未匹配)";
    }

    // 簽署屬性
    std::vector<uint8_t> md = sha256Of(cd1.data(), cd1.size());
    std::vector<uint8_t> h1 = sha1Of(cd1.data(), cd1.size());
    std::vector<uint8_t> h256 = sha256Of(cd256.data(), cd256.size());
    NSData* b64a = [NSData dataWithBytes:h1.data() length:h1.size()];
    NSData* b64b = [NSData dataWithBytes:h256.data() length:20];
    NSString* plist = [NSString stringWithFormat:
        @"<?xml version=\"1.0\" encoding=\"UTF-8\"?>\n"
        "<!DOCTYPE plist PUBLIC \"-//Apple//DTD PLIST 1.0//EN\" \"http://www.apple.com/DTDs/PropertyList-1.0.dtd\">\n"
        "<plist version=\"1.0\">\n<dict>\n\t<key>cdhashes</key>\n\t<array>\n\t\t<data>%@</data>\n\t\t<data>%@</data>\n\t</array>\n</dict>\n</plist>\n",
        [b64a base64EncodedStringWithOptions:0], [b64b base64EncodedStringWithOptions:0]];
    NSData* plistData = [plist dataUsingEncoding:NSUTF8StringEncoding];

    char tbuf[16];
    time_t now = time(NULL); struct tm g; gmtime_r(&now, &g);
    strftime(tbuf, sizeof(tbuf), "%y%m%d%H%M%SZ", &g);

    std::vector<std::vector<uint8_t>> attrs;
    attrs.push_back(DerBuf().tlvv(0x30, derCat({oidCT, DerBuf().tlvv(0x31, oidData)})));
    {
        DerBuf tb; tb.u8(0x17); tb.len(strlen(tbuf)); tb.bytes(tbuf, strlen(tbuf));
        attrs.push_back(DerBuf().tlvv(0x30, derCat({oidST, DerBuf().tlvv(0x31, tb.d)})));
    }
    attrs.push_back(DerBuf().tlvv(0x30, derCat({oidMD, DerBuf().tlvv(0x31, DerBuf().tlvv(0x04, md))})));
    attrs.push_back(DerBuf().tlvv(0x30, derCat({oid91, DerBuf().tlvv(0x31, DerBuf().tlvv(0x04, std::vector<uint8_t>((const uint8_t*)plistData.bytes, (const uint8_t*)plistData.bytes + plistData.length)))})));
    {
        auto inner = DerBuf().tlvv(0x30, derCat({oidSHA256, DerBuf().tlvv(0x04, h256)}));
        attrs.push_back(DerBuf().tlvv(0x30, derCat({oid92, DerBuf().tlvv(0x31, inner)})));
    }
    std::sort(attrs.begin(), attrs.end());
    DerBuf attrsConcat; for (auto& a : attrs) attrsConcat.bytes(a);
    std::vector<uint8_t> attrsSET = DerBuf().tlvv(0x31, attrsConcat.d);

    CFErrorRef cfErr = NULL;
    CFDataRef sig = SecKeyCreateSignature(gPrivKey, kSecKeyAlgorithmRSASignatureMessagePKCS1v15SHA256,
                                          (__bridge CFDataRef)[NSData dataWithBytes:attrsSET.data() length:attrsSET.size()], &cfErr);
    if (!sig) {
        err = cfErr ? [(__bridge NSError*)cfErr localizedDescription].UTF8String : "SecKeyCreateSignature 失敗";
        if (cfErr) CFRelease(cfErr);
        return false;
    }
    std::vector<uint8_t> sigBytes((const uint8_t*)CFDataGetBytePtr(sig), (const uint8_t*)CFDataGetBytePtr(sig) + CFDataGetLength(sig));
    CFRelease(sig);

    auto sid = DerBuf().tlvv(0x30, derCat({gLeafIssuerTLV, gLeafSerialTLV}));
    auto signerInfo = DerBuf().tlvv(0x30, derCat({
        derInt(1), sid, algSHA256,
        DerBuf().tlvv(0xa0, attrsConcat.d),
        algRSA, DerBuf().tlvv(0x04, sigBytes)}));
    auto signerInfos = DerBuf().tlvv(0x31, signerInfo);
    DerBuf certsConcat; for (auto& c : certs) certsConcat.bytes(c);
    auto certsA0 = DerBuf().tlvv(0xa0, certsConcat.d);
    auto encap = DerBuf().tlvv(0x30, oidData);
    auto digestSet = DerBuf().tlvv(0x31, algSHA256);
    auto signedData = DerBuf().tlvv(0x30, derCat({derInt(1), digestSet, encap, certsA0, signerInfos}));
    out = DerBuf().tlvv(0x30, derCat({oidSignedData, DerBuf().tlvv(0xa0, signedData)}));
    return true;
}
} // namespace

extern "C" {

// 以導入身份真簽名單一 Mach-O（dylib 或主程式）；ident 為 NULL 時用 LC_ID_DYLIB
int paxidx_cert_sign_file(const char* srcPath, const char* dstPath, const char* identOrNull, char* report, size_t cap) {
    auto fail = [&](const std::string& m) { if (report && cap) snprintf(report, cap, "%s", m.c_str()); return 1; };
    if (!gCertDER || !gPrivKey) return fail("尚未導入證書");
    NSMutableData* data = [NSMutableData dataWithContentsOfFile:[NSString stringWithUTF8String:srcPath]];
    if (!data) return fail("讀不到來源檔");
    uint8_t* base = (uint8_t*)data.mutableBytes;
    size_t n = data.length;
    if (n < 64 || rdLE32(base) != 0xfeedfacf) return fail("不是 thin arm64 Mach-O");
    uint32_t filetype = rdLE32(base + 12);
    uint32_t ncmds = rdLE32(base + 16);
    uint32_t dataoff = 0, datasize = 0; size_t csLcOff = 0;
    uint64_t textFS = 0, leFoff = 0; size_t leFsOff = 0, leVsOff = 0;
    std::string idDylib;
    size_t lcOff = 32;
    for (uint32_t i = 0; i < ncmds; i++) {
        if (lcOff + 8 > n) break;
        uint32_t cmd = rdLE32(base + lcOff), csz = rdLE32(base + lcOff + 4);
        if (csz < 8) break;
        if (cmd == 0x19 && lcOff + 72 <= n) { // LC_SEGMENT_64
            char seg[17] = {0}; memcpy(seg, base + lcOff + 8, 16);
            if (!strcmp(seg, "__TEXT")) textFS = rdLE64(base + lcOff + 48);
            if (!strcmp(seg, "__LINKEDIT")) { leFoff = rdLE64(base + lcOff + 40); leVsOff = lcOff + 32; leFsOff = lcOff + 48; }
        } else if (cmd == 0x1d && lcOff + 16 <= n) { // LC_CODE_SIGNATURE
            dataoff = rdLE32(base + lcOff + 8); datasize = rdLE32(base + lcOff + 12); csLcOff = lcOff;
        } else if (cmd == 0x0d && lcOff + 12 <= n) { // LC_ID_DYLIB
            uint32_t no = rdLE32(base + lcOff + 8);
            if (lcOff + no < n) idDylib = (const char*)(base + lcOff + no);
        }
        lcOff += csz;
    }
    if (!dataoff) return fail("沒有 LC_CODE_SIGNATURE");
    std::string ident = identOrNull ? identOrNull : (idDylib.empty() ? "paxidx.file" : idDylib);
    std::string team = !gProfileTeam.empty() ? gProfileTeam : gLeafOU;

    // Entitlements：只有主程式（MH_EXECUTE）才掛；來源＝描述檔（改寫 app id）或最小集
    const bool isExec = filetype == 2;
    std::vector<uint8_t> entBlob, derBlob;
    std::string entNote = "無（非主程式）";
    NSDictionary* entDict = nil;
    if (isExec) {
        NSMutableDictionary* d = nil;
        if (!gProfileEntXML.empty()) {
            id obj = [NSPropertyListSerialization propertyListWithData:[NSData dataWithBytes:gProfileEntXML.data() length:gProfileEntXML.size()] options:0 format:NULL error:NULL];
            if ([obj isKindOfClass:[NSDictionary class]]) d = [obj mutableCopy];
        }
        if (!d) d = [NSMutableDictionary dictionary];
        if (!team.empty()) {
            d[@"application-identifier"] = [NSString stringWithFormat:@"%s.%s", team.c_str(), ident.c_str()];
            d[@"com.apple.developer.team-identifier"] = [NSString stringWithUTF8String:team.c_str()];
        }
        if (!d[@"get-task-allow"]) d[@"get-task-allow"] = @YES;
        entDict = d;
        NSData* xml = [NSPropertyListSerialization dataWithPropertyList:d format:NSPropertyListXMLFormat_v1_0 options:0 error:NULL];
        if (xml) entBlob = wrapEntitlementsXML((const uint8_t*)xml.bytes, xml.length);
        if (!buildDerEntitlements(d, derBlob)) derBlob.clear();
        entNote = gProfileEntXML.empty() ? "最小集（無描述檔）" : "描述檔（app id 已改寫）";
    }

    std::vector<uint8_t> reqBlob = buildRequirements(ident, gLeafCN);
    // 槽位（高→低）：DER7, rep6=0, Ent5, app4=0, CodeRes3=0, Req2, Info1=0
    struct SlotH { std::vector<uint8_t> sha1, sha256; };
    auto H = [](const std::vector<uint8_t>& blob) {
        SlotH s; if (!blob.empty()) { s.sha1 = sha1Of(blob.data(), blob.size()); s.sha256 = sha256Of(blob.data(), blob.size()); }
        else { s.sha1.assign(20, 0); s.sha256.assign(32, 0); }
        return s;
    };
    std::vector<SlotH> slots = { H(derBlob), H({}), H(entBlob), H({}), H({}), H(reqBlob), H({}) }; // index 0 = 槽7
    int nSpecial = 7;
    while (nSpecial > 2) {
        const SlotH& top = slots[7 - nSpecial];
        bool zero = true; for (uint8_t c : top.sha256) if (c) { zero = false; break; }
        if (!zero) break;
        nSpecial--;
    }
    uint32_t nPages = (dataoff + 4095) / 4096;
    auto cdLen = [&](int hs) {
        return 88u + (uint32_t)ident.size() + 1 + (team.empty() ? 0 : (uint32_t)team.size() + 1) + nSpecial * hs + nPages * hs;
    };
    uint32_t cmsEst = 2048 + (uint32_t)gCertDER.length + 2600; // leaf + WWDR + root + 簽署資訊餘量
    uint32_t nSlots = 3 + (!entBlob.empty() ? 1 : 0) + (!derBlob.empty() ? 1 : 0) + 1; // CD,Req,Ent?,DER?,Alt,CMS
    uint32_t need = 12 + 8 * nSlots + cdLen(20) + cdLen(32) + (uint32_t)reqBlob.size() + (uint32_t)entBlob.size() + (uint32_t)derBlob.size() + cmsEst;
    // 擴區（簽名區須在檔尾）
    if (datasize < need) {
        if ((uint64_t)dataoff + datasize != (uint64_t)n) return fail("簽名區不在檔尾，無法擴區");
        [data increaseLengthBy:(need - datasize)];
        base = (uint8_t*)data.mutableBytes; n = data.length;
        if (leFsOff) { wrLE64(base + leFsOff, (uint64_t)n - leFoff); uint64_t vs = (n - leFoff + 0x3fff) & ~0x3fffULL; wrLE64(base + leVsOff, vs); }
    }
    wrLE32(base + csLcOff + 12, need); // datasize = 預留量（雜湊前定版）
    // 頁雜湊（codeLimit = dataoff）
    std::vector<std::vector<uint8_t>> pageSha1, pageSha256;
    for (uint32_t i = 0; i < nPages; i++) {
        size_t off = (size_t)i * 4096, ln = std::min<size_t>(4096, dataoff - off);
        pageSha1.push_back(sha1Of(base + off, ln));
        pageSha256.push_back(sha256Of(base + off, ln));
    }
    auto mkSpec = [&](int ht) {
        CDSpec s; s.ident = ident; s.team = team; s.codeLimit = dataoff; s.nSpecial = nSpecial;
        s.execSegLimit = textFS; s.execSegFlags = isExec ? 1 : 0;
        for (int i = 7 - nSpecial; i < 7; i++) s.specialHashes.push_back(ht == 1 ? slots[i].sha1 : slots[i].sha256);
        s.codeHashes = ht == 1 ? pageSha1 : pageSha256;
        return s;
    };
    std::vector<uint8_t> cd1 = buildCD(mkSpec(1), 1);
    std::vector<uint8_t> cd2 = buildCD(mkSpec(2), 2);
    std::string cmsErr, chainNote;
    std::vector<uint8_t> cms;
    if (!buildCMS(cd1, cd2, cms, cmsErr, chainNote)) return fail("CMS 失敗: " + cmsErr);
    std::vector<uint8_t> cmsBlob(8);
    wrBE32(cmsBlob.data(), 0xfade0b01); wrBE32(cmsBlob.data() + 4, (uint32_t)(8 + cms.size()));
    cmsBlob.insert(cmsBlob.end(), cms.begin(), cms.end());
    // 組 superblob（ZSign 順序：CD, Req, Ent, DER, AltCD, CMS）
    struct Ent { uint32_t type; const std::vector<uint8_t>* blob; };
    std::vector<Ent> ents = { {0, &cd1}, {2, &reqBlob} };
    if (!entBlob.empty()) ents.push_back({5, &entBlob});
    if (!derBlob.empty()) ents.push_back({7, &derBlob});
    ents.push_back({0x1000, &cd2});
    ents.push_back({0x10000, &cmsBlob});
    uint32_t sbTotal = 12 + 8 * (uint32_t)ents.size();
    for (auto& e : ents) sbTotal += (uint32_t)e.blob->size();
    if (sbTotal > need) return fail("內部錯誤：superblob 超出預留區");
    std::vector<uint8_t> sb(sbTotal, 0);
    wrBE32(sb.data(), 0xfade0cc0); wrBE32(sb.data() + 4, sbTotal); wrBE32(sb.data() + 8, (uint32_t)ents.size());
    uint32_t cur = 12 + 8 * (uint32_t)ents.size();
    for (size_t i = 0; i < ents.size(); i++) {
        wrBE32(sb.data() + 12 + 8 * i, ents[i].type);
        wrBE32(sb.data() + 12 + 8 * i + 4, cur);
        memcpy(sb.data() + cur, ents[i].blob->data(), ents[i].blob->size());
        cur += (uint32_t)ents[i].blob->size();
    }
    memcpy(base + dataoff, sb.data(), sbTotal);
    if (![data writeToFile:[NSString stringWithUTF8String:dstPath] atomically:YES]) return fail("寫出失敗");
    std::vector<uint8_t> cdhash = sha256Of(cd2.data(), cd2.size());
    char buf[1024];
    snprintf(buf, sizeof(buf),
             "簽名完成 ident=%s team=%s\nsuperblob %u bytes（預留 %u）CMS %zu bytes\ncdhash(sha256副CD) %s\n鏈: %s\nentitlements: %s nSpecial=%d nPages=%u",
             ident.c_str(), team.c_str(), sbTotal, need, cmsBlob.size(), hexOf(cdhash.data(), cdhash.size()).c_str(),
             chainNote.c_str(), entNote.c_str(), nSpecial, nPages);
    if (report && cap) snprintf(report, cap, "%s", buf);
    return 0;
}

} // extern "C"
