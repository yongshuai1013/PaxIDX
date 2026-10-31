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
    /// 預覽用途可關編輯（設定頁主題預覽）
    var editable: Bool = true
    /// 補全候選的額外詞彙（呼叫端傳入：同專案各源檔的標識符）
    var completionVocabulary: [String] = []
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
        textView.isEditable = editable
        textView.autocapitalizationType = .none
        textView.autocorrectionType = .no
        // 雙指縮放：改字體大小（值存 UserDefaults）
        let pinch = UIPinchGestureRecognizer(target: context.coordinator,
                                             action: #selector(Coordinator.handlePinch(_:)))
        textView.addGestureRecognizer(pinch)

        if editable {
            // 補全候選條掛鍵盤上方（唯讀預覽不掛）
            let bar = CompletionBarView()
            bar.onPick = { [weak c = context.coordinator] word in
                c?.applyCompletion(word)
            }
            textView.inputAccessoryView = bar
            context.coordinator.completionBar = bar
        }

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
        } else if context.coordinator.themeIsStale(for: uiView) {
            // 在設定頁改了主題、回到已開著的編輯器：直接換色不用重開
            context.coordinator.applyHighlight()
        }
    }

    class Coordinator: NSObject, UITextViewDelegate {
        var parent: CodeEditorView
        weak var textView: EditorTextView?
        weak var completionBar: CompletionBarView?
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
            refreshCompletions()
        }

        func textViewDidChangeSelection(_ textView: UITextView) {
            refreshCompletions()
        }

        func themeIsStale(for tv: UITextView) -> Bool {
            if appliedThemeName.isEmpty { return false }
            let dark = tv.traitCollection.userInterfaceStyle == .dark
            return EditorThemeStore.resolved(dark: dark) != appliedThemeName
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
                // 主題：設定頁選的 Highlightr 主題；「跟隨系統」才依深淺色配 xcode／xcode-dark
                let dark = tv.traitCollection.userInterfaceStyle == .dark
                let themeName = EditorThemeStore.resolved(dark: dark)
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
                // 編輯器背景跟主題走（深色主題配淺底會沒法看）
                if result != nil, let bg = hl.theme.themeBackgroundColor {
                    tv.backgroundColor = bg
                }
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

/// 編輯器主題偏好（設定頁與編輯器共用）：存 Highlightr 主題名；"auto" 為跟隨系統。
enum EditorThemeStore {
    static let key = "paxidx.editor.theme"
    static let auto = "auto"
    static var selected: String {
        UserDefaults.standard.string(forKey: key) ?? auto
    }
    static func resolved(dark: Bool) -> String {
        let sel = selected
        return sel == auto ? (dark ? "xcode-dark" : "xcode") : sel
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

        // gutter 背景：跟編輯器底色（主題色）一致，避免深色主題露淺色條
        (backgroundColor ?? .secondarySystemBackground).setFill()
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

// MARK: - 詞彙補全（第一版：前綴比對，不做型別推斷）

extension CodeEditorView.Coordinator {
    /// 游標前的標識符前綴（至少 2 字、非純數字）
    func currentPrefix() -> (word: String, range: NSRange)? {
        guard let tv = textView else { return nil }
        let sel = tv.selectedRange
        guard sel.length == 0, sel.location > 0 else { return nil }
        let ns = tv.text as NSString
        var start = sel.location
        while start > 0 {
            let ch = ns.character(at: start - 1)
            let isIdent = (ch >= 65 && ch <= 90) || (ch >= 97 && ch <= 122)
                || (ch >= 48 && ch <= 57) || ch == 95
            if !isIdent { break }
            start -= 1
        }
        let len = sel.location - start
        guard len >= 2 else { return nil }
        let word = ns.substring(with: NSRange(location: start, length: len))
        if word.allSatisfy({ $0.isNumber }) { return nil }
        return (word, NSRange(location: start, length: len))
    }

    /// 重算候選並更新候選條；候選池＝內建詞表＋專案詞＋本文標識符
    func refreshCompletions() {
        guard let tv = textView, completionBar != nil else { return }
        guard let (prefix, _) = currentPrefix() else {
            setBar(tv, [])
            return
        }
        var pool = CompletionVocab.words(for: parent.language)
        pool.formUnion(parent.completionVocabulary)
        pool.formUnion(CompletionVocab.identifiers(in: tv.text ?? ""))
        let lower = prefix.lowercased()
        var hits = Array(pool.filter { $0.lowercased().hasPrefix(lower) && $0 != prefix })
        hits.sort { ($0.count, $0.lowercased()) < ($1.count, $1.lowercased()) }
        setBar(tv, Array(hits.prefix(12)))
    }

    private func setBar(_ tv: EditorTextView, _ candidates: [String]) {
        guard let bar = completionBar else { return }
        let was = bar.isShowing
        bar.update(candidates: candidates)
        if bar.isShowing != was { tv.reloadInputViews() }
    }

    /// 點選候選：以前綴範圍換成完整詞，游標移到詞尾
    func applyCompletion(_ word: String) {
        guard let tv = textView, let (_, range) = currentPrefix() else { return }
        let ns = tv.text as NSString
        tv.text = ns.replacingCharacters(in: range, with: word)
        tv.selectedRange = NSRange(location: range.location + (word as NSString).length,
                                   length: 0)
        textViewDidChange(tv)
    }
}

/// 補全候選條：掛在鍵盤上方（inputAccessoryView），橫向捲動；無候選時高度收成 0。
final class CompletionBarView: UIView {
    private let scroll = UIScrollView()
    private let stack = UIStackView()
    var onPick: ((String) -> Void)?
    private(set) var isShowing = false

    override init(frame: CGRect) {
        super.init(frame: frame)
        backgroundColor = .secondarySystemBackground
        autoresizingMask = .flexibleWidth
        scroll.showsHorizontalScrollIndicator = false
        scroll.translatesAutoresizingMaskIntoConstraints = false
        stack.axis = .horizontal
        stack.spacing = 8
        stack.alignment = .center
        stack.translatesAutoresizingMaskIntoConstraints = false
        addSubview(scroll)
        scroll.addSubview(stack)
        NSLayoutConstraint.activate([
            scroll.leadingAnchor.constraint(equalTo: leadingAnchor),
            scroll.trailingAnchor.constraint(equalTo: trailingAnchor),
            scroll.topAnchor.constraint(equalTo: topAnchor),
            scroll.bottomAnchor.constraint(equalTo: bottomAnchor),
            stack.leadingAnchor.constraint(equalTo: scroll.contentLayoutGuide.leadingAnchor,
                                            constant: 10),
            stack.trailingAnchor.constraint(equalTo: scroll.contentLayoutGuide.trailingAnchor,
                                             constant: -10),
            stack.topAnchor.constraint(equalTo: scroll.contentLayoutGuide.topAnchor),
            stack.bottomAnchor.constraint(equalTo: scroll.contentLayoutGuide.bottomAnchor),
            stack.heightAnchor.constraint(equalTo: scroll.frameLayoutGuide.heightAnchor),
        ])
    }

    required init?(coder: NSCoder) { fatalError("init(coder:) has not been implemented") }

    override var intrinsicContentSize: CGSize {
        CGSize(width: UIView.noIntrinsicMetric, height: isShowing ? 42 : 0)
    }

    func update(candidates: [String]) {
        let show = !candidates.isEmpty
        if show != isShowing {
            isShowing = show
            invalidateIntrinsicContentSize()
        }
        for v in stack.arrangedSubviews {
            stack.removeArrangedSubview(v)
            v.removeFromSuperview()
        }
        for word in candidates {
            let b = UIButton(type: .system)
            b.setTitle(word, for: .normal)
            b.titleLabel?.font = .monospacedSystemFont(ofSize: 14, weight: .regular)
            b.contentEdgeInsets = UIEdgeInsets(top: 5, left: 10, bottom: 5, right: 10)
            b.backgroundColor = .systemBackground
            b.layer.cornerRadius = 7
            b.addAction(UIAction { [weak self] _ in self?.onPick?(word) },
                        for: .touchUpInside)
            stack.addArrangedSubview(b)
        }
        scroll.setContentOffset(.zero, animated: false)
    }
}

/// 補全詞表與標識符抽取（編輯器與 FileEditorView 共用同一套抽詞邏輯）
enum CompletionVocab {
    /// 抽出文字裡長度 ≥3 的標識符
    static func identifiers(in text: String) -> Set<String> {
        var out = Set<String>()
        var cur = ""
        func flush() {
            if cur.count >= 3 { out.insert(cur) }
            cur = ""
        }
        for scalar in text.unicodeScalars {
            let v = scalar.value
            if (v >= 65 && v <= 90) || (v >= 97 && v <= 122)
                || (v >= 48 && v <= 57) || v == 95 {
                cur.unicodeScalars.append(scalar)
            } else {
                flush()
            }
        }
        flush()
        return out
    }

    static func words(for language: String) -> Set<String> {
        language == "swift" ? swiftWords : cFamilyWords
    }

    /// C／C++／ObjC 共用：關鍵字＋常用型別＋常用 API
    static let cFamilyWords: Set<String> = [
        // 關鍵字
        "int", "char", "void", "float", "double", "long", "short", "bool",
        "signed", "unsigned", "struct", "union", "enum", "typedef", "static",
        "const", "extern", "return", "if", "else", "for", "while", "do",
        "switch", "case", "default", "break", "continue", "sizeof", "goto",
        "class", "public", "private", "protected", "virtual", "override",
        "template", "typename", "namespace", "using", "new", "delete", "this",
        "nullptr", "true", "false", "auto", "constexpr", "noexcept", "friend",
        "inline", "mutable", "explicit", "operator", "throw", "try", "catch",
        "interface", "implementation", "property", "end", "autoreleasepool",
        "synthesize", "dynamic", "protocol", "selector", "nonatomic", "atomic",
        "strong", "weak", "assign", "copy", "readonly", "readwrite", "retain",
        "nil", "YES", "NO", "self", "super", "import", "include", "define",
        // 型別
        "NSString", "NSMutableString", "NSArray", "NSMutableArray",
        "NSDictionary", "NSMutableDictionary", "NSSet", "NSNumber", "NSData",
        "NSDate", "NSURL", "NSError", "NSObject", "NSValue", "NSIndexPath",
        "UIView", "UIViewController", "UIWindow", "UILabel", "UIButton",
        "UIColor", "UIFont", "UIScreen", "UIApplication", "UIResponder",
        "UIImage", "UIImageView", "UITableView", "UICollectionView",
        "UITextField", "UIScrollView", "UIStackView", "UIAlertController",
        "BOOL", "NSInteger", "NSUInteger", "CGFloat", "CGRect", "CGPoint",
        "CGSize", "SEL", "size_t", "uint8_t", "uint32_t", "int32_t", "int64_t",
        "string", "vector", "map", "pair", "shared_ptr", "unique_ptr",
        // 常用 API／方法名
        "NSLog", "NSStringFromClass", "NSClassFromString", "UIApplicationMain",
        "alloc", "init", "initWithFrame", "addSubview", "removeFromSuperview",
        "viewDidLoad", "viewWillAppear", "viewDidAppear", "layoutSubviews",
        "backgroundColor", "textColor", "textAlignment", "font", "text",
        "frame", "bounds", "center", "hidden", "alpha", "userInteractionEnabled",
        "addTarget", "setTitle", "setImage", "addGestureRecognizer",
        "present", "dismiss", "pushViewController", "popViewController",
        "stringWithFormat", "stringWithUTF8String", "UTF8String", "c_str",
        "length", "count", "size", "push_back", "append", "begin", "end",
        "makeKeyAndVisible", "rootViewController", "mainScreen", "whiteColor",
        "blackColor", "clearColor", "systemFontOfSize", "boldSystemFontOfSize",
        "dispatch_async", "dispatch_once", "main", "argc", "argv",
    ]

    /// Swift 關鍵字＋常用型別
    static let swiftWords: Set<String> = [
        "import", "func", "var", "let", "class", "struct", "enum", "protocol",
        "extension", "guard", "return", "if", "else", "for", "while", "switch",
        "case", "default", "break", "continue", "inout", "static", "private",
        "public", "internal", "fileprivate", "override", "init", "deinit",
        "self", "super", "nil", "true", "false", "some", "any", "throws",
        "throw", "try", "catch", "do", "defer", "in", "where", "typealias",
        "associatedtype", "lazy", "weak", "unowned", "mutating", "nonmutating",
        "View", "body", "Text", "VStack", "HStack", "ZStack", "Spacer",
        "Button", "Image", "List", "Form", "Section", "NavigationView",
        "NavigationLink", "State", "Binding", "ObservedObject", "StateObject",
        "EnvironmentObject", "Published", "Environment", "AppStorage",
        "String", "Int", "Double", "Float", "Bool", "Array", "Dictionary",
        "Set", "Optional", "Date", "URL", "Data", "UUID", "Foundation",
        "SwiftUI", "UIKit", "print", "fatalError",
    ]
}
