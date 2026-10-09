import SwiftUI

/// 專案詳情：文件列表＋編輯器＋編譯入口（支持刪除/重命名/複製/貼上）
struct ProjectDetailView: View {
    let project: Project
    @State private var files: [String] = []
    @State private var selectedFile: String?
    @State private var showEditor = false
    @State private var showBuild = false
    @State private var message = ""
    @StateObject private var clipboard = FileClipboard.shared
    @State private var showRenameAlert = false
    @State private var renameTarget = ""
    @State private var newName = ""
    @State private var actionSheetFile: String?
    @State private var showActionSheet = false

    var body: some View {
        List {
            Section(header: Text("源文件")) {
                ForEach(files, id: \.self) { file in
                    HStack {
                        Button(action: { openFile(file) }) {
                            Text(file)
                                .foregroundColor(.primary)
                        }
                        .buttonStyle(PlainButtonStyle())
                        Spacer()
                        Button(action: {
                            actionSheetFile = file
                            showActionSheet = true
                        }) {
                            Image(systemName: "ellipsis.circle")
                                .foregroundColor(.secondary)
                        }
                        .buttonStyle(PlainButtonStyle())
                    }
                    .swipeActions(edge: .trailing, allowsFullSwipe: true) {
                        Button(role: .destructive) {
                            deleteFile(file)
                        } label: {
                            Label("刪除", systemImage: "trash")
                        }
                    }
                }
            }
            Section {
                Button(action: { showBuild = true }) {
                    HStack {
                        Spacer()
                        Text("編譯")
                            .font(.headline)
                        Spacer()
                    }
                }
            }
            if !message.isEmpty {
                Section {
                    Text(message)
                        .font(.caption)
                        .foregroundColor(.secondary)
                }
            }
        }
        .navigationTitle(project.name)
        .toolbar {
            ToolbarItem(placement: .navigationBarTrailing) {
                if clipboard.copiedPath != nil {
                    Button("貼上") {
                        pasteFile()
                    }
                }
            }
        }
        .onAppear(perform: reloadFiles)
        .alert("重命名", isPresented: $showRenameAlert) {
            TextField("新名稱", text: $newName)
            Button("取消", role: .cancel) { }
            Button("確定") {
                renameFile(from: renameTarget, to: newName)
            }
        }
        .actionSheet(isPresented: $showActionSheet) {
            ActionSheet(title: Text(actionSheetFile ?? ""), buttons: [
                .default(Text("重命名")) {
                    if let f = actionSheetFile {
                        renameTarget = f
                        newName = f
                        showRenameAlert = true
                    }
                },
                .default(Text("複製")) {
                    if let f = actionSheetFile { copyFile(f, isCut: false) }
                },
                .default(Text("剪切")) {
                    if let f = actionSheetFile { copyFile(f, isCut: true) }
                },
                .cancel(Text("取消"))
            ])
        }
        .sheet(isPresented: $showEditor) {
            if let file = selectedFile {
                NavigationView {
                    FileEditorView(project: project, filename: file,
                                   onSave: { reloadFiles() })
                }
            }
        }
        .fullScreenCover(isPresented: $showBuild) {
            NavigationView {
                BuildView(project: project)
            }
        }
    }

    private func reloadFiles() {
        let dir = ProjectFiles.sourcesDirectory(for: project.name)
        files = (try? FileManager.default.contentsOfDirectory(atPath: dir.path)) ?? []
        message = ""
    }

    private func openFile(_ file: String) {
        selectedFile = file
        showEditor = true
    }

    private func deleteFile(_ file: String) {
        let url = ProjectFiles.sourcesDirectory(for: project.name)
            .appendingPathComponent(file)
        do {
            try FileManager.default.removeItem(at: url)
            reloadFiles()
        } catch {
            message = "刪除失敗：\(error.localizedDescription)"
        }
    }

    private func renameFile(from oldName: String, to newName: String) {
        guard !newName.isEmpty, newName != oldName else { return }
        let dir = ProjectFiles.sourcesDirectory(for: project.name)
        let oldURL = dir.appendingPathComponent(oldName)
        let newURL = dir.appendingPathComponent(newName)
        do {
            if FileManager.default.fileExists(atPath: newURL.path) {
                message = "重命名失敗：目標已存在"
                return
            }
            try FileManager.default.moveItem(at: oldURL, to: newURL)
            reloadFiles()
        } catch {
            message = "重命名失敗：\(error.localizedDescription)"
        }
    }

    private func copyFile(_ file: String, isCut: Bool) {
        let url = ProjectFiles.sourcesDirectory(for: project.name)
            .appendingPathComponent(file)
        clipboard.copiedPath = url.path
        clipboard.copiedName = file
        clipboard.isCut = isCut
        message = isCut ? "已剪切：\(file)" : "已複製：\(file)"
    }

    private func pasteFile() {
        guard let srcPath = clipboard.copiedPath,
              let name = clipboard.copiedName else { return }
        let dir = ProjectFiles.sourcesDirectory(for: project.name)
        let fm = FileManager.default
        var destName = name
        var destURL = dir.appendingPathComponent(destName)
        // 避免重名
        var counter = 1
        while fm.fileExists(atPath: destURL.path) {
            let base = (name as NSString).deletingPathExtension
            let ext = (name as NSString).pathExtension
            destName = ext.isEmpty ? "\(base)_\(counter)" : "\(base)_\(counter).\(ext)"
            destURL = dir.appendingPathComponent(destName)
            counter += 1
        }
        do {
            if clipboard.isCut {
                try fm.moveItem(atPath: srcPath, toPath: destURL.path)
                clipboard.copiedPath = nil
                clipboard.copiedName = nil
            } else {
                try fm.copyItem(atPath: srcPath, toPath: destURL.path)
            }
            reloadFiles()
            message = "已貼上：\(destName)"
        } catch {
            message = "貼上失敗：\(error.localizedDescription)"
        }
    }
}

/// 文件編輯器
struct FileEditorView: View {
    let project: Project
    let filename: String
    var onSave: () -> Void
    @Environment(\.presentationMode) var presentationMode
    @State private var content = ""
    @State private var message = ""

    var body: some View {
        VStack {
            CodeEditorView(text: $content)
            if !message.isEmpty {
                Text(message)
                    .font(.caption)
                    .foregroundColor(.secondary)
            }
        }
        .navigationTitle(filename)
        .navigationBarItems(
            trailing: Button("保存") { save() }
        )
        .onAppear(perform: load)
    }

    private func load() {
        let url = ProjectFiles.sourcesDirectory(for: project.name)
            .appendingPathComponent(filename)
        content = (try? String(contentsOf: url, encoding: .utf8)) ?? ""
    }

    private func save() {
        let url = ProjectFiles.sourcesDirectory(for: project.name)
            .appendingPathComponent(filename)
        do {
            try content.write(to: url, atomically: true, encoding: .utf8)
            message = "已保存"
            onSave()
            presentationMode.wrappedValue.dismiss()
        } catch {
            message = "保存失敗：\(error.localizedDescription)"
        }
    }
}
