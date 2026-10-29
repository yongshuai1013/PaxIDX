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

#ifdef __cplusplus
}
#endif

#endif /* NativeToolchainBridge_h */
