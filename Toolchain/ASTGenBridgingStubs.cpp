//===--- ASTGenBridgingStubs.cpp ------------------------------------------===//
//
// PaxIDX 裝置端工具鏈專用：swiftASTGen / swiftMacroEvaluation 兩個庫的
// C 橋接入口實作。
//
// 為什麼需要這個檔案：
//   前端裡 Swift 寫的庫只有三個（同一個 SwiftPM 套件 ASTGen 的三個
//   模塊）：libswiftASTGen.a、libswiftMacroEvaluation.a、
//   libswiftIDEUtilsBridging.a。它們都直接或間接引用 _CompilerSwift*
//   符號（swift-syntax 的「編譯器支援庫」：_CompilerSwiftSyntax、
//   _CompilerSwiftParser、_CompilerSwiftIDEUtils、…）。那些庫在官方
//   構建裡只產 macOS host 版，從沒為 iPhoneOS arm64 編過——run #27／
//   #28 的 dylib 連結死在前兩個庫、#29 死在第三個。所以 Stage 合併
//   大庫時三個都排除，由本檔案提供它們對 C++ 前端的全部 C 入口
//   （簽名照 swift/Bridging/ASTGen.h 與 swift/Bridging/MacroEvaluation.h；
//   IDEUtils 的入口照其 Swift 源碼的 @_cdecl 簽名）。
//
// 裝置端的行為邊界（誠實申報，不是假裝支援）：
//   * 宏（macros）：不支援。expand* 入口一律回「沒有產出」，呼叫方
//     （TypeCheckMacros）會走它自己的失敗路徑發出診斷；checkMacroDefinition
//     回 -1（呼叫方定義即「無效的宏定義」）。宏插件本來就要獨立進程執行，
//     裝置端跑不了——這是已知限制，不是本檔案的取捨。
//   * ASTGen 解析路徑（swift_ASTGen_parseSourceFile 一組）：只在
//     Feature::ParserASTGen 開啟時才會被呼叫，預設編譯不走；樁回空／失敗，
//     萬一被呼叫到也是響亮地失敗，不會靜默產出錯誤的 AST。
//   * 正規表示式字面量（regex literals）：lex/parse 入口回 false，
//     用到 regex 字面量的代碼會在型別檢查階段報錯；一般代碼不受影響。
//   * #if 條件評估：不在這裡處理。swift fork（paxidx-ios15）的
//     ParseIfConfig 補丁讓 evaluateWithSwiftIfConfig 回「不可用」，
//     解析器改走上游原生 C++ 評估器（與 C++-only 構建相同），語義完整。
//     本檔案的 swift_ASTGen_evaluatePoundIfCondition 因此永遠不會被呼叫，
//     只為滿足連結而存在。
//   * extractInlinableText：真 ASTGen 版回「去掉註釋的原文」；本實作回
//     原文（含註釋）。註釋在語義上是空白，@inlinable 函數的接口文本帶
//     註釋不影響消費端編譯——這是刻意接受的唯一語義差異。
//   * bridgedSwiftClosureCall_1：照 Swift 版逐字轉寫的真 trampoline
//     （載入 closure 指向的函數指標並呼叫），不是樁。
//   * 其餘（診斷佇列、指紋、configured regions、inactive code 掃描、
//     unqualified lookup 驗證）：都是 IDE／診斷輔助或被實驗 feature
//     守著的路徑；樁回空結果／中性值，批次編譯不依賴它們產出代碼。
//
//===----------------------------------------------------------------------===//

#include <cstddef>
#include <cstdint>
#include <cstring>
#include <sys/types.h>

#include "swift/Bridging/ASTGen.h"
#include "swift/Bridging/MacroEvaluation.h"

namespace {

// 不透明控制代碼（queued diagnostics / per-frontend diagnostic state）用
// 的假句柄：呼叫方只把它原樣傳回配對的 destroy/render 函數，從不解引用；
// 本檔案的配對函數也從不解引用。給一個真實存在的地址而不是 nullptr，
// 因為標頭把回傳標了 _Nonnull，呼叫方可能拿它跟 nullptr 比較來判斷
// 「建立成功」。
char gDummyHandleStorage;
void *dummyHandle() { return &gDummyHandleStorage; }

void zeroOut(void *ptr, size_t size) { std::memset(ptr, 0, size); }

} // namespace

//===----------------------------------------------------------------------===//
// 只在呼叫方 .cpp 裡本地宣告、沒有進 Bridging 標頭的入口。
//===----------------------------------------------------------------------===//

#pragma clang diagnostic push
#pragma clang diagnostic ignored "-Wreturn-type-c-linkage"
extern "C" {

// TypeChecker.cpp 本地宣告。ParseIfConfig 補丁後無人呼叫（見檔頭）。
intptr_t swift_ASTGen_evaluatePoundIfCondition(BridgedASTContext,
                                               void *_Nonnull,
                                               BridgedStringRef,
                                               BridgedStringRef, bool);

// MiscDiagnostics.cpp 本地宣告；上游 C++-only 構建的對應行為就是回 false
// （「在 inactive 代碼裡沒找到引用」→ 不發那條建議收窄用途的警告）。
bool swift_ASTGen_inactiveCodeContainsReference(BridgedASTContext,
                                                BridgedStringRef,
                                                BridgedStringRef,
                                                BridgedStringRef, void **);
bool swift_ASTGen_inactiveCodeContainsTryOrThrow(BridgedASTContext,
                                                 BridgedStringRef,
                                                 BridgedStringRef);
void swift_ASTGen_freeInactiveCodeContainsReferenceCache(void *);

// InlinableText.cpp 本地宣告。
BridgedStringRef swift_ASTGen_extractInlinableText(BridgedASTContext,
                                                   BridgedStringRef);

} // extern "C"
#pragma clang diagnostic pop

//===----------------------------------------------------------------------===//
// swift/Bridging/ASTGen.h —— 診斷佇列與渲染
//===----------------------------------------------------------------------===//

void *swift_ASTGen_createQueuedDiagnostics() { return dummyHandle(); }

void swift_ASTGen_destroyQueuedDiagnostics(void *) {}

void swift_ASTGen_addQueuedSourceFile(void *, ssize_t, void *,
                                      const uint8_t *, intptr_t, ssize_t,
                                      ssize_t) {}

void swift_ASTGen_addQueuedDiagnostic(
    void *, void *, BridgedStringRef, BridgedDiagnosticSeverity,
    BridgedSourceLoc, BridgedStringRef, BridgedStringRef,
    const BridgedCharSourceRange *, ptrdiff_t, BridgedArrayRef) {}

void swift_ASTGen_renderSingleDiagnostic(void *, BridgedStringRef,
                                         BridgedDiagnosticSeverity,
                                         BridgedStringRef, BridgedStringRef,
                                         ssize_t,
                                         BridgedStringRef *renderedString) {
  *renderedString = BridgedStringRef();
}

void swift_ASTGen_renderQueuedDiagnostics(void *, ssize_t, ssize_t,
                                          BridgedStringRef *renderedString) {
  *renderedString = BridgedStringRef();
}

void *swift_ASTGen_createPerFrontendDiagnosticState() {
  return dummyHandle();
}

void swift_ASTGen_destroyPerFrontendDiagnosticState(void *) {}

void swift_ASTGen_renderCategoryFootnotes(void *, ssize_t,
                                          BridgedStringRef *renderedString) {
  *renderedString = BridgedStringRef();
}

//===----------------------------------------------------------------------===//
// swift/Bridging/ASTGen.h —— ASTGen 解析路徑（ParserASTGen feature 專用）
//===----------------------------------------------------------------------===//

void *swift_ASTGen_parseSourceFile(BridgedStringRef, BridgedStringRef,
                                   BridgedStringRef, void *,
                                   BridgedGeneratedSourceFileKind) {
  return nullptr;
}

void swift_ASTGen_destroySourceFile(void *) {}

// 標頭契約：0 = round-trip 成功，非 0 = 失敗。我們沒解析過任何東西，
// 誠實回失敗。
int swift_ASTGen_roundTripCheck(void *) { return 1; }

// 標頭契約：非 0 = 有發出診斷。我們一條都沒發，回 0。
int swift_ASTGen_emitParserDiagnostics(BridgedASTContext, void *, void *,
                                       int, int) {
  return 0;
}

void swift_ASTGen_buildTopLevelASTNodes(BridgedDiagnosticEngine, void *,
                                         BridgedDeclContext, BridgedNullableDecl,
                                         BridgedASTContext, void *,
                                         void (*)(BridgedASTNode, void *)) {}

BridgedFingerprint swift_ASTGen_getSourceFileFingerprint(void *,
                                                         BridgedASTContext) {
  BridgedFingerprint result;
  zeroOut(&result, sizeof(result));
  return result;
}

// 我們的入口從不分配 BridgedString（render* 回空字串、extractInlinableText
// 借用呼叫方的緩衝區），所以釋放永遠是 no-op；呼叫方拿到的字串要嘛是空的、
// 要嘛指向它自己擁有的 SourceManager 緩衝區。
void swift_ASTGen_freeBridgedString(BridgedStringRef) {}

//===----------------------------------------------------------------------===//
// swift/Bridging/ASTGen.h —— 正規表示式字面量
//===----------------------------------------------------------------------===//

// 回 false = 「這不是 regex 字面量／解析失敗」；型別檢查會對真的 regex
// 字面量報錯（誠實失敗），一般代碼不會呼叫到這裡。
bool swift_ASTGen_lexRegexLiteral(const char **, const char *, bool,
                                  BridgedNullableDiagnosticEngine) {
  return false;
}

bool swift_ASTGen_parseRegexLiteral(BridgedStringRef, size_t *versionOut,
                                    void *, size_t,
                                    BridgedRegexLiteralPatternFeatures *featuresOut,
                                    BridgedSourceLoc, BridgedDiagnosticEngine) {
  *versionOut = 0;
  zeroOut(featuresOut, sizeof(BridgedRegexLiteralPatternFeatures));
  return false;
}

void swift_ASTGen_freeBridgedRegexLiteralPatternFeatures(
    BridgedRegexLiteralPatternFeatures) {}

void swift_ASTGen_getSwiftVersionForRegexPatternFeature(
    BridgedRegexLiteralPatternFeatureKind, BridgedSwiftVersion *versionOut) {
  zeroOut(versionOut, sizeof(BridgedSwiftVersion));
}

void swift_ASTGen_getDescriptionForRegexPatternFeature(
    BridgedRegexLiteralPatternFeatureKind, BridgedASTContext,
    BridgedStringRef *descriptionOut) {
  *descriptionOut = BridgedStringRef();
}

//===----------------------------------------------------------------------===//
// swift/Bridging/ASTGen.h —— #if 區域、lookup 驗證、虛擬檔案、可用性宏
//===----------------------------------------------------------------------===//

intptr_t swift_ASTGen_configuredRegions(
    BridgedASTContext, void *,
    BridgedIfConfigClauseRangeInfo *_Nullable *regionsOut) {
  *regionsOut = nullptr;
  return 0;
}

void swift_ASTGen_freeConfiguredRegions(BridgedIfConfigClauseRangeInfo *,
                                         intptr_t) {}

// 只在 Feature::UnqualifiedLookupValidation（實驗 feature）開啟時呼叫；
// C++ 查找本身照常進行，這裡只是交叉驗證。回 true = 驗證通過（不額外
// 發 lookup_outputs_dont_match 診斷）。
bool swift_ASTGen_validateUnqualifiedLookup(void *, BridgedASTContext,
                                            BridgedSourceLoc, bool,
                                            BridgedArrayRef) {
  return true;
}

size_t swift_ASTGen_virtualFiles(void *,
                                 BridgedVirtualFile *_Nullable *virtualFiles) {
  *virtualFiles = nullptr;
  return 0;
}

void swift_ASTGen_freeBridgedVirtualFiles(BridgedVirtualFile *, size_t) {}

// 回 true = hadError（ParseRequests.cpp 呼叫方的變量名就是 hadError）；
// 本來就被 ParserASTGen feature 守著，批次編譯不會走到。
bool swift_ASTGen_parseAvailabilityMacroDefinition(
    BridgedASTContext, BridgedDeclContext, BridgedDiagnosticEngine,
    BridgedStringRef, BridgedAvailabilityMacroDefinition *outPtr) {
  zeroOut(outPtr, sizeof(BridgedAvailabilityMacroDefinition));
  return true;
}

void swift_ASTGen_freeAvailabilityMacroDefinition(
    BridgedAvailabilityMacroDefinition *) {}

//===----------------------------------------------------------------------===//
// 本地宣告的入口
//===----------------------------------------------------------------------===//

// 永遠不會被呼叫（#if 走 fork 補丁的原生 C++ 評估）；回 0 只為滿足連結。
intptr_t swift_ASTGen_evaluatePoundIfCondition(BridgedASTContext, void *,
                                               BridgedStringRef,
                                               BridgedStringRef, bool) {
  return 0;
}

bool swift_ASTGen_inactiveCodeContainsReference(BridgedASTContext,
                                                BridgedStringRef,
                                                BridgedStringRef,
                                                BridgedStringRef,
                                                void **cache) {
  if (cache)
    *cache = nullptr;
  return false;
}

bool swift_ASTGen_inactiveCodeContainsTryOrThrow(BridgedASTContext,
                                                 BridgedStringRef,
                                                 BridgedStringRef) {
  return false;
}

void swift_ASTGen_freeInactiveCodeContainsReferenceCache(void *) {}

// 借用呼叫方的字串直接回傳（見檔頭的語義差異說明）；配對的
// swift_ASTGen_freeBridgedString 是 no-op，不會誤放 SourceManager 的
// 緩衝區。
BridgedStringRef swift_ASTGen_extractInlinableText(BridgedASTContext,
                                                   BridgedStringRef sourceText) {
  return sourceText;
}

//===----------------------------------------------------------------------===//
// swift/Bridging/MacroEvaluation.h —— 宏（裝置端不支援，誠實失敗）
//===----------------------------------------------------------------------===//

// 回 nullptr：呼叫方會把宏視為找不到／無法解析並發出診斷。
void *swift_Macros_resolveExternalMacro(const char *, const char *, void *) {
  return nullptr;
}

void swift_Macros_destroyExternalMacro(void *) {}

// 回 false：預設參數裡的宏表達式檢查不通過 → 呼叫方診斷。
bool swift_Macros_checkDefaultArgumentMacroExpression(void *, void *,
                                                      const void *) {
  return false;
}

// 回 -1：呼叫方（TypeCheckMacros）定義 checkResult < 0 即「無效的宏
// 定義」，會回 MacroDefinition::forInvalid() 並發出診斷。出參全部清零，
// 呼叫方 SWIFT_DEFER 裡的 free* 都是本檔案的 no-op，安全。
ptrdiff_t swift_Macros_checkMacroDefinition(
    void *, BridgedStringRef, BridgedStringRef,
    BridgedStringRef *expansionSourceOutPtr,
    ptrdiff_t *_Nullable *replacementsPtr, ptrdiff_t *numReplacements,
    ptrdiff_t *_Nullable *genericReplacementsPtr,
    ptrdiff_t *numGenericReplacements) {
  *expansionSourceOutPtr = BridgedStringRef();
  *replacementsPtr = nullptr;
  *numReplacements = 0;
  *genericReplacementsPtr = nullptr;
  *numGenericReplacements = 0;
  return -1;
}

void swift_Macros_freeExpansionReplacements(ptrdiff_t *, ptrdiff_t) {}

// 呼叫方只看 evaluatedSourceOut 的 data 是否為 nullptr 判斷成敗；回空
// 字串 = 展開失敗，呼叫方回 nullptr 並走它自己的診斷路徑。
ptrdiff_t swift_Macros_expandFreestandingMacro(
    void *, const void *, const char *, uint8_t, void *, const void *,
    BridgedStringRef *evaluatedSourceOut) {
  *evaluatedSourceOut = BridgedStringRef();
  return 0;
}

ptrdiff_t swift_Macros_expandAttachedMacro(
    void *, const void *, const char *, const char *, const char *, uint8_t,
    void *, const void *, void *, const void *, void *, const void *,
    BridgedStringRef *evaluatedSourceOut) {
  *evaluatedSourceOut = BridgedStringRef();
  return 0;
}

// 回 false：插件載入失敗，呼叫方發出診斷。裝置端本來就沒有宏插件進程。
bool swift_Macros_initializePlugin(void *, void *) { return false; }

void swift_Macros_deinitializePlugin(void *) {}

bool swift_Macros_pluginServerLoadLibraryPlugin(void *, const char *,
                                                const char *,
                                                BridgedStringRef *errorOut) {
  if (errorOut)
    *errorOut = BridgedStringRef();
  return false;
}

//===----------------------------------------------------------------------===//
// SwiftIDEUtilsBridging —— IDE 名稱匹配（批次編譯不用，run #30 補）
//===----------------------------------------------------------------------===//

// lib/ASTGen/Sources/SwiftIDEUtilsBridging 的唯一入口：替 IDE 的改名／
// 找引用功能把宣告位置解析成名稱位置。批次編譯（performFrontend）不
// 呼叫；回 nullptr = 沒有解析結果，是呼叫方能正常處理的答案。這個庫
// 的 object 同時引用 swiftASTGen 的 ExportedSourceFile 與
// _CompilerSwiftIDEUtils，所以跟前兩個庫一樣排除＋樁。
void *swift_SwiftIDEUtilsBridging_runNameMatcher(const void *,
                                                 const BridgedSourceLoc *,
                                                 size_t) {
  return nullptr;
}

//===----------------------------------------------------------------------===//
// 真 trampoline（照 lib/ASTGen/Sources/ASTGen/Bridge.swift 逐字轉寫）：
// closure 指向「函數指標的存放處」，載入後以 arg 呼叫。
//===----------------------------------------------------------------------===//

extern "C" void swift_ASTGen_bridgedSwiftClosureCall_1(
    const void *_Nonnull closure, const void *_Nullable arg) {
  using Fn = void (*)(const void *);
  Fn fn = *reinterpret_cast<Fn const *>(closure);
  fn(arg);
}
