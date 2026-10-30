#ifndef NativeToolchainBridge_h
#define NativeToolchainBridge_h

#include <stddef.h>

#ifdef __cplusplus
extern "C" {
#endif

/// 工具鏈是否已載入（1=可用，0=不可用）
int paxidx_toolchain_available(void);

/// Swift 工具鏈是否已載入（1=可用，0=不可用）
int paxidx_swift_toolchain_available(void);

/// Swift 編譯是否可用（任一 dylib 含 Swift 前端即為 1）
int paxidx_swift_available(void);

/// 取最後一次載入失敗的原因（dlopen 錯誤文字），0=成功寫入
int paxidx_toolchain_error(char *buffer, size_t capacity);

/// 編譯單個源文件到 .o，0=成功
/// argv 形如：["clang", "-target", <triple>, "-isysroot", <sdk>, "-c", <src>, "-o", <obj>]
/// diagnostics 收編譯器診斷文字（可為 NULL）
int paxidx_clang_compile(int argc, const char * const *argv,
                         char *diagnostics, size_t diagnostics_capacity);

/// 連結 .o 到 Mach-O 可執行文件，0=成功
/// argv 形如：["ld", "-o", <exe>, <obj>..., "-target", <triple>, "-isysroot", <sdk>]
int paxidx_ld_link(int argc, const char * const *argv,
                   char *diagnostics, size_t diagnostics_capacity);

/// 通用 CCJob 執行（整合正式編譯路）：type 0=Clang 前端、2=Swift 前端、
/// 4=連結器；argv 是完整參數（不含程式名），report 收診斷與 stderr 摘要；
/// 0=成功、1=失敗、2=未內嵌
int paxidx_cc_job(int type, int argc, const char * const *argv,
                  char *report, size_t capacity);

/// clang driver 組裝路（Nyxian 同款）：driver 旗標（不含程式名，框架自行
/// 補 "clang" 與 "-fuse-ld=lld"）交 CCDriver 展開成 CCJob 逐個執行，
/// .o 經 output callback 導向 buildDir；0=成功、1=失敗、2=未內嵌
int paxidx_cc_driver(const char *buildDir, int argc, const char * const *argv,
                     char *report, size_t capacity);

/// Nyxian CoreCompiler 載入實測（實驗）：dlopen App 內嵌的
/// CoreCompiler.framework 並讀其版本符號，報告寫入 buffer；
/// 0=載入成功、1=載入失敗、2=未內嵌
int paxidx_nyx_dlopen_test(char *buffer, size_t capacity);

/// Nyxian CoreCompiler 試編（實驗）：用 CoreCompiler 的 CCDriver C API
/// 把一個內建範例 C 檔編成 .o，報告寫入 buffer；0=編出產物、1=失敗、2=未內嵌
int paxidx_nyx_compile_test(char *buffer, size_t capacity);

/// 讀上次試編的步驟進度檔（崩潰定位用），0=成功寫入
int paxidx_nyx_progress(char *buffer, size_t capacity);

/// 編譯 Swift 源文件到 .o，0=成功（僅 Swift 版 dylib 有）
/// argv 形如：["swiftc", "-target", <triple>, "-sdk", <sdk>, "-o", <obj>, <src.swift>]
/// diagnostics 收編譯器診斷文字（可為 NULL）
int paxidx_swift_compile(int argc, const char * const *argv,
                         char *diagnostics, size_t diagnostics_capacity);

/// 導入簽名證書（未加密 .p12，EiliStore/CodeSignKit 導出格式）：解析證書+私鑰並核對相符；
/// info 回證書摘要；0=成功
int paxidx_cert_import_p12(const char *p12Path, const char *password, char *info, size_t cap);

/// 導入描述檔（.mobileprovision）：info 回摘要；0=成功
int paxidx_cert_import_profile(const char *profilePath, char *info, size_t cap);

/// 目前身份摘要（未導入回空字串、傳回 1）
int paxidx_cert_status(char *info, size_t cap);

/// 清除已導入身份
int paxidx_cert_clear(void);

/// 以導入身份真簽名單一 Mach-O（照 ZSign：雙 CodeDirectory + 真 CMS）；
/// identOrNull 為 NULL 時 dylib 用 LC_ID_DYLIB；主程式自動掛 entitlements
/// （有描述檔用描述檔改寫 app id，否則最小集）；report 回簽名摘要；0=成功
int paxidx_cert_sign_file(const char *srcPath, const char *dstPath, const char *identOrNull,
                          char *report, size_t cap);

#ifdef __cplusplus
}
#endif

#endif /* NativeToolchainBridge_h */
