// PaxIDX 工具鏈橋接（App 端）：dlopen 載入 dylib 轉發
// 啟動時不載入 LLVM，點編譯時才 dlopen Documents/Toolchain/ 下的 dylib
// dylib 由 ToolchainManager 從 release 下載
#include "NativeToolchainBridge.h"

#include <Foundation/Foundation.h>
#include <dlfcn.h>
#include <dispatch/dispatch.h>
#include <string>
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
        copyDiag(report, buffer, capacity);
        return 2;
    }
    line("目標：" + std::string(fwPath.UTF8String));
    dlerror();
    void *h = dlopen(fwPath.UTF8String, RTLD_NOW | RTLD_GLOBAL);
    if (!h) {
        const char *e = dlerror();
        line(std::string("dlopen 失敗：") + (e ? e : "(無錯誤文字)"));
        copyDiag(report, buffer, capacity);
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
    copyDiag(report, buffer, capacity);
    return 0;
}
