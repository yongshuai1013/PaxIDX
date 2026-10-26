// PaxIDX 工具鏈 dylib 實現：在 CI 上編進 libPaxIDXNativeToolchain.dylib
// App 端用 dlopen 載入，再 dlsym 這些 paxidx_dylib_* 函數
#include <Foundation/Foundation.h>

#include <cstring>
#include <unistd.h>
#include <fcntl.h>
#include <string>
#include <vector>

#include <llvm/Support/TargetSelect.h>

namespace {

// 註冊 LLVM targets（AArch64），否則 "no targets are registered"
struct TargetInitializer {
    TargetInitializer() {
        llvm::InitializeAllTargets();
        llvm::InitializeAllTargetMCs();
        llvm::InitializeAllAsmPrinters();
        llvm::InitializeAllAsmParsers();
    }
};
static TargetInitializer g_targetInit;

// 診斷文字拷貝到調用方 buffer
void copyDiag(const std::string &value, char *buffer, size_t capacity) {
    if (!buffer || capacity == 0) return;
    size_t n = value.size() < capacity - 1 ? value.size() : capacity - 1;
    memcpy(buffer, value.data(), n);
    buffer[n] = '\0';
}

// 從 argv 取 "-flag value" 的 value
const char *argValue(int argc, const char * const *argv, const char *flag) {
    for (int i = 0; i + 1 < argc; i++) {
        if (strcmp(argv[i], flag) == 0) return argv[i + 1];
    }
    return nullptr;
}

// 按副檔名判語言
const char *langForPath(const char *path) {
    const char *dot = strrchr(path, '.');
    if (!dot) return "c";
    if (strcmp(dot, ".m") == 0) return "objective-c";
    if (strcmp(dot, ".mm") == 0) return "objective-c++";
    if (strcmp(dot, ".cpp") == 0 || strcmp(dot, ".cc") == 0 ||
        strcmp(dot, ".cxx") == 0 || strcmp(dot, ".C") == 0)
        return "c++";
    return "c";
}

} // namespace

// dylib 專用：CI 編譯時一定有 headers，不需要 __has_include 判斷

// Apple SDK 把 IBAction/IBOutlet 預定義成宏，會跟 clang 的 AttrList.inc 拼字衝突
#ifdef IBAction
#undef IBAction
#endif
#ifdef IBOutlet
#undef IBOutlet
#endif

#include <clang/Basic/Diagnostic.h>
#include <clang/Basic/DiagnosticOptions.h>
#include <clang/CodeGen/CodeGenAction.h>
#include <clang/Frontend/CompilerInstance.h>
#include <clang/Frontend/CompilerInvocation.h>
#include <clang/Frontend/TextDiagnosticPrinter.h>
#include <clang/Serialization/PCHContainerOperations.h>
#include <lld/Common/Driver.h>
#include <llvm/ADT/ArrayRef.h>
#include <llvm/ADT/IntrusiveRefCntPtr.h>
#include <llvm/Support/raw_ostream.h>

#include <memory>

LLD_HAS_DRIVER(macho)

extern "C" int paxidx_dylib_available(void) { return 1; }

extern "C" int paxidx_dylib_clang_compile(int argc, const char * const *argv,
                                    char *diagnostics, size_t diagnostics_capacity) {
    const char *triple = argValue(argc, argv, "-target");
    const char *sdk = argValue(argc, argv, "-isysroot");
    const char *src = argValue(argc, argv, "-c");
    const char *obj = argValue(argc, argv, "-o");
    if (!triple || !sdk || !src || !obj) {
        copyDiag("paxidx clang: 缺參數（要 -target/-isysroot/-c/-o）",
                 diagnostics, diagnostics_capacity);
        return 64;
    }

    std::string diagText;
    llvm::raw_string_ostream diagOS(diagText);

    auto diagOpts = llvm::makeIntrusiveRefCnt<clang::DiagnosticOptions>();
    auto diagPrinter = std::make_unique<clang::TextDiagnosticPrinter>(diagOS, diagOpts.get());
    auto diagIDs = llvm::IntrusiveRefCntPtr<clang::DiagnosticIDs>(new clang::DiagnosticIDs());
    clang::DiagnosticsEngine diags(diagIDs, diagOpts, diagPrinter.get(), false);

    std::vector<std::string> owned = {
        "-triple", triple,
        "-emit-obj",
        "-o", obj,
        "-isysroot", sdk,
        "-internal-isystem", std::string(sdk) + "/usr/include",
        "-fblocks",
        "-fobjc-arc",
        "-x", langForPath(src),
        src,
    };
    std::vector<const char *> args;
    args.reserve(owned.size());
    for (auto &s : owned) args.push_back(s.c_str());

    auto invocation = std::make_shared<clang::CompilerInvocation>();
    if (!clang::CompilerInvocation::CreateFromArgs(*invocation, args, diags)) {
        diagOS.flush();
        copyDiag(diagText, diagnostics, diagnostics_capacity);
        return 65;
    }

    clang::CompilerInstance compiler(std::make_shared<clang::PCHContainerOperations>());
    compiler.setInvocation(invocation);
    compiler.createDiagnostics(diagPrinter.release(), true);
    if (!compiler.hasDiagnostics()) {
        copyDiag("paxidx clang: 建 diagnostics 失敗", diagnostics, diagnostics_capacity);
        return 66;
    }

    clang::EmitObjAction action;
    bool ok = compiler.ExecuteAction(action);
    diagOS.flush();
    if (!ok) {
        copyDiag(diagText.empty() ? "paxidx clang: 編譯失敗" : diagText,
                 diagnostics, diagnostics_capacity);
        return 1;
    }
    copyDiag("", diagnostics, diagnostics_capacity);
    return 0;
}

// 從 SDK 的 SDKSettings.plist 讀版本號，失敗回 fallback
static std::string sdkVersion(const char *sdkPath, const char *fallback) {
    NSString *path = [NSString stringWithFormat:@"%s/SDKSettings.plist", sdkPath];
    NSDictionary *d = [NSDictionary dictionaryWithContentsOfFile:path];
    NSString *v = d[@"Version"];
    if (v) return std::string([v UTF8String]);
    return fallback;
}

// Swift 前端（僅 Swift 版 dylib 有，C 版不編這段）
// 最小化：只前向聲明需要的函數，不 include Swift 頭文件（shims 依賴太深編不過）
//
// 調用序列對齊 Nyxian 的 CoreCompiler（CCSwiftCompilerJobExecute）：
//   1. initializeSwiftModules() 先調一次（std::call_once）
//   2. performFrontend 之前摘掉 LLVM fatal error handler，之後裝回自訂的
//   3. performFrontend 的診斷默認打到 stderr——調用期間把 fd 2 重定向到
//      臨時文件，結束讀回填進 diagnostics，失敗不再是「rc=1，無診斷」
//
// initializeSwiftModules 在上游 SwiftCompilerSources/stubs.cpp 裡就是
// 一個空樁（void initializeSwiftModules() {}），只為滿足鏈接器存在；
// 我們只編 swiftFrontendTool、沒鏈 SwiftCompilerSources，所以當年一調它
// 就報符號不存在。這裡補上同一個空樁，純粹跟上游 main 的調用習慣對齊。
#ifdef PAXIDX_HAS_SWIFT_FRONTEND
#include <llvm/Support/ErrorHandling.h>

#include <cstdio>
#include <cstdlib>
#include <mutex>
#include <fcntl.h>
#include <unistd.h>
#include <csignal>
#include <atomic>
#include <thread>
#include <dirent.h>
#include <execinfo.h>
#include <mach/mach.h>

extern "C" void initializeSwiftModules() {}

// 診斷（2026-10-22 真機 Swift 編譯一按就閃退且無系統日誌而加）：
// 把檢查點與前端 stderr 留在 App 的 Documents，崩了也能事後翻出來。
static std::string paxidxDocumentsDir() {
    NSArray *dirs = NSSearchPathForDirectoriesInDomains(
        NSDocumentDirectory, NSUserDomainMask, YES);
    NSString *d = dirs.firstObject;
    return d ? std::string([d UTF8String]) : std::string("/tmp");
}
static void paxidxDebugNote(const std::string &line) {
    std::string path = paxidxDocumentsDir() + "/paxidx-swift-debug.log";
    int fd = open(path.c_str(), O_WRONLY | O_CREAT | O_APPEND, 0644);
    if (fd >= 0) {
        (void)!write(fd, line.data(), line.size());
        (void)!write(fd, "\n", 1);
        close(fd);
    }
}
static std::string paxidxJoinArgs(int argc, const char * const *argv) {
    std::string out;
    for (int i = 0; i < argc; i++) {
        if (i) out += " | ";
        out += argv[i] ? argv[i] : "(null)";
    }
    return out;
}

// 診斷 v2（2026-10-23）：v1 證實死點在 performFrontend 內部且 stderr 全空
// （無聲死亡）。這一版要分清三種死法：
//   a) trap／段錯 → 下面的信號處理器會留下信號號＋回溯；
//   b) exit() → atexit 標記會留下；
//   c) jetsam SIGKILL（抓不到）→ 心跳線程留下的 footprint 曲線會在死前
//      一路爬升、且既無 SIGNAL 也無 ATEXIT。
static int g_diagFd = -1;
static std::atomic<bool> g_hbStop{false};

static void paxidxCrashHandler(int sig, siginfo_t *info, void *) {
    int fd = g_diagFd;
    if (fd < 0) {
        std::string p = paxidxDocumentsDir() + "/paxidx-swift-debug.log";
        fd = open(p.c_str(), O_WRONLY | O_CREAT | O_APPEND, 0644);
    }
    if (fd >= 0) {
        char buf[160];
        int n = snprintf(buf, sizeof(buf), "!!! SIGNAL %d fault_addr=%p\n",
                         sig, info ? info->si_addr : nullptr);
        if (n > 0) (void)!write(fd, buf, (size_t)n);
        void *frames[64];
        int count = backtrace(frames, 64);
        if (count > 0) backtrace_symbols_fd(frames, count, fd);
    }
    signal(sig, SIG_DFL);
    raise(sig);
}

static void paxidxAtExit() {
    paxidxDebugNote("!!! ATEXIT (exit() was called)");
}

static uint64_t paxidxFootprintBytes() {
    task_vm_info_data_t info;
    mach_msg_type_number_t count = TASK_VM_INFO_COUNT;
    if (task_info(mach_task_self(), TASK_VM_INFO, (task_info_t)&info,
                  &count) != KERN_SUCCESS)
        return 0;
    return (uint64_t)info.phys_footprint;
}

static std::string paxidxListDir(const std::string &path, int maxEntries) {
    DIR *d = opendir(path.c_str());
    if (!d) return "(cannot open)";
    std::string out;
    int n = 0;
    while (auto *e = readdir(d)) {
        if (e->d_name[0] == '.') continue;
        if (n >= maxEntries) { out += ", ..."; break; }
        if (n) out += ", ";
        out += e->d_name;
        n++;
    }
    closedir(d);
    return out.empty() ? "(empty)" : out;
}

namespace swift {
class FrontendObserver;
int performFrontend(llvm::ArrayRef<const char *> Args, const char *Argv0,
                    void *Context, FrontendObserver *observer);
} // namespace swift

namespace {

// 跟 Nyxian 的 CCLLVMErrorHandler 同款：印出原因後 abort（fatal 本無路可退）
void paxidxLLVMFatalHandler(void *userData, const char *reason, bool genCrashDiag) {
    (void)userData; (void)genCrashDiag;
    fprintf(stderr, "paxidx swift: fatal LLVM error: %s\n", reason);
    abort();
}

void initSwiftModulesOnce() {
    static std::once_flag flag;
    std::call_once(flag, [] { initializeSwiftModules(); });
}

// RAII：構造時把 stderr 重定向到臨時文件，finish() 恢復 fd 並讀回內容
struct StderrCapture {
    int savedFd = -1;
    int fileFd = -1;
    std::string path;
    explicit StderrCapture(NSString *tmpDir) {
        NSString *p = [tmpDir stringByAppendingPathComponent:
            @"paxidx-swift-stderr.txt"];
        path = std::string([p UTF8String]);
        fflush(stderr);
        savedFd = dup(STDERR_FILENO);
        fileFd = open(path.c_str(), O_WRONLY | O_CREAT | O_TRUNC, 0600);
        if (fileFd >= 0 && savedFd >= 0) dup2(fileFd, STDERR_FILENO);
    }
    std::string finish() {
        fflush(stderr);
        if (savedFd >= 0) { dup2(savedFd, STDERR_FILENO); close(savedFd); savedFd = -1; }
        if (fileFd >= 0) { close(fileFd); fileFd = -1; }
        std::string text;
        if (!path.empty()) {
            if (FILE *f = fopen(path.c_str(), "r")) {
                char buf[4096]; size_t n;
                while ((n = fread(buf, 1, sizeof(buf), f)) > 0) text.append(buf, n);
                fclose(f);
            }
            path.clear(); // 診斷版：不刪檔，留在 Documents 供事後檢查
        }
        return text;
    }
    ~StderrCapture() { if (savedFd >= 0 || fileFd >= 0) finish(); }
};

} // namespace

extern "C" int paxidx_dylib_swift_compile(int argc, const char * const *argv,
                                    char *diagnostics, size_t diagnostics_capacity) {
    paxidxDebugNote("==== swift_compile run pid=" +
                    std::to_string((int)getpid()) + " argc=" +
                    std::to_string(argc) + " argv: " +
                    paxidxJoinArgs(argc, argv));
    if (g_diagFd < 0) {
        std::string p = paxidxDocumentsDir() + "/paxidx-swift-debug.log";
        g_diagFd = open(p.c_str(), O_WRONLY | O_CREAT | O_APPEND, 0644);
    }
    const char *target = argValue(argc, argv, "-target");
    const char *sdk = argValue(argc, argv, "-sdk");
    const char *output = argValue(argc, argv, "-o");
    const char *moduleCachePath = argValue(argc, argv, "-module-cache-path");
    const char *src = nullptr;
    for (int i = argc - 1; i >= 0; i--) {
        size_t n = strlen(argv[i]);
        if (n > 6 && strcmp(argv[i] + n - 6, ".swift") == 0) {
            src = argv[i];
            break;
        }
    }
    if (!target || !sdk || !output || !src) {
        copyDiag("paxidx swift: 缺參數（要 -target/-sdk/-o/<input.swift>）",
                 diagnostics, diagnostics_capacity);
        return 64;
    }

    // 轉發 module cache 路徑（App 傳來的可寫路徑，否則 clang 寫 ~/.cache 被沙盒拒）
    // SwiftShims 是 Clang 模塊，要用 -Xcc -fmodules-cache-path
    std::string resourceDir = std::string(sdk) + "/usr/lib/swift";
    std::vector<std::string> owned;
    if (moduleCachePath) {
        owned.push_back("-module-cache-path");
        owned.push_back(moduleCachePath);
        // -Xcc 後只跟一個參數，必須用 = 連起來（否則 Clang 收到的 flag 不帶路徑，會被忽略）
        owned.push_back("-Xcc");
        owned.push_back(std::string("-fmodules-cache-path=") + moduleCachePath);
    }
    owned.push_back("-target"); owned.push_back(target);
    owned.push_back("-sdk"); owned.push_back(sdk);
    owned.push_back("-resource-dir"); owned.push_back(resourceDir);
    // Clang 內建頭（stdatomic.h 等）：performFrontend 繞過 driver，Clang 的 resource dir 要手動傳
    // 但目錄必須存在，否則 Clang 初始化失敗，連 print("Hello") 都掛
    // 版本目錄名不寫死：資產 clang-resource-headers.zip 裡是 llvm-build 的
    // lib/clang/<版號>（實測為 19），先前寫死 19.1.5 永遠探不到。
    // 掃 usr/lib/clang/ 下第一個含 include/stdarg.h 的子目錄就用它。
    {
        std::string clangBase = std::string(sdk) + "/usr/lib/clang";
        std::string clangResourceDir;
        if (DIR *d = opendir(clangBase.c_str())) {
            while (struct dirent *ent = readdir(d)) {
                if (ent->d_name[0] == '.') continue;
                std::string candidate = clangBase + "/" + ent->d_name;
                FILE *f = fopen((candidate + "/include/stdarg.h").c_str(), "r");
                if (f) {
                    fclose(f);
                    clangResourceDir = candidate;
                    break;
                }
            }
            closedir(d);
        }
        if (!clangResourceDir.empty()) {
            owned.push_back("-Xcc");
            owned.push_back("-resource-dir");
            owned.push_back("-Xcc");
            owned.push_back(clangResourceDir);
        }
        // 不存在就不傳，退回默認行為（至少 pure Swift 能用）
    }
    // 對齊 Nyxian 的 Swift 參數配方（NXSwiftFlagsForCodeTemplateLanguage）：
    // 開 ObjC 互通，前端才能 import Foundation/UIKit 這類 ObjC 框架。
    // 注意：performFrontend 直接吃前端參數，不能帶 -Xfrontend——那是 driver
    // 層的轉發語法，前端本體會報 unknown argument（2026-10-21 真機實測證實）。
    // -parse-as-library 保留（2026-10-26 定案）：逐文件編譯時每個文件都
    // 按庫文件編，才不會個個都合成一個 _main（CI E9 主機實證：拿掉旗標
    // 後連純函數文件也被當成主文件、與 C 的 main 在連結時重複定義）。
    // 代價是頂層代碼文件（App 模板的 print("Hello")）會被這旗標擋下
    // （"expressions are not allowed at the top level"，裝 #57 前的靜默
    // rc=1 即此故）——解法在下方 M4b：首次編譯若正是死在這句診斷，就
    // 拿掉旗標、只把這個文件按主文件重編一次。頂層文件合成 _main 後
    // 與 C 的 main 衝突與否，回到 App 既有的「進入點只能留一個」規則。
    owned.push_back("-parse-as-library");
    owned.push_back("-enable-objc-interop");
    owned.push_back("-emit-object");
    owned.push_back("-o"); owned.push_back(output);
    owned.push_back(src);
    std::vector<const char *> args;
    args.reserve(owned.size());
    for (auto &s : owned) args.push_back(s.c_str());

    {
        std::string joined;
        for (size_t i = 0; i < args.size(); i++) {
            if (i) joined += " | ";
            joined += args[i] ? args[i] : "(null)";
        }
        paxidxDebugNote("M2 frontend args: " + joined);
    }
    if (sdk) {
        std::string sdkStr = sdk;
        paxidxDebugNote("STAT sdk/usr/lib/swift: " +
                        paxidxListDir(sdkStr + "/usr/lib/swift", 24));
        paxidxDebugNote("STAT sdk/usr/lib/clang: " +
                        paxidxListDir(sdkStr + "/usr/lib/clang", 8));
    }
    paxidxDebugNote("STAT Documents/Toolchain: " +
                    paxidxListDir(paxidxDocumentsDir() + "/Toolchain", 16));
    paxidxDebugNote("STAT footprint at entry MB=" +
                    std::to_string(paxidxFootprintBytes() / (1024 * 1024)));
    initSwiftModulesOnce();
    llvm::remove_fatal_error_handler();
    int result = 0;
    std::string captured;
    auto runFrontend = [&](const std::vector<const char *> &a) {
    {
        struct sigaction sa {};
        sa.sa_sigaction = paxidxCrashHandler;
        sa.sa_flags = SA_SIGINFO;
        sigemptyset(&sa.sa_mask);
        for (int sig : {SIGSEGV, SIGBUS, SIGILL, SIGABRT, SIGTRAP, SIGFPE})
            sigaction(sig, &sa, nullptr);
        atexit(paxidxAtExit);
        g_hbStop = false;
        std::thread([] {
            while (!g_hbStop.load()) {
                paxidxDebugNote("HB footprint MB=" +
                                std::to_string(paxidxFootprintBytes() /
                                               (1024 * 1024)));
                usleep(250000);
            }
        }).detach();
        paxidxDebugNote("M3b signal handlers + heartbeat armed");
    }
    {
        NSString *docsDir = [NSString stringWithUTF8String:paxidxDocumentsDir().c_str()];
        StderrCapture cap(docsDir);
        paxidxDebugNote("M3 calling performFrontend");
        result = swift::performFrontend(
            llvm::ArrayRef<const char *>(a.data(), a.size()),
            "swift-frontend", nullptr, nullptr);
        captured = cap.finish();
    }
    g_hbStop = true;
    llvm::install_fatal_error_handler(paxidxLLVMFatalHandler);
    paxidxDebugNote("M4 performFrontend returned rc=" + std::to_string(result) +
                    " captured_bytes=" + std::to_string(captured.size()));
    };
    runFrontend(args);
    if (result != 0) {
        // 首次編譯失敗就拿掉旗標、按主文件重編一次：頂層代碼文件正是
        // 死在這裡（"expressions are not allowed at the top level"）。
        // 不拿診斷文字當觸發條件——裝置上前端診斷從不進 StderrCapture
        // （歷輪 rc=1 皆 captured_bytes=0，2026-10-26 再度實證），文字
        // 條件永遠不成立；真錯誤的文件重編也會失敗、診斷照樣回報。
        std::vector<const char *> retryArgs;
        for (const char *a : args)
            if (std::strcmp(a, "-parse-as-library") != 0)
                retryArgs.push_back(a);
        paxidxDebugNote("M4b top-level code: retrying without -parse-as-library");
        runFrontend(retryArgs);
    }
    if (result != 0) {
        copyDiag(captured.empty()
                     ? "paxidx swift: 編譯失敗（stderr 無輸出）"
                     : captured,
                 diagnostics, diagnostics_capacity);
        return 1;
    }
    copyDiag("", diagnostics, diagnostics_capacity);
    return 0;
}
#endif // PAXIDX_HAS_SWIFT_FRONTEND

// 手造替身目標文件（arm64 Mach-O relocatable，275 位元組）：僅定義
// __swift_FORCE_LOAD_$_swiftCompatibility56 一個 __data 全域符號（8 位元組零）。
// 由來與驗證見 paxidx_dylib_ld_link 內的連結註解。
static const unsigned char kCompat56StubObject[] = {
    0xcf, 0xfa, 0xed, 0xfe, 0x0c, 0x00, 0x00, 0x01, 0x00, 0x00, 0x00, 0x00, 0x01, 0x00, 0x00, 0x00,
    0x02, 0x00, 0x00, 0x00, 0xb0, 0x00, 0x00, 0x00, 0x00, 0x00, 0x00, 0x00, 0x00, 0x00, 0x00, 0x00,
    0x19, 0x00, 0x00, 0x00, 0x98, 0x00, 0x00, 0x00, 0x00, 0x00, 0x00, 0x00, 0x00, 0x00, 0x00, 0x00,
    0x00, 0x00, 0x00, 0x00, 0x00, 0x00, 0x00, 0x00, 0x00, 0x00, 0x00, 0x00, 0x00, 0x00, 0x00, 0x00,
    0x00, 0x00, 0x00, 0x00, 0x00, 0x00, 0x00, 0x00, 0xd0, 0x00, 0x00, 0x00, 0x00, 0x00, 0x00, 0x00,
    0x08, 0x00, 0x00, 0x00, 0x00, 0x00, 0x00, 0x00, 0x00, 0x00, 0x00, 0x00, 0x00, 0x00, 0x00, 0x00,
    0x01, 0x00, 0x00, 0x00, 0x00, 0x00, 0x00, 0x00, 0x5f, 0x5f, 0x64, 0x61, 0x74, 0x61, 0x00, 0x00,
    0x00, 0x00, 0x00, 0x00, 0x00, 0x00, 0x00, 0x00, 0x5f, 0x5f, 0x44, 0x41, 0x54, 0x41, 0x00, 0x00,
    0x00, 0x00, 0x00, 0x00, 0x00, 0x00, 0x00, 0x00, 0x00, 0x00, 0x00, 0x00, 0x00, 0x00, 0x00, 0x00,
    0x08, 0x00, 0x00, 0x00, 0x00, 0x00, 0x00, 0x00, 0xd0, 0x00, 0x00, 0x00, 0x03, 0x00, 0x00, 0x00,
    0x00, 0x00, 0x00, 0x00, 0x00, 0x00, 0x00, 0x00, 0x00, 0x00, 0x00, 0x00, 0x00, 0x00, 0x00, 0x00,
    0x00, 0x00, 0x00, 0x00, 0x00, 0x00, 0x00, 0x00, 0x02, 0x00, 0x00, 0x00, 0x18, 0x00, 0x00, 0x00,
    0xd8, 0x00, 0x00, 0x00, 0x01, 0x00, 0x00, 0x00, 0xe8, 0x00, 0x00, 0x00, 0x2b, 0x00, 0x00, 0x00,
    0x00, 0x00, 0x00, 0x00, 0x00, 0x00, 0x00, 0x00, 0x01, 0x00, 0x00, 0x00, 0x0f, 0x01, 0x00, 0x00,
    0x00, 0x00, 0x00, 0x00, 0x00, 0x00, 0x00, 0x00, 0x00, 0x5f, 0x5f, 0x73, 0x77, 0x69, 0x66, 0x74,
    0x5f, 0x46, 0x4f, 0x52, 0x43, 0x45, 0x5f, 0x4c, 0x4f, 0x41, 0x44, 0x5f, 0x24, 0x5f, 0x73, 0x77,
    0x69, 0x66, 0x74, 0x43, 0x6f, 0x6d, 0x70, 0x61, 0x74, 0x69, 0x62, 0x69, 0x6c, 0x69, 0x74, 0x79,
    0x35, 0x36, 0x00,
};

extern "C" int paxidx_dylib_ld_link(int argc, const char * const *argv,
                              char *diagnostics, size_t diagnostics_capacity) {
    const char *exe = argValue(argc, argv, "-o");
    const char *sdk = argValue(argc, argv, "-isysroot");
    if (!exe || !sdk) {
        copyDiag("paxidx ld: 缺參數（要 -o/-isysroot）", diagnostics, diagnostics_capacity);
        return 64;
    }
    std::vector<std::string> inputs;
    for (int i = 1; i < argc; i++) {
        size_t n = strlen(argv[i]);
        if (n > 2 && strcmp(argv[i] + n - 2, ".o") == 0)
            inputs.emplace_back(argv[i]);
    }
    if (inputs.empty()) {
        copyDiag("paxidx ld: 沒有輸入 .o", diagnostics, diagnostics_capacity);
        return 64;
    }

    std::string ver = sdkVersion(sdk, "15.0");
    std::vector<std::string> owned = {"ld64.lld", "-o", exe};
    for (auto &in : inputs) owned.push_back(in);
    owned.emplace_back("-arch");
    owned.emplace_back("arm64");
    owned.emplace_back("-platform_version");
    owned.emplace_back("ios");
    owned.emplace_back("15.0");
    owned.emplace_back(ver);
    owned.emplace_back("-syslibroot");
    owned.emplace_back(sdk);
    // 正規連結（2026-10-26 定案）：產出執行檔必須自帶函式庫依賴，不再用
    // -undefined dynamic_lookup。那種寫法一條 LC_LOAD_DYLIB 都不寫、全部
    // 符號記成 flat-namespace 運行時查找，dyld 啟動時身邊只有主程序自己，
    // 綁第一個符號就 abort（真機 Test.ipa＋.ips 實證：DYLD symbol not
    // found in flat namespace (_swift_bridgeObjectRelease)；拆 IPA 證實
    // 載入命令裡只有 /usr/lib/dyld 一條）。裸 ld64.lld 不會自動加
    // libSystem（那是 clang driver 的行為），須明寫 -lSystem／-lswiftCore
    // ——但不能靠 -lSystem／-lswiftCore 去讀 SDK 的 .tbd：2026-10-26 真機
    // 實證裝置端 lld 讀設備 SDK 的 .tbd 等於讀空（找得到文件、不報錯、
    // 但一個符號都不貢獻，連 _printf 都未定義；主機 ld-prime 讀同一批
    // .tbd 卻正常——是這支 lld 的 TextAPI 路徑與這批樁不合，舊註解裡
    // 「讀 .tbd 解析失敗」即此）。改成把系統裡的真 dylib 按絕對路徑
    // 直接當連結輸入：真 Mach-O 不經 TextAPI，其 LC_ID_DYLIB 本就是
    // /usr/lib/... 絕對名，記入產物的正是系統那份，無需 rpath。
    owned.emplace_back("/usr/lib/libSystem.B.dylib");
    owned.emplace_back("/usr/lib/swift/libswiftCore.dylib");
    // 以下三支是常用 autolink 目標的真身（存在才加）：並發運行時、
    // -Onone 支援、ObjC 運行時。它們在 SDK 裡只有 .tbd（同樣讀空），
    // 不給真身的話，將來用到 Task／@objc 的代碼會在這裡未定義。
    for (const char *sysLib : {"/usr/lib/swift/libswift_Concurrency.dylib",
                               "/usr/lib/swift/libswiftSwiftOnoneSupport.dylib",
                               "/usr/lib/libobjc.A.dylib"}) {
        if (FILE *f = fopen(sysLib, "rb")) {
            fclose(f);
            owned.emplace_back(sysLib);
        }
    }
    // libswiftCompatibility56 的佔位符號：6.2.4 標準庫令每個 Swift 目標
    // 文件引用 __swift_FORCE_LOAD_$_swiftCompatibility56（逼連結器拉入該
    // 庫的佔位變量，無人解引用），但設備端 SDK 沒有這支庫的 .tbd、iOS 15
    // 系統裡也沒有這支庫本體。隨連結附上一顆手造替身目標文件在本程序內
    // 定義該符號（kCompat56StubObject，275 位元組，僅一個 __data 零值
    // 全域；2026-10-26 CI E8/E10 以主機 ld 驗證可解析、可連結），連結
    // 不記該庫的載入命令，運行時自然不會去找它。
    {
        std::string stubPath = std::string(exe) + ".paxidx-compat56-stub.o";
        if (FILE *f = fopen(stubPath.c_str(), "wb")) {
            fwrite(kCompat56StubObject, 1, sizeof(kCompat56StubObject), f);
            fclose(f);
            owned.push_back(stubPath);
        }
    }

    std::vector<const char *> lldArgs;
    lldArgs.reserve(owned.size());
    for (auto &s : owned) lldArgs.push_back(s.c_str());

    std::string errText;
    llvm::raw_string_ostream errOS(errText);
    bool ok = lld::macho::link(
        llvm::ArrayRef<const char *>(lldArgs.data(), lldArgs.size()),
        llvm::outs(), errOS, /*exitEarly=*/false, /*disableOutput=*/false);
    errOS.flush();
    if (!ok) {
        copyDiag(errText.empty() ? "paxidx ld: 連結失敗" : errText,
                 diagnostics, diagnostics_capacity);
        return 1;
    }
    copyDiag("", diagnostics, diagnostics_capacity);
    return 0;
}
