import Foundation
import UIKit

@MainActor
enum HTMLText {
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
        let unsupported = "(?i)<(?:script|style|iframe|object|embed|link|meta|base|form|svg|math|audio|video|canvas|html|head|body)\\b|\\s(?:on[a-z]+|srcset|action|formaction|contenteditable|data-trilium-original-src|data-trilium-original-alt)\\s*=|href\\s*=\\s*[^\\\"'\\s>]"
        if html.range(of: unsupported, options: .regularExpression) != nil { return true }
        guard let regex = try? NSRegularExpression(pattern: "(?i)href\\s*=\\s*[\\\"']([^\\\"']*)[\\\"']") else { return true }
        let string = html as NSString
        return regex.matches(in: html, range: NSRange(location: 0, length: string.length)).contains { match in
            let href = string.substring(with: match.range(at: 1)).trimmingCharacters(in: .whitespacesAndNewlines).lowercased()
            return !["https:", "http:", "mailto:", "#", "/"].contains(where: { href.hasPrefix($0) })
        }
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
