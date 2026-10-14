import Foundation
import UIKit

@MainActor
enum HTMLText {
    private static let openingTags = try? NSRegularExpression(
        pattern: #"<([A-Za-z][A-Za-z0-9:-]*)((?:"[^"]*"|'[^']*'|[^'">])*)>"#)
    private static let attributes = try? NSRegularExpression(
        pattern: #"\s+([^\s=/'"<>]+)(?:\s*=\s*(?:"([^"]*)"|'([^']*)'|([^\s"'=<>`]+)))?"#)
    private static let unsupportedTags: Set<String> = [
        "script", "style", "iframe", "object", "embed", "link", "meta", "base", "form",
        "svg", "math", "audio", "video", "canvas", "html", "head", "body"
    ]
    private static let unsupportedAttributes: Set<String> = [
        "srcset", "action", "formaction", "contenteditable",
        "data-trilium-original-src", "data-trilium-original-alt"
    ]

    static func escape(_ value: String) -> String {
        value.replacingOccurrences(of: "&", with: "&amp;")
            .replacingOccurrences(of: "<", with: "&lt;")
            .replacingOccurrences(of: ">", with: "&gt;")
            .replacingOccurrences(of: "\"", with: "&quot;")
            .replacingOccurrences(of: "'", with: "&#39;")
    }
    static func paragraphs(_ value: String) -> String {
        value.components(separatedBy: "\n").map { "<p>\(escape($0).isEmpty ? "<br>" : escape($0))</p>" }.joined()
    }
    static func requiresSourceEditing(_ html: String) -> Bool {
        guard let openingTags, let attributes else { return true }
        let string = html as NSString
        for tag in openingTags.matches(in: html, range: NSRange(location: 0, length: string.length)) {
            let name = string.substring(with: tag.range(at: 1)).lowercased()
            if unsupportedTags.contains(name) { return true }
            // Escaped code and quoted attribute values are text, not executable attributes.
            let source = string.substring(with: tag.range(at: 2)) as NSString
            var end = 0
            for attribute in attributes.matches(in: source as String, range: NSRange(location: 0, length: source.length)) {
                guard attribute.range.location == end else { return true }
                end = NSMaxRange(attribute.range)
                let name = source.substring(with: attribute.range(at: 1)).lowercased()
                if unsupportedAttributes.contains(name) ||
                    name.range(of: "^on[a-z]+$", options: .regularExpression) != nil { return true }
                if name == "href" {
                    let quoted = [2, 3].map { attribute.range(at: $0) }.first { $0.location != NSNotFound }
                    guard let quoted else { return true }
                    let href = source.substring(with: quoted).trimmingCharacters(in: .whitespacesAndNewlines).lowercased()
                    if !["https:", "http:", "mailto:", "#", "/"].contains(where: { href.hasPrefix($0) }) { return true }
                }
            }
            let remainder = source.substring(from: end).trimmingCharacters(in: .whitespacesAndNewlines)
            if !remainder.isEmpty && remainder != "/" { return true }
        }
        let remaining = openingTags.stringByReplacingMatches(
            in: html, range: NSRange(location: 0, length: string.length), withTemplate: "")
        return remaining.range(of: "<[A-Za-z]", options: .regularExpression) != nil
    }
    static func plainText(_ html: String) -> String {
        // Avoid NSAttributedString's HTML importer: it can fetch remote resources.
        let normalized = html.replacingOccurrences(of: "(?i)<p>\\s*<br\\s*/?>\\s*</p>", with: "<p></p>", options: .regularExpression)
        let breaks = normalized.replacingOccurrences(of: "(?i)<br\\s*/?>|</(?:p|div|h[1-6]|li|tr)>", with: "\n", options: .regularExpression)
        let stripped = breaks.replacingOccurrences(of: "(?is)<(script|style)[^>]*>.*?</\\1>", with: "", options: .regularExpression)
            .replacingOccurrences(of: "<[^>]+>", with: "", options: .regularExpression)
        return stripped.replacingOccurrences(of: "&nbsp;", with: " ")
            .replacingOccurrences(of: "&lt;", with: "<").replacingOccurrences(of: "&gt;", with: ">")
            .replacingOccurrences(of: "&quot;", with: "\"").replacingOccurrences(of: "&#39;", with: "'")
            .replacingOccurrences(of: "&amp;", with: "&").trimmingCharacters(in: .whitespacesAndNewlines)
    }
}

@MainActor
enum MarkdownTable {
    static let template = "| 列 1 | 列 2 |\n| --- | --- |\n| 内容 | 内容 |"

    static func html(from source: String) throws -> String {
        let lines = source.trimmingCharacters(in: .whitespacesAndNewlines)
            .components(separatedBy: .newlines)
        guard lines.count >= 2, !lines.contains(where: { $0.trimmingCharacters(in: .whitespaces).isEmpty }) else {
            throw UserFacingError(message: "请输入表头、分隔行和可选的数据行，表格内不能有空行。")
        }
        let header = cells(in: lines[0])
        let delimiters = cells(in: lines[1])
        guard !header.isEmpty, header.count == delimiters.count,
              delimiters.allSatisfy({ $0.range(of: "^:?-+:?$", options: .regularExpression) != nil }) else {
            throw UserFacingError(message: "表头与分隔行的列数必须一致，分隔行请使用 ---、:---、:---: 或 ---:。")
        }
        let alignments = delimiters.map { value -> String? in
            if value.hasPrefix(":") { return value.hasSuffix(":") ? "center" : "left" }
            return value.hasSuffix(":") ? "right" : nil
        }
        func row(_ values: [String], tag: String) throws -> String {
            let cells = try header.indices.map { index in
                let alignment = alignments[index].map { " style=\"text-align:\($0)\"" } ?? ""
                let value = index < values.count ? values[index] : ""
                return "<\(tag)\(alignment)>\(try inlineHTML(value))</\(tag)>"
            }.joined()
            return "<tr>\(cells)</tr>"
        }
        let body = try lines.dropFirst(2).map { try row(cells(in: $0), tag: "td") }.joined()
        return "<table><thead>\(try row(header, tag: "th"))</thead>\(body.isEmpty ? "" : "<tbody>\(body)</tbody>")</table>"
    }

    private static func cells(in line: String) -> [String] {
        let text = line.trimmingCharacters(in: .whitespaces)
        var result = [String]()
        var cell = ""
        var escaped = false
        var endsWithPipe = false
        for character in text {
            endsWithPipe = false
            if escaped {
                // GFM unescapes pipes before interpreting inline Markdown, including code spans.
                if character != "|" { cell.append("\\") }
                cell.append(character)
                escaped = false
            } else if character == "\\" {
                escaped = true
            } else if character == "|" {
                result.append(cell.trimmingCharacters(in: .whitespaces))
                cell = ""
                endsWithPipe = true
            } else {
                cell.append(character)
            }
        }
        if escaped { cell.append("\\") }
        result.append(cell.trimmingCharacters(in: .whitespaces))
        if text.hasPrefix("|") { result.removeFirst() }
        if endsWithPipe { result.removeLast() }
        return result
    }

    private static func inlineHTML(_ source: String) throws -> String {
        // Foundation handles inline Markdown; only the explicit line-break tag is accepted as HTML.
        let normalized = inlineParts(source).joined(separator: "\n")
        let text = try AttributedString(markdown: normalized, options: .init(interpretedSyntax: .inlineOnlyPreservingWhitespace))
        return MarkdownHTML.inlineHTML(text, preserveLineBreaks: true)
    }

    private static func inlineParts(_ source: String) -> [String] {
        var parts = [""]
        var index = source.startIndex
        var codeDelimiter = 0
        while index < source.endIndex {
            let character = source[index]
            if character == "\\" {
                parts[parts.count - 1].append(character)
                index = source.index(after: index)
                if index < source.endIndex {
                    parts[parts.count - 1].append(source[index])
                    index = source.index(after: index)
                }
                continue
            }
            if character == "`" {
                let start = index
                while index < source.endIndex && source[index] == "`" { index = source.index(after: index) }
                let count = source.distance(from: start, to: index)
                if codeDelimiter == 0 { codeDelimiter = count }
                else if codeDelimiter == count { codeDelimiter = 0 }
                parts[parts.count - 1].append(contentsOf: source[start..<index])
                continue
            }
            if codeDelimiter == 0, character == "<",
               let range = source[index...].range(of: "(?i)^<br\\s*/?>", options: .regularExpression) {
                parts.append("")
                index = range.upperBound
            } else {
                parts[parts.count - 1].append(character)
                index = source.index(after: index)
            }
        }
        return parts
    }
}
