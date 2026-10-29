import SwiftUI
import Zip

/// Nyxian CoreCompiler 載入實測頁（實驗，2026-10-26）：
/// 離線體檢顯示 Nyxian 的 CoreCompiler（minos 16.0）在符號層與
/// iOS 15.8.5 完全相容、強綁定缺失為零；nyx_test 實驗包會把改戳記
/// （minos 改 15.0）後的 CoreCompiler.framework 塞進 App 的
/// Frameworks/，本頁按鈕實際 dlopen 它，驗證 dyld 在 iOS 15 上
/// 真的肯載入並完成初始化。一般包沒有內嵌，頁面會直接說明。
struct NyxLoadTestView: View {
    @State private var report = "尚未執行"
    @State private var running = false
    @State private var compileReport = "尚未執行"
    @State private var compiling = false
    @State private var progressText = ""

    var body: some View {
        List {
            Section {
                if !running {
                    Button("載入 CoreCompiler 實測") {
                        runTest()
                    }
                } else {
                    Text("載入中…（185MB，首次會慢）")
                        .font(.caption)
                        .foregroundColor(.secondary)
                }
                Text("只做 dlopen＋讀版本符號，不呼叫編譯功能。成功＝改戳記後 dyld 接受、且全體初始化在 iOS 15 上跑完；失敗會顯示 dyld 的原文錯誤。")
                    .font(.caption)
                    .foregroundColor(.secondary)
            }
            Section(header: Text("結果")) {
                Text(report)
                    .font(.system(.caption, design: .monospaced))
                    .textSelection(.enabled)
            }
            Section {
                if !compiling {
                    Button("用 CoreCompiler 試編一個 C 檔") {
                        runCompile()
                    }
                } else {
                    Text("編譯中…")
                        .font(.caption)
                        .foregroundColor(.secondary)
                }
                Text("走 CoreCompiler 直打 CCJob（介面照 Nyxian 開源源碼）：A–F 段驗 C／ObjC／連結；G 段把產出的 dylib 真 dlopen 呼叫驗返回值；S 段是關鍵票——用他們的 Swift 前端（6.3.3）編一個 import Foundation 的 Swift 檔，自家線從未編成過這一級別。")
                    .font(.caption)
                    .foregroundColor(.secondary)
            }
            Section(header: Text("上次試編進度（閃退定位用）")) {
                Text(progressText.isEmpty ? "（無記錄）" : progressText)
                    .font(.system(.caption, design: .monospaced))
                    .textSelection(.enabled)
                Button("重新讀取進度") { loadProgress() }
            }
            Section(header: Text("試編結果")) {
                Text(compileReport)
                    .font(.system(.caption, design: .monospaced))
                    .textSelection(.enabled)
            }
        }
        .navigationTitle("Nyxian 載入實測")
        .onAppear { loadProgress() }
    }

    private func loadProgress() {
        var buf = [CChar](repeating: 0, count: 8192)
        _ = paxidx_nyx_progress(&buf, buf.count)
        progressText = String(cString: buf)
    }

    private func runCompile() {
        compiling = true
        compileReport = "執行中…"
        // 用大棧的專用線程跑，順便排除 GCD 工作線程棧太小（512KB）壓垮 LLVM 的可能
        let thread = Thread {
            Self.bootstrapPaxSDK()
            var buf = [CChar](repeating: 0, count: 32768)
            let rc = paxidx_nyx_compile_test(&buf, buf.count)
            let text = String(cString: buf)
            DispatchQueue.main.async {
                compiling = false
                compileReport = "rc=\(rc)\n\(text)"
                loadProgress()
            }
        }
        thread.stackSize = 32 * 1024 * 1024
        thread.start()
    }


    /// 他們的打包法：App 自帶 PaxSDK.zip（完整乾淨 SDK＋BSROOT res），
    /// 首次試編前解壓到 Documents/PaxSDK 固定根，橋接 S10 直指該根。
    private static func bootstrapPaxSDK() {
        guard let zip = Bundle.main.url(forResource: "PaxSDK", withExtension: "zip") else { return }
        let fm = FileManager.default
        let dest = fm.urls(for: .documentDirectory, in: .userDomainMask)[0]
            .appendingPathComponent("PaxSDK")
        let sentinel = dest.appendingPathComponent(
            "iPhoneOS.sdk/usr/lib/swift/Swift.swiftmodule/arm64-apple-ios.swiftinterface")
        if fm.fileExists(atPath: sentinel.path) { return }
        try? fm.createDirectory(at: dest, withIntermediateDirectories: true)
        try? Zip.unzipFile(zip, destination: dest, overwrite: true, password: nil)
    }

    private func runTest() {
        running = true
        report = "執行中…"
        DispatchQueue.global(qos: .userInitiated).async {
            var buf = [CChar](repeating: 0, count: 16384)
            let rc = paxidx_nyx_dlopen_test(&buf, buf.count)
            let text = String(cString: buf)
            DispatchQueue.main.async {
                running = false
                report = "rc=\(rc)\n\(text)"
            }
        }
    }
}
