import Foundation

@MainActor
enum MarkdownHTML {
    static func html(from source: String) -> String {
        guard let text = try? AttributedString(markdown: source, options: .init(interpretedSyntax: .full)) else {
            return HTMLText.paragraphs(source)
        }
        var html = ""
        var stack: [PresentationIntent.IntentType] = []
        for run in text.runs {
            // Foundation lists the innermost block first; HTML opens its ancestors first.
            let blocks = Array((run.presentationIntent?.components ?? []).reversed())
            let shared = zip(stack, blocks).prefix { $0.0.identity == $0.1.identity }.count
            html += closingTags(stack, from: shared)
            for index in shared..<blocks.count {
                html += openingTag(blocks[index].kind, descendants: Array(blocks.dropFirst(index + 1)),
                                   ancestors: Array(blocks.prefix(index)))
            }
            stack = blocks
            let value = String(text[run.range].characters)
            if blocks.contains(where: { if case .thematicBreak = $0.kind { return true }; return false }) {
                continue
            }
            if blocks.contains(where: { if case .codeBlock = $0.kind { return true }; return false }) {
                html += HTMLText.escape(value)
            } else {
                html += inlineHTML(AttributedString(text[run.range]))
            }
        }
        html += closingTags(stack, from: 0)
        return html
    }

    static func inlineHTML(_ text: AttributedString, preserveLineBreaks: Bool = false) -> String {
        text.runs.map { run in
            let intent = run.inlinePresentationIntent ?? []
            var html = HTMLText.escape(String(text[run.range].characters))
            if intent.contains(.lineBreak) { html = "<br>" }
            else if intent.contains(.softBreak), !preserveLineBreaks { html = " " }
            else { html = html.replacingOccurrences(of: "\n", with: "<br>") }
            if intent.contains(.code) { html = "<code>\(html)</code>" }
            if intent.contains(.stronglyEmphasized) { html = "<strong>\(html)</strong>" }
            if intent.contains(.emphasized) { html = "<em>\(html)</em>" }
            if intent.contains(.strikethrough) { html = "<del>\(html)</del>" }
            if let link = run.link, isSafeLink(link) {
                html = "<a href=\"\(HTMLText.escape(link.absoluteString))\">\(html)</a>"
            }
            return html
        }.joined()
    }

    static func messageHTML(_ message: ChatMessage) -> String {
        message.role == "assistant" ? html(from: message.content) : HTMLText.paragraphs(message.content)
    }

    private static func isSafeLink(_ url: URL) -> Bool {
        ["http", "https", "mailto"].contains(url.scheme?.lowercased() ?? "") ||
            url.absoluteString.hasPrefix("#") || url.absoluteString.hasPrefix("/")
    }

    private static func openingTag(_ kind: PresentationIntent.Kind,
                                   descendants: [PresentationIntent.IntentType],
                                   ancestors: [PresentationIntent.IntentType]) -> String {
        switch kind {
        case .paragraph: return "<p>"
        case .header(let level): return "<h\(level)>"
        case .blockQuote: return "<blockquote>"
        case .codeBlock(let language):
            let attribute = language.map { " class=\"language-\(HTMLText.escape($0))\"" } ?? ""
            return "<pre><code\(attribute)>"
        case .unorderedList: return "<ul>"
        case .orderedList:
            let ordinal = descendants.compactMap { block -> Int? in
                if case .listItem(let ordinal) = block.kind { return ordinal }
                return nil
            }.first ?? 1
            return ordinal == 1 ? "<ol>" : "<ol start=\"\(ordinal)\">"
        case .listItem: return "<li>"
        case .thematicBreak: return "<hr>"
        case .table: return "<table>"
        case .tableHeaderRow, .tableRow: return "<tr>"
        case .tableCell(let index):
            let header = ancestors.contains { if case .tableHeaderRow = $0.kind { return true }; return false }
            var alignment = ""
            for ancestor in ancestors {
                if case .table(let columns) = ancestor.kind, columns.indices.contains(index) {
                    switch columns[index].alignment {
                    case .left: alignment = "left"
                    case .center: alignment = "center"
                    case .right: alignment = "right"
                    @unknown default: break
                    }
                }
            }
            let style = alignment.isEmpty ? "" : " style=\"text-align:\(alignment)\""
            return "<\(header ? "th" : "td")\(style)>"
        @unknown default: return ""
        }
    }

    private static func closingTags(_ blocks: [PresentationIntent.IntentType], from index: Int) -> String {
        let header = blocks.contains { if case .tableHeaderRow = $0.kind { return true }; return false }
        return blocks.dropFirst(index).reversed().map { closingTag($0.kind, header: header) }.joined()
    }

    private static func closingTag(_ kind: PresentationIntent.Kind, header: Bool) -> String {
        switch kind {
        case .paragraph: return "</p>"
        case .header(let level): return "</h\(level)>"
        case .blockQuote: return "</blockquote>"
        case .codeBlock: return "</code></pre>"
        case .unorderedList: return "</ul>"
        case .orderedList: return "</ol>"
        case .listItem: return "</li>"
        case .table: return "</table>"
        case .tableHeaderRow, .tableRow: return "</tr>"
        case .tableCell: return header ? "</th>" : "</td>"
        case .thematicBreak: return ""
        @unknown default: return ""
        }
    }
}
