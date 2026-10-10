import AppKit
import RackoonCore
import SwiftUI

/// A small code editor for compose YAML and `.env`: monospaced, line numbers, syntax colours from the active
/// terminal theme, bands behind changed and failing lines, 2-space tabs and auto-indent. Use `.id(file)` so each
/// file gets its own text view and therefore its own undo history.
struct CodeEditorView: NSViewRepresentable {
    @Binding var text: String
    let isEnv: Bool
    let theme: TerminalTheme
    let changedLines: Set<Int>
    let errorLines: Set<Int>

    func makeCoordinator() -> Coordinator { Coordinator(self) }

    func makeNSView(context: Context) -> NSScrollView {
        let scroll = NSScrollView()
        scroll.hasVerticalScroller = true
        scroll.hasHorizontalScroller = true
        scroll.autohidesScrollers = true
        scroll.borderType = .noBorder

        let tv = EditorTextView()
        tv.isRichText = false
        tv.allowsUndo = true
        tv.isAutomaticQuoteSubstitutionEnabled = false      // smart quotes would corrupt YAML
        tv.isAutomaticDashSubstitutionEnabled = false
        tv.isAutomaticTextReplacementEnabled = false
        tv.isAutomaticSpellingCorrectionEnabled = false
        tv.isContinuousSpellCheckingEnabled = false
        tv.isGrammarCheckingEnabled = false
        tv.isAutomaticLinkDetectionEnabled = false
        tv.isAutomaticDataDetectionEnabled = false
        tv.smartInsertDeleteEnabled = false
        tv.usesFindBar = true
        tv.isIncrementalSearchingEnabled = true
        // No wrapping: YAML lines are read as written, and a long line scrolls sideways.
        tv.isHorizontallyResizable = true
        tv.isVerticallyResizable = true
        tv.maxSize = NSSize(width: CGFloat.greatestFiniteMagnitude, height: CGFloat.greatestFiniteMagnitude)
        tv.textContainer?.widthTracksTextView = false
        tv.textContainer?.containerSize = NSSize(width: CGFloat.greatestFiniteMagnitude, height: CGFloat.greatestFiniteMagnitude)
        tv.textContainerInset = NSSize(width: 6, height: 10)
        tv.string = text
        scroll.documentView = tv

        let ruler = LineNumberRuler(scrollView: scroll, orientation: .verticalRuler)
        ruler.clientView = tv
        scroll.verticalRulerView = ruler
        scroll.hasVerticalRuler = true
        scroll.rulersVisible = true

        tv.delegate = context.coordinator
        context.coordinator.textView = tv
        context.coordinator.ruler = ruler
        context.coordinator.apply(parent: self, force: true)
        return scroll
    }

    func updateNSView(_ scroll: NSScrollView, context: Context) {
        context.coordinator.parent = self
        context.coordinator.apply(parent: self, force: false)
    }

    @MainActor
    final class Coordinator: NSObject, NSTextViewDelegate {
        var parent: CodeEditorView
        weak var textView: EditorTextView?
        weak var ruler: LineNumberRuler?
        private var styledKey = ""

        init(_ parent: CodeEditorView) { self.parent = parent }

        func textDidChange(_ notification: Notification) {
            guard let tv = textView else { return }
            if parent.text != tv.string { parent.text = tv.string }
            restyle(force: true)
        }

        func apply(parent: CodeEditorView, force: Bool) {
            guard let tv = textView else { return }
            if tv.string != parent.text {
                // An outside change (Revert, reload): replace through the text system so it can be undone.
                let full = NSRange(location: 0, length: (tv.string as NSString).length)
                let keep = min(tv.selectedRange().location, (parent.text as NSString).length)
                if tv.shouldChangeText(in: full, replacementString: parent.text) {
                    tv.textStorage?.replaceCharacters(in: full, with: parent.text)
                    tv.didChangeText()
                }
                tv.setSelectedRange(NSRange(location: keep, length: 0))
            }
            restyle(force: force)
            let changedBands = tv.changedLines != parent.changedLines || tv.errorLines != parent.errorLines
            tv.changedLines = parent.changedLines
            tv.errorLines = parent.errorLines
            ruler?.changedLines = parent.changedLines
            ruler?.errorLines = parent.errorLines
            if changedBands { tv.needsDisplay = true; ruler?.needsDisplay = true }
        }

        /// Fonts, colours and syntax tokens. Cheap for files of at most 64 KiB, but only redone when something changed.
        func restyle(force: Bool) {
            guard let tv = textView, let storage = tv.textStorage else { return }
            let key = "\(parent.theme.id)|\(parent.isEnv)|\(storage.length)|\(tv.string.hashValue)"
            guard force || key != styledKey else { return }
            styledKey = key

            let theme = parent.theme
            let fg = theme.foregroundRGB.nsColor
            let bg = theme.backgroundRGB.nsColor
            let font = NSFont.monospacedSystemFont(ofSize: 13, weight: .regular)
            let ansi = theme.ansiRGB.map(\.nsColor)
            func color(_ kind: SyntaxKind) -> NSColor {
                switch kind {
                case .key: ansi[5]
                case .string: ansi[2]
                case .number: ansi[3]
                case .keyword: ansi[6]
                case .comment: fg.withAlphaComponent(0.45)
                case .punctuation: fg.withAlphaComponent(0.55)
                }
            }
            tv.backgroundColor = bg
            tv.insertionPointColor = fg
            tv.selectedTextAttributes = [.backgroundColor: fg.withAlphaComponent(0.25)]
            tv.typingAttributes = [.font: font, .foregroundColor: fg]
            (tv.enclosingScrollView)?.backgroundColor = bg
            ruler?.gutterColor = Theme.sidebarNS
            ruler?.numberColor = fg.withAlphaComponent(0.4)
            ruler?.font = NSFont.monospacedDigitSystemFont(ofSize: 11, weight: .regular)

            let text = storage.string
            let tokens = parent.isEnv ? SyntaxHighlighter.env(text) : SyntaxHighlighter.yaml(text)
            storage.beginEditing()
            let full = NSRange(location: 0, length: storage.length)
            storage.setAttributes([.font: font, .foregroundColor: fg], range: full)
            for t in tokens where t.location >= 0 && t.location + t.length <= storage.length {
                storage.addAttribute(.foregroundColor, value: color(t.kind), range: NSRange(location: t.location, length: t.length))
            }
            storage.endEditing()
            tv.bandColors = (changed: ansi[2].withAlphaComponent(0.10), error: ansi[1].withAlphaComponent(0.16))
            ruler?.barColors = (changed: ansi[2], error: ansi[1])
            tv.refreshLineStarts()
            ruler?.lineStarts = tv.lineStarts
            ruler?.needsDisplay = true
            tv.needsDisplay = true
        }
    }
}

/// NSTextView with bands behind chosen lines, 2-space tabs and auto-indent.
final class EditorTextView: NSTextView {
    var changedLines: Set<Int> = []
    var errorLines: Set<Int> = []
    var bandColors: (changed: NSColor, error: NSColor) = (.clear, .clear)
    /// UTF-16 offset where each line starts (always at least one entry).
    private(set) var lineStarts: [Int] = [0]

    func refreshLineStarts() {
        let ns = string as NSString
        var starts = [0]
        var i = 0
        while i < ns.length {
            let r = ns.range(of: "\n", options: [], range: NSRange(location: i, length: ns.length - i))
            if r.location == NSNotFound { break }
            starts.append(r.location + 1)
            i = r.location + 1
        }
        lineStarts = starts
    }

    override func didChangeText() {
        super.didChangeText()
        refreshLineStarts()
        (enclosingScrollView?.verticalRulerView as? LineNumberRuler)?.lineStarts = lineStarts
        enclosingScrollView?.verticalRulerView?.needsDisplay = true
    }

    /// Rect (in this view's coordinates) of the full-width band for a 1-based line.
    func bandRect(forLine line: Int) -> NSRect? {
        guard line >= 1, line <= lineStarts.count, let lm = layoutManager else { return nil }
        let start = lineStarts[line - 1]
        let rect: NSRect
        if start >= (string as NSString).length {
            guard line == lineStarts.count else { return nil }
            let extra = lm.extraLineFragmentRect
            rect = extra.isEmpty ? NSRect(x: 0, y: 0, width: 0, height: 18) : extra
        } else {
            let glyph = lm.glyphIndexForCharacter(at: start)
            rect = lm.lineFragmentRect(forGlyphAt: glyph, effectiveRange: nil)
        }
        let origin = textContainerOrigin
        return NSRect(x: 0, y: rect.minY + origin.y, width: max(bounds.width, enclosingScrollView?.contentSize.width ?? 0), height: rect.height)
    }

    override func drawBackground(in rect: NSRect) {
        super.drawBackground(in: rect)
        for line in changedLines.subtracting(errorLines) {
            if let r = bandRect(forLine: line), r.intersects(rect) { bandColors.changed.setFill(); r.fill() }
        }
        for line in errorLines {
            if let r = bandRect(forLine: line), r.intersects(rect) { bandColors.error.setFill(); r.fill() }
        }
    }

    override func insertTab(_ sender: Any?) {
        insertText("  ", replacementRange: selectedRange())   // YAML does not allow tab characters
    }

    override func insertBacktab(_ sender: Any?) {
        let ns = string as NSString
        let line = ns.lineRange(for: NSRange(location: selectedRange().location, length: 0))
        var remove = 0
        while remove < 2, line.location + remove < ns.length, ns.character(at: line.location + remove) == 32 { remove += 1 }
        guard remove > 0 else { return }
        let range = NSRange(location: line.location, length: remove)
        if shouldChangeText(in: range, replacementString: "") {
            textStorage?.replaceCharacters(in: range, with: "")
            didChangeText()
        }
    }

    override func insertNewline(_ sender: Any?) {
        let ns = string as NSString
        let caret = selectedRange().location
        let line = ns.lineRange(for: NSRange(location: caret, length: 0))
        let before = ns.substring(with: NSRange(location: line.location, length: caret - line.location))
        var indent = String(before.prefix { $0 == " " })
        if before.trimmingCharacters(in: .whitespaces).hasSuffix(":") { indent += "  " }
        super.insertNewline(sender)
        if !indent.isEmpty { insertText(indent, replacementRange: selectedRange()) }
    }
}

/// Line numbers, with a thin bar for changed and failing lines.
final class LineNumberRuler: NSRulerView {
    var lineStarts: [Int] = [0] { didSet { updateThickness() } }
    var changedLines: Set<Int> = []
    var errorLines: Set<Int> = []
    var gutterColor = NSColor.windowBackgroundColor
    var numberColor = NSColor.secondaryLabelColor
    var barColors: (changed: NSColor, error: NSColor) = (.systemGreen, .systemRed)
    var font = NSFont.monospacedDigitSystemFont(ofSize: 11, weight: .regular) { didSet { updateThickness() } }

    override init(scrollView: NSScrollView?, orientation: NSRulerView.Orientation) {
        super.init(scrollView: scrollView, orientation: orientation)
        updateThickness()
    }
    required init(coder: NSCoder) { fatalError("not used") }

    private func updateThickness() {
        let digits = max(3, String(lineStarts.count).count)
        let width = ("0" as NSString).size(withAttributes: [.font: font]).width
        let wanted = ceil(width * CGFloat(digits)) + 24
        if abs(ruleThickness - wanted) > 0.5 { ruleThickness = wanted }
    }

    override func drawHashMarksAndLabels(in rect: NSRect) {
        guard let tv = clientView as? EditorTextView else { return }
        gutterColor.setFill()
        bounds.fill()
        let visible = tv.visibleRect
        let attributes: [NSAttributedString.Key: Any] = [.font: font, .foregroundColor: numberColor]
        for line in 1...lineStarts.count {
            guard let band = tv.bandRect(forLine: line) else { continue }
            guard band.maxY >= visible.minY, band.minY <= visible.maxY else { continue }
            let y = convert(NSPoint(x: 0, y: band.minY), from: tv).y
            if changedLines.contains(line) || errorLines.contains(line) {
                (errorLines.contains(line) ? barColors.error : barColors.changed).setFill()
                NSRect(x: 0, y: y, width: 3, height: band.height).fill()
            }
            let label = NSAttributedString(string: String(line), attributes: attributes)
            let size = label.size()
            label.draw(at: NSPoint(x: ruleThickness - size.width - 12, y: y + (band.height - size.height) / 2))
        }
    }
}
