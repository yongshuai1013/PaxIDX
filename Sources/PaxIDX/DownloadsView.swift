import SwiftUI

/// 下載管理頁（2026-10-26 永帥交代，Foundation 全線通過後落地）：
/// 把散在設定頁的下載件集中一頁管理——Darwin SDK、Swift 模塊（標準庫
/// ＋框架）、Clang 頭文件、系統函式庫（sysroot 主包＋框架附加包），
/// 每項各有狀態、下載／重新下載與進度。實際下載、疊加與驗證都走既有
/// 的 SDKManager／ToolchainManager，本頁不另寫下載邏輯。
struct DownloadsView: View {
    @State private var sdkInstalled = SDKManager.shared.isInstalled
    @State private var modulesOverlaid = ToolchainManager.shared.isSwiftModulesOverlaid
    @State private var clangOverlaid = ToolchainManager.shared.isClangHeadersOverlaid
    @State private var sysrootInstalled = ToolchainManager.shared.isSysrootInstalled

    @State private var sdkBusy = false
    @State private var sdkProgress = 0.0
    @State private var sdkMessage = ""
    @State private var modulesBusy = false
    @State private var modulesProgress = 0.0
    @State private var modulesMessage = ""
    @State private var clangBusy = false
    @State private var clangProgress = 0.0
    @State private var clangMessage = ""
    @State private var sysrootBusy = false
    @State private var sysrootProgress = 0.0
    @State private var sysrootMessage = ""

    var body: some View {
        List {
            Section(header: Text("Darwin SDK")) {
                statusRow(installed: sdkInstalled, doneText: "已安裝", todoText: "未安裝")
                progressRow(busy: sdkBusy, progress: sdkProgress)
                messageRow(sdkMessage)
                if !sdkBusy {
                    Button(sdkInstalled ? "重新下載 SDK（約 36MB）" : "下載 SDK（約 36MB）") {
                        downloadSDK()
                    }
                }
                Text("編譯用的 iOS SDK 本體（接口集）。從文件導入 SDK 的選項在設定頁。")
                    .font(.caption)
                    .foregroundColor(.secondary)
            }
            Section(header: Text("Swift 模塊（標準庫＋框架）")) {
                statusRow(installed: modulesOverlaid, doneText: "已疊加（6.2.4）", todoText: "未疊加")
                progressRow(busy: modulesBusy, progress: modulesProgress)
                messageRow(modulesMessage)
                if !modulesBusy {
                    Button(modulesOverlaid ? "重新疊加 Swift 模塊（約 9MB）" : "疊加 Swift 模塊（約 9MB）") {
                        overlayModules()
                    }
                }
                Text("工具鏈 6.2.4 的模塊二進制：標準庫整包＋Foundation／Dispatch 等 15 個框架模塊，疊加進 SDK（同目錄有接口時整目錄替換，免前端現場重建）。疊加時順手清掉 SDK 裡的 libxml 分身樹。")
                    .font(.caption)
                    .foregroundColor(.secondary)
            }
            Section(header: Text("Clang 頭文件")) {
                statusRow(installed: clangOverlaid, doneText: "已疊加", todoText: "未疊加")
                progressRow(busy: clangBusy, progress: clangProgress)
                messageRow(clangMessage)
                if !clangBusy {
                    Button(clangOverlaid ? "重新下載 Clang 頭文件（約 1MB）" : "下載 Clang 頭文件（約 1MB）") {
                        overlayClangHeaders()
                    }
                }
                Text("Clang 內建頭文件，裝到 usr/lib/clang/19.1.5，並鏡像一份到 usr/lib/swift/clang/（前端以 -resource-dir 指 SDK 時靠鏡像找內建模塊，缺了會靜默失敗）。")
                    .font(.caption)
                    .foregroundColor(.secondary)
            }
            Section(header: Text("系統函式庫（sysroot）")) {
                statusRow(installed: sysrootInstalled, doneText: "已安裝", todoText: "未安裝")
                progressRow(busy: sysrootBusy, progress: sysrootProgress)
                messageRow(sysrootMessage)
                if !sysrootBusy {
                    Button(sysrootInstalled ? "重新安裝系統函式庫（約 60MB）" : "安裝系統函式庫（約 60MB）") {
                        installSysroot()
                    }
                }
                Text("從 iOS 15.8.5 固件抽出的真 dylib 副本：主包（系統函式庫，約 36MB）＋框架附加包（Foundation／CoreFoundation 真身與 67 支 libswift 運行庫，約 24MB），裝進 SDK 的 paxidx-sysroot 供連結使用；安裝名仍是系統原名，運行時用裝置正版。")
                    .font(.caption)
                    .foregroundColor(.secondary)
            }
        }
        .navigationTitle("下載管理")
        .onAppear { refreshStatuses() }
    }

    @ViewBuilder
    private func statusRow(installed: Bool, doneText: String, todoText: String) -> some View {
        HStack {
            Text("狀態")
            Spacer()
            Text(installed ? doneText : todoText)
                .foregroundColor(installed ? .green : .orange)
        }
    }

    @ViewBuilder
    private func progressRow(busy: Bool, progress: Double) -> some View {
        if busy {
            HStack {
                ProgressView(value: progress)
                Text("\(Int(progress * 100))%")
                    .font(.caption)
                    .foregroundColor(.secondary)
                    .frame(width: 45, alignment: .trailing)
            }
        }
    }

    @ViewBuilder
    private func messageRow(_ message: String) -> some View {
        if !message.isEmpty {
            Text(message)
                .font(.caption)
                .foregroundColor(.secondary)
        }
    }

    private func refreshStatuses() {
        sdkInstalled = SDKManager.shared.isInstalled
        modulesOverlaid = ToolchainManager.shared.isSwiftModulesOverlaid
        clangOverlaid = ToolchainManager.shared.isClangHeadersOverlaid
        sysrootInstalled = ToolchainManager.shared.isSysrootInstalled
    }

    private func downloadSDK() {
        sdkBusy = true
        sdkMessage = "下載中…"
        SDKManager.shared.downloadLatest(
            onProgress: { p in
                DispatchQueue.main.async { sdkProgress = p }
            },
            completion: { result in
                DispatchQueue.main.async {
                    sdkBusy = false
                    refreshStatuses()
                    switch result {
                    case .success(let url):
                        sdkMessage = "已安裝到：\(url.lastPathComponent)"
                    case .failure(let error):
                        sdkMessage = "失敗：\(error.localizedDescription)"
                    }
                }
            }
        )
    }

    private func overlayModules() {
        modulesBusy = true
        modulesMessage = "下載 Swift 模塊中…"
        ToolchainManager.shared.downloadSwiftModules(
            onProgress: { p in
                DispatchQueue.main.async { modulesProgress = p }
            },
            completion: { result in
                DispatchQueue.main.async {
                    modulesBusy = false
                    refreshStatuses()
                    switch result {
                    case .success:
                        modulesMessage = modulesOverlaid ? "Swift 模塊疊加完成" : "疊加完成但驗證未過，請回報"
                    case .failure(let error):
                        modulesMessage = "疊加失敗：\(error.localizedDescription)"
                    }
                }
            }
        )
    }

    private func overlayClangHeaders() {
        clangBusy = true
        clangMessage = "下載 Clang 頭文件中…"
        ToolchainManager.shared.downloadClangHeaders(
            onProgress: { p in
                DispatchQueue.main.async { clangProgress = p }
            },
            completion: { result in
                DispatchQueue.main.async {
                    clangBusy = false
                    refreshStatuses()
                    switch result {
                    case .success:
                        clangMessage = clangOverlaid ? "Clang 頭文件疊加完成" : "疊加完成但驗證未過，請回報"
                    case .failure(let error):
                        clangMessage = "Clang 頭文件失敗：\(error.localizedDescription)"
                    }
                }
            }
        )
    }

    private func installSysroot() {
        sysrootBusy = true
        sysrootMessage = "下載系統函式庫中（主包＋框架附加包）…"
        ToolchainManager.shared.downloadSysroot(
            onProgress: { p in
                DispatchQueue.main.async { sysrootProgress = p }
            },
            completion: { result in
                DispatchQueue.main.async {
                    sysrootBusy = false
                    refreshStatuses()
                    switch result {
                    case .success:
                        sysrootMessage = sysrootInstalled ? "系統函式庫安裝完成" : "安裝完成但驗證未過，請回報"
                    case .failure(let error):
                        sysrootMessage = "系統函式庫安裝失敗：\(error.localizedDescription)"
                    }
                }
            }
        )
    }
}
