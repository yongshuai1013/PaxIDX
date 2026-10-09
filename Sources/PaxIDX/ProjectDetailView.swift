import SwiftUI

/// 專案詳情：文件列表＋編輯器＋編譯入口
struct ProjectDetailView: View {
    let project: Project
    @State private var files: [String] = []
    @State private var selectedFile: String?
    @State private var showEditor = false
    @State private var showBuild = false
    @State private var message = ""

    var body: some View {
        List {
            Section(header: Text("源文件")) {
                ForEach(files, id: \.self) { file in
                    Button(action: { openFile(file) }) {
                        HStack {
                            Text(file)
                            Spacer()
                            Image(systemName: "chevron.right")
                                .foregroundColor(.secondary)
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
        .onAppear(perform: reloadFiles)
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
    }

    private func openFile(_ file: String) {
        selectedFile = file
        showEditor = true
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
