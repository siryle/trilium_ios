import XCTest
@testable import TriliumPocket

@MainActor
final class MarkdownRenderingTests: XCTestCase {
    func testHeadingsParagraphsAndInlineFormatting() {
        let html = MarkdownHTML.html(from: """
        # Heading

        **Bold** and *italic*, ~~deleted~~, `a < b`.

        Another paragraph with [Link](https://example.com/?a=1&b=2).
        """)
        XCTAssertTrue(html.contains("<h1>Heading</h1>"))
        XCTAssertTrue(html.contains("<strong>Bold</strong>"))
        XCTAssertTrue(html.contains("<em>italic</em>"))
        XCTAssertTrue(html.contains("<del>deleted</del>"))
        XCTAssertTrue(html.contains("<code>a &lt; b</code>"))
        XCTAssertTrue(html.contains("<p>Another paragraph"))
        XCTAssertTrue(html.contains("href=\"https://example.com/?a=1&amp;b=2\""))
        XCTAssertFalse(html.contains("**"))
    }

    func testNestedListsQuotesAndOrderedListStart() {
        let html = MarkdownHTML.html(from: """
        > Quote
        >
        > - First
        >   - Nested
        > - Second

        3. Third
        4. Fourth
        """)
        XCTAssertTrue(html.contains("<blockquote>"))
        XCTAssertTrue(html.contains("<ul><li>"))
        XCTAssertTrue(html.contains("Nested"))
        XCTAssertTrue(html.contains("</ul></li>"))
        XCTAssertTrue(html.contains("</blockquote>"))
        XCTAssertTrue(html.contains("<ol start=\"3\"><li>"))
        XCTAssertTrue(html.hasSuffix("</li></ol>"))
    }

    func testCodeBlockPreservesNewlinesAndEscapesHTML() {
        let html = MarkdownHTML.html(from: """
        ```html
        <script>alert("hello")</script>
        **literal** & more
        ```
        """)
        XCTAssertTrue(html.contains("<pre><code class=\"language-html\">"))
        XCTAssertTrue(html.contains("&lt;script&gt;alert(&quot;hello&quot;)&lt;/script&gt;\n"))
        XCTAssertTrue(html.contains("**literal** &amp; more"))
        XCTAssertFalse(html.contains("<script>"))
        XCTAssertFalse(html.contains("<strong>"))
        XCTAssertTrue(html.hasSuffix("</code></pre>"))
    }

    func testTablesHaveMatchingCellTagsAlignmentAndInlineFormatting() {
        let html = MarkdownHTML.html(from: """
        | Name | Size |
        | :--- | ---: |
        | **Data** | `a\\|b` |
        | More | 100 |
        """)
        XCTAssertTrue(html.contains("<table>"))
        XCTAssertTrue(html.contains("<th style=\"text-align:left\">Name</th>"))
        XCTAssertTrue(html.contains("<th style=\"text-align:right\">Size</th>"))
        XCTAssertTrue(html.contains("<td style=\"text-align:left\"><strong>Data</strong></td>"))
        XCTAssertTrue(html.contains("<code>a|b</code>"))
        XCTAssertTrue(html.hasSuffix("</tr></table>"))
        XCTAssertFalse(html.contains("</td></tr><tr><th"))
    }

    func testConsecutiveBlocksDoNotMergeAndHardBreaksRemainVisible() {
        let html = MarkdownHTML.html(from: """
        ## First
        ## Second

        Line one
        line two

        Hard break\\
        next line
        """)
        XCTAssertTrue(html.contains("<h2>First</h2>"))
        XCTAssertTrue(html.contains("<h2>Second</h2>"))
        XCTAssertTrue(html.contains("Line one line two"))
        XCTAssertTrue(html.contains("Hard break<br>next line"))
    }

    func testUnsafeLinksAndRawHTMLCannotBecomeExecutableMarkup() {
        let html = MarkdownHTML.html(from: """
        [Unsafe](javascript:alert)
        [Safe](https://example.com)

        `<img src=x onerror=alert(1)>`
        """)
        XCTAssertFalse(html.contains("href=\"javascript:"))
        XCTAssertTrue(html.contains("<a href=\"https://example.com\">Safe</a>"))
        XCTAssertTrue(html.contains("&lt;img src=x onerror=alert(1)&gt;"))
        XCTAssertFalse(html.contains("<img"))
        XCTAssertFalse(HTMLText.requiresSourceEditing(html))
    }

    func testSavedAssistantMessageUsesSameHTMLAsPreviewWhileUserTextIsLiteral() {
        let source = "# Heading\n\n- Item\n\n**Bold**"
        let assistant = MarkdownHTML.messageHTML(ChatMessage(role: "assistant", content: source))
        XCTAssertTrue(assistant.contains("<h1>Heading</h1>"))
        XCTAssertTrue(assistant.contains("<ul><li>"))
        XCTAssertTrue(assistant.contains("<strong>Bold</strong>"))
        XCTAssertFalse(HTMLText.requiresSourceEditing(assistant))
        let user = MarkdownHTML.messageHTML(ChatMessage(role: "user", content: source))
        XCTAssertEqual(user, HTMLText.paragraphs(source))
        XCTAssertTrue(user.contains("**Bold**"))
        XCTAssertFalse(user.contains("<h1>"))
    }

    func testIncompleteStreamingMarkdownStillKeepsTextAndBalancedBlocks() {
        for source in ["# Partial", "**unfinished", "- First\n  - Partial", "```swift\nlet value = 1"] {
            let html = MarkdownHTML.html(from: source)
            XCTAssertFalse(html.isEmpty)
            XCTAssertFalse(HTMLText.plainText(html).isEmpty)
            XCTAssertEqual(html.components(separatedBy: "<pre>").count,
                           html.components(separatedBy: "</pre>").count)
            XCTAssertEqual(html.components(separatedBy: "<li>").count,
                           html.components(separatedBy: "</li>").count)
        }
        XCTAssertEqual(MarkdownHTML.html(from: ""), "")
    }
}
