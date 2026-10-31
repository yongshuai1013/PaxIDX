import SwiftUI
import Highlightr

/// 代碼編輯器：行號＋C 語法高亮（iOS 15 可用）
/// 行號改畫在 UITextView 子類自己的 draw 裡（Forge 等現成編輯器的通行做法）：
/// 號碼與文字同一個 view、同一個座標系、同一次繪製，天生跟著內容捲動。
/// 前兩版都栽在「分離的 gutter view」：第一版拿關捲動的 UITextView 同步
/// offset 被系統夾掉；第二版自繪 view 在自己的繪製時機采样主 view 的
/// contentOffset 與排版，兩者世代不一致時行號就增減漂移（實測同段代碼
/// 兩張截圖行距編號都不同）。本版廢掉分離 gutter，inset 左側即號碼欄。
struct CodeEditorView: UIViewRepresentable {
    @Binding var text: String
    /// highlight.js 語言名（c／cpp／objectivec／swift），由檔案副檔名決定
    var language: String = "cpp"
    var font: UIFont = .monospacedSystemFont(ofSize: 14, weight: .regular)

    func makeCoordinator() -> Coordinator {
        Coordinator(self)
    }

    func makeUIView(context: Context) -> EditorTextView {
        let textView = EditorTextView()
        textView.delegate = context.coordinator
        textView.font = context.coordinator.currentFont()
        textView.backgroundColor = .systemBackground
        textView.textContainerInset = UIEdgeInsets(top: 8, left: 4, bottom: 8, right: 4)
        textView.autocapitalizationType = .none
        textView.autocorrectionType = .no
        // 雙指縮放：改字體大小（值存 UserDefaults）
        let pinch = UIPinchGestureRecognizer(target: context.coordinator,
                                             action: #selector(Coordinator.handlePinch(_:)))
        textView.addGestureRecognizer(pinch)

        context.coordinator.textView = textView
        context.coordinator.applyHighlight()
        textView.refreshGutterWidth()
        return textView
    }

    func updateUIView(_ uiView: EditorTextView, context: Context) {
        // 外部 text 變化時更新（避免循環）
        if uiView.text != text {
            uiView.text = text
            context.coordinator.applyHighlight()
            uiView.refreshGutterWidth()
        }
    }

    class Coordinator: NSObject, UITextViewDelegate {
        var parent: CodeEditorView
        weak var textView: EditorTextView?
        private var isHighlighting = false
        private(set) var fontSize: CGFloat
        private var pinchStartSize: CGFloat = 14

        init(_ parent: CodeEditorView) {
            self.parent = parent
            let saved = UserDefaults.standard.double(forKey: "paxidx.editor.fontSize")
            fontSize = saved > 0 ? CGFloat(saved) : parent.font.pointSize
        }

        func currentFont() -> UIFont {
            .monospacedSystemFont(ofSize: fontSize, weight: .regular)
        }

        @objc func handlePinch(_ g: UIPinchGestureRecognizer) {
            if g.state == .began { pinchStartSize = fontSize }
            if g.state == .changed || g.state == .ended {
                setFontSize(min(32, max(9, pinchStartSize * g.scale)))
            }
        }

        private func setFontSize(_ size: CGFloat) {
            if abs(size - fontSize) < 0.4 { return }
            fontSize = size
            UserDefaults.standard.set(Double(size), forKey: "paxidx.editor.fontSize")
            textView?.font = currentFont()
            applyHighlight()
            textView?.refreshGutterWidth()
        }

        func textViewDidChange(_ textView: UITextView) {
            if isHighlighting { return }
            parent.text = textView.text
            applyHighlight()
            (textView as? EditorTextView)?.refreshGutterWidth()
        }

        private var highlighter: Highlightr?
        private var appliedThemeName = ""
        private var appliedFontSize: CGFloat = -1

        func applyHighlight() {
            guard let tv = textView else { return }
            isHighlighting = true
            let selectedRange = tv.selectedRange
            let code = tv.text ?? ""
            if highlighter == nil { highlighter = Highlightr() }
            var result: NSAttributedString?
            if let hl = highlighter {
                // 主題隨深淺色（xcode 亮／xcode-dark 暗）；換主題或字級才重設，避免每鍵重解析 CSS
                let dark = tv.traitCollection.userInterfaceStyle == .dark
                let themeName = dark ? "xcode-dark" : "xcode"
                if themeName != appliedThemeName {
                    _ = hl.setTheme(to: themeName)
                    appliedThemeName = themeName
                    appliedFontSize = -1
                }
                if fontSize != appliedFontSize {
                    hl.theme.setCodeFont(currentFont())
                    appliedFontSize = fontSize
                }
                result = hl.highlight(code, as: parent.language)
            }
            if let result = result {
                // 主題自帶的 .hljs 背景色不用：編輯器背景維持 systemBackground
                let mutable = NSMutableAttributedString(attributedString: result)
                mutable.removeAttribute(.backgroundColor,
                                        range: NSRange(location: 0, length: mutable.length))
                tv.attributedText = mutable
            } else {
                // Highlightr 不可用就老實純文字，不假裝有高亮
                tv.attributedText = NSAttributedString(
                    string: code,
                    attributes: [.font: currentFont(), .foregroundColor: UIColor.label])
            }
            tv.selectedRange = selectedRange
            isHighlighting = false
        }
    }
}

/// 編輯器本體：行號畫在自己的 draw 裡，gutter 欄就是 textContainerInset 的左側空間。
final class EditorTextView: UITextView {
    private(set) var gutterWidth: CGFloat = 0

    /// 依總行數位數與字體大小算 gutter 寬，同步左 inset
    func refreshGutterWidth() {
        let lineCount = max(1, text.reduce(into: 1) { n, c in if c == "\n" { n += 1 } })
        let digits = CGFloat(max(2, String(lineCount).count))
        let w = digits * (font?.pointSize ?? 14) * 0.62 + 14
        if abs(w - gutterWidth) > 0.5 {
            gutterWidth = w
            textContainerInset.left = w + 4
        }
        setNeedsDisplay()
    }

    override func layoutSubviews() {
        super.layoutSubviews()
        setNeedsDisplay()   // 捲動時重畫行號（與 Forge 同法）
    }

    override func draw(_ rect: CGRect) {
        super.draw(rect)
        guard gutterWidth > 0, let font = font else { return }
        let lm = layoutManager
        let tc = textContainer
        let inset = textContainerInset
        let visible = CGRect(origin: contentOffset, size: bounds.size)

        // gutter 背景
        UIColor.secondarySystemBackground.setFill()
        UIRectFill(CGRect(x: visible.minX, y: visible.minY,
                          width: gutterWidth, height: visible.height))

        let ns = text as NSString
        let area = CGRect(x: visible.minX - inset.left, y: visible.minY - inset.top,
                          width: tc.size.width, height: visible.height)
        let glyphs = lm.glyphRange(forBoundingRect: area, in: tc)
        let attrs: [NSAttributedString.Key: Any] = [
            .font: font, .foregroundColor: UIColor.systemGray,
        ]

        func drawNumber(_ n: Int, frag: CGRect) {
            let s = "\(n)" as NSString
            let sz = s.size(withAttributes: attrs)
            s.draw(at: CGPoint(x: visible.minX + gutterWidth - 6 - sz.width,
                               y: frag.minY + inset.top + (frag.height - sz.height) / 2),
                   withAttributes: attrs)
        }

        if glyphs.length > 0 {
            // 第一個可見字元之前的換行數定起算行號：
            // 若它正好在行首，下一個行首 fragment 就是這一行；
            // 若它在行中（上方有被捲出的續行），下一個行首要再 +1。
            let first = lm.characterIndexForGlyph(at: glyphs.location)
            var newlines = 0
            var i = 0
            while i < first { if ns.character(at: i) == 10 { newlines += 1 }; i += 1 }
            let firstIsStart = first == 0 || ns.character(at: first - 1) == 10
            var lineNo = newlines + (firstIsStart ? 1 : 2)
            lm.enumerateLineFragments(forGlyphRange: glyphs) { frag, _, _, gr, _ in
                let ci = lm.characterIndexForGlyph(at: gr.location)
                if ci == 0 || ns.character(at: ci - 1) == 10 {
                    drawNumber(lineNo, frag: frag)
                    lineNo += 1
                }
            }
        }

        // 結尾換行後的額外空行也要有號
        let extra = lm.extraLineFragmentRect
        if extra.height > 0 {
            let r = CGRect(x: extra.minX + inset.left, y: extra.minY + inset.top,
                           width: extra.width, height: extra.height)
            if r.intersects(visible) {
                let total = text.reduce(into: 1) { n, c in if c == "\n" { n += 1 } }
                drawNumber(ns.length == 0 ? 1 : total, frag: extra)
            }
        }
    }
}
