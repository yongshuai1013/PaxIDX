import SwiftUI
import UniformTypeIdentifiers

/// 簽名證書頁（2026-10-30）：導入開發者證書（.p12）＋描述檔（.mobileprovision），
/// 以橋接的真簽名器（照 ZSign 作法：雙 CodeDirectory＋真 CMS）簽名產出。
/// 第一輪驗收：簽內嵌探針 dylib → 把簽好的檔分享給 Pax 離線驗 CMS。
struct CertSignView: View {
    @State private var statusText = "尚未載入"
    @State private var password = ""
    @State private var showP12Picker = false
    @State private var showProfilePicker = false
    @State private var signReport = ""
    @State private var signing = false
    @State private var showShare = false

    private var storeDir: URL {
        let base = FileManager.default.urls(for: .applicationSupportDirectory, in: .userDomainMask)[0]
        let dir = base.appendingPathComponent("PaxIDXSigning", isDirectory: true)
        try? FileManager.default.createDirectory(at: dir, withIntermediateDirectories: true)
        return dir
    }
    private var p12URL: URL { storeDir.appendingPathComponent("identity.p12") }
    private var profileURL: URL { storeDir.appendingPathComponent("profile.mobileprovision") }
    private var signedProbeURL: URL {
        let dir = FileManager.default.urls(for: .documentDirectory, in: .userDomainMask)[0]
            .appendingPathComponent("certsign", isDirectory: true)
        try? FileManager.default.createDirectory(at: dir, withIntermediateDirectories: true)
        return dir.appendingPathComponent("probe_signed.dylib")
    }

    var body: some View {
        List {
            Section(header: Text("目前身份")) {
                Text(statusText)
                    .font(.system(.caption, design: .monospaced))
                    .textSelection(.enabled)
                Button("重新載入") { reload() }
            }
            Section(header: Text("導入")) {
                SecureField("P12 密碼（EiliStore 導出的未加密，可留空）", text: $password)
                Button("導入證書（.p12）") { showP12Picker = true }
                Button("導入描述檔（.mobileprovision）") { showProfilePicker = true }
                Button("清除身份", role: .destructive) {
                    try? FileManager.default.removeItem(at: p12URL)
                    try? FileManager.default.removeItem(at: profileURL)
                    _ = paxidx_cert_clear()
                    statusText = "已清除"
                }
            }
            Section(header: Text("真簽名實測")) {
                if signing {
                    Text("簽名中…").font(.caption).foregroundColor(.secondary)
                } else {
                    Button("簽內嵌探針 dylib") { signProbe() }
                }
                Text("把 App 內嵌的 probe_ldid.dylib 用導入的證書真簽一份（雙 CD＋CMS），簽好的檔請用下方分享傳給 Pax 離線驗簽。")
                    .font(.caption)
                    .foregroundColor(.secondary)
                if !signReport.isEmpty {
                    Text(signReport)
                        .font(.system(.caption, design: .monospaced))
                        .textSelection(.enabled)
                    Button("分享簽好的 dylib") { showShare = true }
                }
            }
        }
        .navigationTitle("簽名證書")
        .onAppear { reload() }
        .sheet(isPresented: $showP12Picker) {
            DocPicker(types: [UTType(filenameExtension: "p12") ?? .data]) { url in
                importPicked(url, to: p12URL) { reload() }
            }
        }
        .sheet(isPresented: $showProfilePicker) {
            DocPicker(types: [UTType(filenameExtension: "mobileprovision") ?? .data]) { url in
                importPicked(url, to: profileURL) { reload() }
            }
        }
        .sheet(isPresented: $showShare) {
            CertShareSheet(items: [signedProbeURL])
        }
    }

    private func importPicked(_ url: URL, to dst: URL, done: @escaping () -> Void) {
        let scoped = url.startAccessingSecurityScopedResource()
        defer { if scoped { url.stopAccessingSecurityScopedResource() } }
        try? FileManager.default.removeItem(at: dst)
        do {
            try FileManager.default.copyItem(at: url, to: dst)
        } catch {
            statusText = "複製檔案失敗：\(error.localizedDescription)"
            return
        }
        done()
    }

    private func reload() {
        var messages: [String] = []
        if FileManager.default.fileExists(atPath: p12URL.path) {
            var buf = [CChar](repeating: 0, count: 4096)
            let rc = paxidx_cert_import_p12((p12URL.path as NSString).utf8String,
                                            (password as NSString).utf8String, &buf, buf.count)
            messages.append(rc == 0 ? String(cString: buf) : "P12 導入失敗：\(String(cString: buf))")
        }
        if FileManager.default.fileExists(atPath: profileURL.path) {
            var buf = [CChar](repeating: 0, count: 4096)
            let rc = paxidx_cert_import_profile((profileURL.path as NSString).utf8String, &buf, buf.count)
            messages.append(rc == 0 ? String(cString: buf) : "描述檔導入失敗：\(String(cString: buf))")
        }
        statusText = messages.isEmpty ? "尚未導入（先導出 EiliStore 的 .p12 再來這裡導入）" : messages.joined(separator: "\n---\n")
    }

    private func signProbe() {
        guard let src = Bundle.main.path(forResource: "probe_ldid", ofType: "dylib") else {
            signReport = "bundle 內找不到 probe_ldid.dylib"
            return
        }
        signing = true
        signReport = "執行中…"
        let dst = signedProbeURL
        DispatchQueue.global(qos: .userInitiated).async {
            var buf = [CChar](repeating: 0, count: 8192)
            let rc = paxidx_cert_sign_file((src as NSString).utf8String,
                                           (dst.path as NSString).utf8String,
                                           nil, &buf, buf.count)
            let text = String(cString: buf)
            DispatchQueue.main.async {
                signing = false
                signReport = "rc=\(rc)\n\(text)"
            }
        }
    }
}

struct DocPicker: UIViewControllerRepresentable {
    let types: [UTType]
    let onPick: (URL) -> Void
    func makeUIViewController(context: Context) -> UIDocumentPickerViewController {
        let vc = UIDocumentPickerViewController(forOpeningContentTypes: types)
        vc.delegate = context.coordinator
        vc.allowsMultipleSelection = false
        return vc
    }
    func updateUIViewController(_ vc: UIDocumentPickerViewController, context: Context) {}
    func makeCoordinator() -> Coordinator { Coordinator(onPick: onPick) }
    final class Coordinator: NSObject, UIDocumentPickerDelegate {
        let onPick: (URL) -> Void
        init(onPick: @escaping (URL) -> Void) { self.onPick = onPick }
        func documentPicker(_ controller: UIDocumentPickerViewController, didPickDocumentsAt urls: [URL]) {
            if let u = urls.first { onPick(u) }
        }
    }
}

struct CertShareSheet: UIViewControllerRepresentable {
    let items: [Any]
    func makeUIViewController(context: Context) -> UIActivityViewController {
        UIActivityViewController(activityItems: items, applicationActivities: nil)
    }
    func updateUIViewController(_ vc: UIActivityViewController, context: Context) {}
}
