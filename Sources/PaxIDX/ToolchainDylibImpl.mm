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
// 注意：不調 initializeSwiftModules()——該符號在只編 swiftFrontendTool 時不存在，
// 且 Swift 官方說 swift-frontend 不嚴格要求它
#ifdef PAXIDX_HAS_SWIFT_FRONTEND
namespace swift {
class FrontendObserver;
int performFrontend(llvm::ArrayRef<const char *> Args, const char *Argv0,
                    void *Context, FrontendObserver *observer);
} // namespace swift

extern "C" int paxidx_dylib_swift_compile(int argc, const char * const *argv,
                                    char *diagnostics, size_t diagnostics_capacity) {
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
    {
        std::string clangResourceDir = std::string(sdk) + "/usr/lib/clang/19.1.5";
        std::string probe = clangResourceDir + "/include/stdarg.h";
        FILE *f = fopen(probe.c_str(), "r");
        if (f) {
            fclose(f);
            owned.push_back("-Xcc");
            owned.push_back("-resource-dir");
            owned.push_back("-Xcc");
            owned.push_back(clangResourceDir);
        }
        // 不存在就不傳，退回默認行為（至少 pure Swift 能用）
    }
    owned.push_back("-emit-object");
    owned.push_back("-o"); owned.push_back(output);
    owned.push_back(src);
    std::vector<const char *> args;
    args.reserve(owned.size());
    for (auto &s : owned) args.push_back(s.c_str());

    int result = swift::performFrontend(
        llvm::ArrayRef<const char *>(args.data(), args.size()),
        "swift-frontend", nullptr, nullptr);
    if (result != 0) {
        copyDiag("paxidx swift: 編譯失敗（rc=1，無診斷）",
                 diagnostics, diagnostics_capacity);
        return 1;
    }
    copyDiag("", diagnostics, diagnostics_capacity);
    return 0;
}
#endif // PAXIDX_HAS_SWIFT_FRONTEND

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
    // 不自動鏈系統庫：LLD 看到 platform_version 會自動找 libSystem.tbd，但解析不了
    owned.emplace_back("-nostdlib");
    // 不加 -lSystem：SDK 的 .tbd LLD 解析不了；
    // 已有 -undefined dynamic_lookup，未定義符號運行時由 iOS 的 libSystem 提供
    // SDK 的 .tbd 可能不全（如 ___darwin_fd_set），允許未定義符號，運行時由 iOS 的 libSystem 提供
    owned.emplace_back("-undefined");
    owned.emplace_back("dynamic_lookup");

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
