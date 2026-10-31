import SwiftUI

/// 代碼編輯器：行號＋C 語法高亮（iOS 15 可用）
/// 行號欄改自繪：照主編輯區 layoutManager 的 line fragment 位置逐行畫，
/// 跟著捲動重畫。舊做法拿第二個 UITextView 裝全部行號再同步
/// contentOffset——它關了捲動，offset 會被系統夾掉、超出畫面的行
/// 根本不排版，就是「滑下去行號不見／點一下冒出錯位行號」的病根。
struct CodeEditorView: UIViewRepresentable {
    @Binding var text: String
    var font: UIFont = .monospacedSystemFont(ofSize: 14, weight: .regular)

    func makeCoordinator() -> Coordinator {
        Coordinator(self)
    }

    func makeUIView(context: Context) -> UIView {
        let container = UIView()

        // 行號欄（自繪 view，不再是文字視圖）
        let gutter = LineNumberGutterView()
        gutter.backgroundColor = .systemBackground
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

        gutter.textView = textView
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
        context.coordinator.applyHighlight()

        return container
    }

    func updateUIView(_ uiView: UIView, context: Context) {
        // 外部 text 變化時更新（避免循環）
        if context.coordinator.textView?.text != text {
            context.coordinator.textView?.text = text
            context.coordinator.applyHighlight()
            context.coordinator.gutter?.setNeedsDisplay()
        }
    }

    class Coordinator: NSObject, UITextViewDelegate {
        var parent: CodeEditorView
        weak var gutter: LineNumberGutterView?
        weak var textView: UITextView?
        private var isHighlighting = false

        init(_ parent: CodeEditorView) {
            self.parent = parent
        }

        func textViewDidChange(_ textView: UITextView) {
            if isHighlighting { return }
            parent.text = textView.text
            applyHighlight()
            gutter?.setNeedsDisplay()
        }

        func textViewDidChangeSelection(_ textView: UITextView) {
            gutter?.setNeedsDisplay()
        }

        func scrollViewDidScroll(_ scrollView: UIScrollView) {
            gutter?.setNeedsDisplay()
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

/// 行號欄：依主編輯區每個 line fragment 的實際位置畫行號。
/// 自動換行造成的續行 fragment 不畫號（只在邏輯行首畫），與一般編輯器一致。
final class LineNumberGutterView: UIView {
    weak var textView: UITextView?
    var numberFont: UIFont = .monospacedSystemFont(ofSize: 14, weight: .regular)
    var numberColor: UIColor = .systemGray

    override func draw(_ rect: CGRect) {
        guard let tv = textView else { return }
        let lm = tv.layoutManager
        let tc = tv.textContainer
        lm.ensureLayout(for: tc)
        let ns = tv.text as NSString
        let inset = tv.textContainerInset
        // 可見範圍換算到 text container 座標
        let visible = CGRect(x: 0, y: tv.contentOffset.y - inset.top,
                             width: tc.size.width, height: tv.bounds.height)
        let glyphRange = lm.glyphRange(forBoundingRect: visible, in: tc)
        if glyphRange.length == 0 { return }
        // 第一個可見字元的邏輯行號（前面的換行數＋1）
        let firstChar = lm.characterIndexForGlyph(at: glyphRange.location)
        var lineNumber = 1
        if firstChar > 0 {
            lineNumber = ns.substring(to: firstChar)
                .components(separatedBy: "\n").count
        }
        let attrs: [NSAttributedString.Key: Any] = [
            .font: numberFont, .foregroundColor: numberColor,
        ]
        var isFirstFragment = true
        lm.enumerateLineFragments(forGlyphRange: glyphRange) {
            _, usedRect, _, fragGlyphRange, _ in
            let charIndex = lm.characterIndexForGlyph(at: fragGlyphRange.location)
            let isLineStart = charIndex == 0
                || (charIndex > 0 && ns.character(at: charIndex - 1) == 10)
            if isLineStart {
                if !isFirstFragment { lineNumber += 1 }
                let s = "\(lineNumber)" as NSString
                let size = s.size(withAttributes: attrs)
                let y = usedRect.minY + inset.top - tv.contentOffset.y
                    + (usedRect.height - size.height) / 2
                s.draw(at: CGPoint(x: self.bounds.width - size.width - 6, y: y),
                       withAttributes: attrs)
            }
            isFirstFragment = false
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
