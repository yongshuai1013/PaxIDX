import Foundation

/// 編譯階段：順序執行的單個步驟
struct BuildStage {
    /// 階段名稱（顯示用）
    let name: String
    /// 執行閉包：回傳 nil 表示成功，回傳字串表示失敗原因
    /// - Parameter log: 用來輸出日誌的回調
    let run: (_ log: (String) -> Void) -> String?
}

/// 編譯執行器：按順序跑完所有階段
/// iOS 15 兼容：用 GCD 回調，不用 async/await
final class BuildExecutor {
    private let stages: [BuildStage]

    init(stages: [BuildStage]) {
        self.stages = stages
    }

    /// 在背景執行緒執行
    /// - Parameters:
    ///   - onStage: 階段切換回調（主線程）
    ///   - onLog: 日誌回調（主線程）
    ///   - onDone: 完成回調（主線程），參數為（是否成功，訊息）
    func execute(
        onStage: @escaping (Int, String) -> Void,
        onLog: @escaping (String) -> Void,
        onDone: @escaping (Bool, String) -> Void
    ) {
        DispatchQueue.global(qos: .userInitiated).async {
            for (i, stage) in self.stages.enumerated() {
                DispatchQueue.main.async { onStage(i, stage.name) }
                DispatchQueue.main.async { onLog("▶ \(stage.name)") }
                if let err = stage.run({ line in
                    DispatchQueue.main.async { onLog(line) }
                }) {
                    DispatchQueue.main.async {
                        onLog("✘ 失敗：\(err)")
                        onDone(false, err)
                    }
                    return
                }
                DispatchQueue.main.async { onLog("✔ \(stage.name) 完成") }
            }
            DispatchQueue.main.async { onDone(true, "全部階段完成") }
        }
    }
}
