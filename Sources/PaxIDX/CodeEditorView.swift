import SwiftUI

/// 代碼編輯器：行號＋C 語法高亮（iOS 15 可用）
struct CodeEditorView: UIViewRepresentable {
    @Binding var text: String
    var font: UIFont = .monospacedSystemFont(ofSize: 14, weight: .regular)

    func makeCoordinator() -> Coordinator {
        Coordinator(self)
    }

    func makeUIView(context: Context) -> UIView {
        let container = UIView()

        // 行號 gutter
        let gutter = UITextView()
        gutter.isEditable = false
        gutter.isSelectable = false
        gutter.isScrollEnabled = false
        gutter.font = font
        gutter.textColor = .systemGray
        gutter.backgroundColor = .systemBackground
        gutter.textContainerInset = UIEdgeInsets(top: 8, left: 4, bottom: 8, right: 4)
        gutter.translatesAutoresizingMaskIntoConstraints = false

        // 主編輯區
        let textView = UITextView()
        textView.delegate = context.coordinator
        textView.font = font
        textView.backgroundColor = .systemBackground
        textView.textContainerInset = UIEdgeInsets(top: 8, left: 4, bottom: 8, right: 4)
        textView.autocapitalizationType = .none
        textView.autocorrectionType = .no
        textView.translatesAutoresizingMaskIntoConstraints = false
        // 同步滾動
        textView.delegate = context.coordinator

        container.addSubview(gutter)
        container.addSubview(textView)

        NSLayoutConstraint.activate([
            gutter.leadingAnchor.constraint(equalTo: container.leadingAnchor),
            gutter.topAnchor.constraint(equalTo: container.topAnchor),
            gutter.bottomAnchor.constraint(equalTo: container.bottomAnchor),
            gutter.widthAnchor.constraint(equalToConstant: 44),

            textView.leadingAnchor.constraint(equalTo: gutter.trailingAnchor),
            textView.trailingAnchor.constraint(equalTo: container.trailingAnchor),
            textView.topAnchor.constraint(equalTo: container.topAnchor),
            textView.bottomAnchor.constraint(equalTo: container.bottomAnchor),
        ])

        context.coordinator.gutter = gutter
        context.coordinator.textView = textView
        context.coordinator.updateGutter()
        context.coordinator.applyHighlight()

        return container
    }

    func updateUIView(_ uiView: UIView, context: Context) {
        // 外部 text 變化時更新（避免循環）
        if context.coordinator.textView?.text != text {
            context.coordinator.textView?.text = text
            context.coordinator.applyHighlight()
            context.coordinator.updateGutter()
        }
    }

    class Coordinator: NSObject, UITextViewDelegate {
        var parent: CodeEditorView
        weak var gutter: UITextView?
        weak var textView: UITextView?
        private var isHighlighting = false

        init(_ parent: CodeEditorView) {
            self.parent = parent
        }

        func textViewDidChange(_ textView: UITextView) {
            if isHighlighting { return }
            parent.text = textView.text
            applyHighlight()
            updateGutter()
        }

        func scrollViewDidScroll(_ scrollView: UIScrollView) {
            // 同步 gutter 滾動（gutter 不滾動，用 contentOffset 偏移文字）
            updateGutterOffset()
        }

        func updateGutter() {
            guard let tv = textView, let gutter = gutter else { return }
            let lines = tv.text.components(separatedBy: "\n").count
            let numbers = (1...max(lines, 1)).map { "\($0)" }.joined(separator: "\n")
            gutter.text = numbers
            updateGutterOffset()
        }

        private func updateGutterOffset() {
            guard let tv = textView, let gutter = gutter else { return }
            // gutter 顯示對應行：用 contentOffset 計算首行
            let offsetY = tv.contentOffset.y
            gutter.contentOffset = CGPoint(x: 0, y: offsetY)
        }

        func applyHighlight() {
            guard let tv = textView else { return }
            isHighlighting = true
            let selectedRange = tv.selectedRange
            let attr = CHighlighter.highlight(tv.text, font: parent.font)
            tv.attributedText = attr
            tv.selectedRange = selectedRange
            isHighlighting = false
        }
    }
}

/// 簡單 C 高亮：關鍵字／字串／註釋／預處理／數字
private enum CHighlighter {
    static let keywords: Set<String> = [
        "int", "char", "void", "float", "double", "long", "short", "signed", "unsigned",
        "struct", "union", "enum", "typedef", "static", "const", "extern", "return",
        "if", "else", "for", "while", "do", "switch", "case", "break", "continue",
        "sizeof", "include",
    ]

    static func highlight(_ text: String, font: UIFont) -> NSAttributedString {
        let result = NSMutableAttributedString(string: text)
        let fullRange = NSRange(location: 0, length: (text as NSString).length)
        result.addAttribute(.font, value: font, range: fullRange)
        result.addAttribute(.foregroundColor, value: UIColor.label, range: fullRange)

        let ns = text as NSString

        // 註釋：//... 和 /*...*/
        let commentPattern = #"//.*|/\*[\s\S]*?\*/"#
        apply(pattern: commentPattern, color: .systemGreen, in: result, ns: ns)

        // 字串："..."
        let stringPattern = #""(?:[^"\\]|\\.)*""#
        apply(pattern: stringPattern, color: .systemRed, in: result, ns: ns)

        // 預處理：#...
        let prePattern = #"^\s*#.*"#
        apply(pattern: prePattern, color: .systemRed, options: .anchorsMatchLines, in: result, ns: ns)

        // 數字
        let numPattern = #"\b\d+\b"#
        apply(pattern: numPattern, color: .systemPurple, in: result, ns: ns)

        // 關鍵字
        for kw in keywords {
            let pattern = "\\b\(kw)\\b"
            apply(pattern: pattern, color: .systemPurple, in: result, ns: ns)
        }

        return result
    }

    private static func apply(pattern: String, color: UIColor,
                              options: NSRegularExpression.Options = [],
                              in attr: NSMutableAttributedString, ns: NSString) {
        guard let re = try? NSRegularExpression(pattern: pattern, options: options) else { return }
        let range = NSRange(location: 0, length: ns.length)
        for m in re.matches(in: ns as String, options: [], range: range) {
            attr.addAttribute(.foregroundColor, value: color, range: m.range)
        }
    }
}
