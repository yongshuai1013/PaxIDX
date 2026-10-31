import Foundation

/// 項目文件管理：在 Documents/projects/ 下增刪查
final class ProjectFiles {
    /// 錯誤類型
    enum ProjectError: LocalizedError {
        case alreadyExists
        case invalidName

        var errorDescription: String? {
            switch self {
            case .alreadyExists: return "同名項目已存在"
            case .invalidName: return "項目名稱不合法"
            }
        }
    }

    /// projects 根目錄
    static var projectsDirectory: URL {
        let docs = FileManager.default.urls(for: .documentDirectory, in: .userDomainMask)[0]
        return docs.appendingPathComponent("projects", isDirectory: true)
    }

    /// 某個項目的目錄
    static func directory(for name: String) -> URL {
        return projectsDirectory.appendingPathComponent(name, isDirectory: true)
    }

    /// 某個項目的源碼目錄（Sources/）
    static func sourcesDirectory(for name: String) -> URL {
        return directory(for: name).appendingPathComponent("Sources", isDirectory: true)
    }

    /// 列出所有項目（讀目錄名 + project.json）
    static func listProjects() -> [Project] {
        let fm = FileManager.default
        let root = projectsDirectory
        guard let names = try? fm.contentsOfDirectory(atPath: root.path) else { return [] }
        var result: [Project] = []
        for name in names.sorted() {
            let metaURL = directory(for: name).appendingPathComponent("project.json")
            if let data = try? Data(contentsOf: metaURL),
               let p = try? JSONDecoder().decode(Project.self, from: data) {
                result.append(p)
            } else {
                // 沒有 project.json 就用目錄名補一個預設
                result.append(Project(name: name, bundleID: "com.example.\(name)"))
            }
        }
        return result
    }

    /// 新建項目：建目錄 + 寫 project.json + 放一個 main.c 範例
    static func createProject(name: String, bundleID: String, sdkFolder: String? = nil, kind: String = "c") throws {
        let trimmed = name.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !trimmed.isEmpty, !trimmed.contains("/") else { throw ProjectError.invalidName }
        let dir = directory(for: trimmed)
        guard !FileManager.default.fileExists(atPath: dir.path) else { throw ProjectError.alreadyExists }
        try FileManager.default.createDirectory(at: sourcesDirectory(for: trimmed), withIntermediateDirectories: true)
        let project = Project(name: trimmed, bundleID: bundleID, sdkFolder: sdkFolder)
        let data = try JSONEncoder().encode(project)
        try data.write(to: dir.appendingPathComponent("project.json"))
        // 放一個最小可編譯的範例（依專案類型）
        let sampleName: String
        let sample: String
        switch kind {
        case "cpp":
            sampleName = "main.cpp"
            sample = "#include <iostream>\n\nint main() {\n    std::cout << \"Hello, PaxIDX!\" << std::endl;\n    return 0;\n}\n"
        case "mm":
            sampleName = "main.mm"
            sample = "#import <Foundation/Foundation.h>\n#include <string>\n#include <iostream>\n\nint main(int argc, char *argv[]) {\n    @autoreleasepool {\n        std::string who = \"PaxIDX\";\n        std::cout << \"Hello from \" << who << std::endl;\n        NSLog(@\"Hello from %s\", who.c_str());\n    }\n    return 0;\n}\n"
        default:
            sampleName = "main.c"
            sample = "#include <stdio.h>\nint main() { printf(\"Hello, PaxIDX!\\n\"); return 0; }\n"
        }
        try sample.write(to: sourcesDirectory(for: trimmed).appendingPathComponent(sampleName), atomically: true, encoding: .utf8)
    }

    /// 更新項目的 SDK 選擇（寫回 project.json）
    static func updateSDKFolder(name: String, folder: String?) {
        let metaURL = directory(for: name).appendingPathComponent("project.json")
        guard let data = try? Data(contentsOf: metaURL),
              var p = try? JSONDecoder().decode(Project.self, from: data) else { return }
        p.sdkFolder = folder
        if let out = try? JSONEncoder().encode(p) {
            try? out.write(to: metaURL)
        }
    }

    /// 刪除項目（整個目錄）
    static func deleteProject(name: String) throws {
        try FileManager.default.removeItem(at: directory(for: name))
    }
}
