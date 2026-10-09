import SwiftUI

/// 專案列表（iOS 15 兼容：用 NavigationView，不用 NavigationStack）
struct ProjectsView: View {
    @State private var projects: [Project] = []
    @State private var showingNewProject = false
    @State private var showError = false
    @State private var errorMessage = ""
    @State private var activeProject: Project?

    var body: some View {
        NavigationView {
            List {
                ForEach(projects) { project in
                    Button(action: { activeProject = project }) {
                        VStack(alignment: .leading, spacing: 4) {
                            Text(project.name).font(.headline)
                            Text(project.bundleID)
                                .font(.caption)
                                .foregroundColor(.secondary)
                        }
                        .frame(maxWidth: .infinity, alignment: .leading)
                        .contentShape(Rectangle())
                    }
                    .buttonStyle(PlainButtonStyle())
                }
                .onDelete(perform: delete)
            }
            .navigationTitle("專案")
            .navigationBarItems(trailing: Button(action: { showingNewProject = true }) {
                Image(systemName: "plus")
            })
            .sheet(isPresented: $showingNewProject, onDismiss: reload) {
                NewProjectView()
            }
            // 專案頁用全螢幕覆蓋打開，底部 TabBar 整列自然隱藏
            .fullScreenCover(item: $activeProject) { project in
                NavigationView {
                    BuildView(project: project)
                }
            }
            .onAppear(perform: reload)
            .alert(isPresented: $showError) {
                Alert(title: Text("出錯"), message: Text(errorMessage), dismissButton: .default(Text("好")))
            }
        }
    }

    /// 重新讀取專案列表
    private func reload() {
        projects = ProjectFiles.listProjects()
    }

    private func delete(at offsets: IndexSet) {
        for i in offsets {
            do {
                try ProjectFiles.deleteProject(name: projects[i].name)
            } catch {
                errorMessage = error.localizedDescription
                showError = true
            }
        }
        reload()
    }
}

/// 新建項目表單
struct NewProjectView: View {
    @Environment(\.presentationMode) private var presentationMode
    @State private var name = ""
    @State private var bundleID = ""
    @State private var showError = false
    @State private var errorMessage = ""
    @State private var activeProject: Project?

    var body: some View {
        NavigationView {
            Form {
                Section(header: Text("專案資訊")) {
                    TextField("專案名稱", text: $name)
                    TextField("Bundle ID（可空，自動生成）", text: $bundleID)
                        .autocapitalization(.none)
                        .disableAutocorrection(true)
                }
                Section {
                    Button("建立") {
                        do {
                            let bid = bundleID.isEmpty ? "com.example.\(name)" : bundleID
                            try ProjectFiles.createProject(name: name, bundleID: bid)
                            presentationMode.wrappedValue.dismiss()
                        } catch {
                            errorMessage = error.localizedDescription
                            showError = true
                        }
                    }
                }
            }
            .navigationTitle("新專案")
            .navigationBarItems(leading: Button("取消") {
                presentationMode.wrappedValue.dismiss()
            })
            .alert(isPresented: $showError) {
                Alert(title: Text("出錯"), message: Text(errorMessage), dismissButton: .default(Text("好")))
            }
        }
    }
}
