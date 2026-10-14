import Foundation
import XCTest
@testable import TriliumPocket

final class CoreTests: XCTestCase {
    func testServerURLPreservesReverseProxyPathAndTrimsWhitespace() throws {
        let url = try APIClient.validatedURL("  https://notes.example.com:8443/trilium/\n", allowHTTP: false)

        XCTAssertEqual(url.scheme, "https")
        XCTAssertEqual(url.host, "notes.example.com")
        XCTAssertEqual(url.port, 8443)
        XCTAssertEqual(url.absoluteString, "https://notes.example.com:8443/trilium/")
    }

    func testHTTPRequiresExplicitOptIn() throws {
        XCTAssertThrowsError(try APIClient.validatedURL("http://192.168.1.12:8080", allowHTTP: false))
        let url = try APIClient.validatedURL("http://192.168.1.12:8080", allowHTTP: true)
        XCTAssertEqual(url.scheme, "http")
        XCTAssertEqual(url.host, "192.168.1.12")
    }

    func testServerURLRejectsCredentialsAndNonBaseAddresses() {
        let invalidAddresses = [
            "notes.example.com",
            "/trilium",
            "ftp://notes.example.com",
            "https://user:secret@notes.example.com",
            "https://user@notes.example.com",
            "https://notes.example.com?token=secret",
            "https://notes.example.com/#root/note1234"
        ]

        for address in invalidAddresses {
            XCTAssertThrowsError(try APIClient.validatedURL(address, allowHTTP: true), address)
        }
    }

    func testClonedNoteRetainsDistinctTreePlacementsAndNullablePrefix() throws {
        let note = try JSONDecoder().decode(Note.self, from: Self.noteJSON)
        let branches = try JSONDecoder().decode([Branch].self, from: Data("""
        [
          {"branchId":"projects_sharedNote","noteId":"sharedNote","parentNoteId":"projects",
           "prefix":null,"notePosition":20,"isExpanded":false,"utcDateModified":"2026-09-28 12:00:00.000Z"},
          {"branchId":"archive_sharedNote","noteId":"sharedNote","parentNoteId":"archive",
           "prefix":"Reference","notePosition":10,"isExpanded":true,"utcDateModified":"2026-09-28 12:00:00.000Z"}
        ]
        """.utf8))
        let placements = branches.map { TreeEntry(branch: $0, note: note) }

        XCTAssertEqual(note.parentNoteIds, ["projects", "archive"])
        XCTAssertEqual(Set(placements.map(\.note.id)), Set(["sharedNote"]))
        XCTAssertEqual(Set(placements.map(\.id)).count, 2)
        XCTAssertNil(branches[0].prefix)
        XCTAssertEqual(placements[0].title, "Shared research")
        XCTAssertEqual(placements[1].title, "Reference - Shared research")
    }

    func testNewServerNoteTypesRemainReadableWithoutBecomingEditable() throws {
        let object = try XCTUnwrap(JSONSerialization.jsonObject(with: Self.noteJSON) as? [String: Any])
        var futureNote = object
        futureNote["type"] = "futureDiagram"
        futureNote["mime"] = "application/json"
        let data = try JSONSerialization.data(withJSONObject: futureNote)
        let note = try JSONDecoder().decode(Note.self, from: data)

        XCTAssertEqual(note.type, "futureDiagram")
        XCTAssertEqual(note.title, "Shared research")
        XCTAssertFalse(note.isEditable)
    }

    func testProtectedTextNoteCannotBeEdited() throws {
        var object = try XCTUnwrap(JSONSerialization.jsonObject(with: Self.noteJSON) as? [String: Any])
        object["isProtected"] = true
        object["title"] = "[protected]"
        let note = try JSONDecoder().decode(Note.self, from: JSONSerialization.data(withJSONObject: object))

        XCTAssertFalse(note.isEditable)
        XCTAssertEqual(note.icon, "lock")
    }

    func testSearchAndCreateDecodeDifferentETAPIResponseEnvelopes() throws {
        let noteObject = try JSONSerialization.jsonObject(with: Self.noteJSON)
        let searchData = try JSONSerialization.data(withJSONObject: ["results": [noteObject], "debugInfo": ["extra": true]])
        let search = try JSONDecoder().decode(SearchResponse.self, from: searchData)
        let createData = try JSONSerialization.data(withJSONObject: [
            "note": noteObject,
            "branch": ["branchId": "root_sharedNote", "noteId": "sharedNote", "parentNoteId": "root",
                       "prefix": NSNull(), "notePosition": 10]
        ])
        let created = try JSONDecoder().decode(CreatedNote.self, from: createData)

        XCTAssertEqual(search.results.map(\.noteId), ["sharedNote"])
        XCTAssertEqual(created.note.noteId, created.branch.noteId)
        XCTAssertEqual(created.branch.parentNoteId, "root")
    }

    func testSuccessfulContentAndEmptyUpdateResponsesPassStatusValidation() throws {
        let url = try XCTUnwrap(URL(string: "https://notes.example.com/etapi/notes/sharedNote/content"))
        let contentResponse = try XCTUnwrap(HTTPURLResponse(url: url, statusCode: 200, httpVersion: nil,
                                                          headerFields: ["Content-Type": "text/html"]))
        let updateResponse = try XCTUnwrap(HTTPURLResponse(url: url, statusCode: 204, httpVersion: nil, headerFields: nil))

        XCTAssertNoThrow(try APIClient.check(contentResponse, data: Data("<p>Saved</p>".utf8)))
        XCTAssertNoThrow(try APIClient.check(updateResponse, data: Data()))
    }

    func testRedirectsAndProxyErrorsCannotBeMistakenForNoteContent() throws {
        let url = try XCTUnwrap(URL(string: "https://notes.example.com/etapi/notes/sharedNote/content"))
        for status in [302, 401, 404, 413, 429, 502] {
            let response = try XCTUnwrap(HTTPURLResponse(url: url, statusCode: status, httpVersion: nil,
                                                       headerFields: ["Content-Type": "text/html"]))
            XCTAssertThrowsError(try APIClient.check(response, data: Data("<html>Gateway error</html>".utf8))) { error in
                XCTAssertFalse(error.localizedDescription.isEmpty)
            }
        }
    }

    @MainActor
    func testPlainTextCaptureEscapesMarkupAndPreservesBlankParagraphs() async {
        let capture = "Fish & chips <script>\"quoted\" 'text'</script>\n\n第二行"
        let html = HTMLText.paragraphs(capture)

        XCTAssertFalse(html.contains("<script>"))
        XCTAssertTrue(html.contains("&lt;script&gt;"))
        XCTAssertTrue(html.contains("&amp;"))
        XCTAssertTrue(html.contains("&quot;quoted&quot;"))
        XCTAssertTrue(html.contains("&#39;text&#39;"))
        XCTAssertTrue(html.contains("<p><br></p>"))
        XCTAssertEqual(HTMLText.plainText(html), capture)
    }

    @MainActor
    func testMarkdownTableSupportsAlignmentAndNormalizesBodyColumnCounts() throws {
        let html = try MarkdownTable.html(from: """
        | 名称 | 容量 | 说明 |
        | :--- | :---: | ---: |
        | EFI | 500M |
        | Windows | 100G | 系统 | ignored |
        """)
        XCTAssertTrue(html.contains("<th style=\"text-align:left\">名称</th>"))
        XCTAssertTrue(html.contains("<th style=\"text-align:center\">容量</th>"))
        XCTAssertTrue(html.contains("<th style=\"text-align:right\">说明</th>"))
        XCTAssertTrue(html.contains("<td style=\"text-align:right\"></td>"))
        XCTAssertFalse(html.contains("ignored"))
    }

    @MainActor
    func testMarkdownTablePreservesEscapedPipesAndInlineFormatting() throws {
        let html = try MarkdownTable.html(from: """
        Name | Value
        --- | ---
        **Bold** and *italic* | `a\\|b`
        [Link](https://example.com) | ~~Deleted~~
        """)
        XCTAssertTrue(html.contains("<strong>Bold</strong>"))
        XCTAssertTrue(html.contains("<em>italic</em>"))
        XCTAssertTrue(html.contains("<code>a|b</code>"))
        XCTAssertTrue(html.contains("<a href=\"https://example.com\">Link</a>"))
        XCTAssertTrue(html.contains("<del>Deleted</del>"))
    }

    @MainActor
    func testMarkdownTableDistinguishesLineBreaksFromLiteralAndCodeMarkup() throws {
        let html = try MarkdownTable.html(from: """
        | Break | Literal | Code |
        | --- | --- | --- |
        | First<br>Next | \\<br\\> | `<br>` |
        """)
        XCTAssertTrue(html.contains("<td>First<br>Next</td>"))
        XCTAssertTrue(html.contains("<td>&lt;br&gt;</td>"))
        XCTAssertTrue(html.contains("<code>&lt;br&gt;</code>"))
    }

    @MainActor
    func testMarkdownTableRejectsMalformedHeadersAndUnsafeLinks() throws {
        for source in ["", "| A |", "| A | B |\n| --- |", "| A |\n| invalid |", "| A |\n| --- |\n\n| B |"] {
            XCTAssertThrowsError(try MarkdownTable.html(from: source))
        }
        let html = try MarkdownTable.html(from: "| A |\n| --- |\n| [Unsafe](javascript:alert) |")
        XCTAssertFalse(html.contains("href="))
        XCTAssertTrue(html.contains("Unsafe"))
        XCTAssertNoThrow(try MarkdownTable.html(from: "| A |\n| --- |"))
    }

    @MainActor
    func testHTMLPreviewPreservesReadableBlocksAndExcludesExecutableText() async {
        let html = """
        <style>body { display: none; }</style><h2>Heading</h2><p>A &amp; B<br>Next &lt;line&gt;</p><script>alert('hidden')</script><ul><li>First</li><li>Second</li></ul>
        """

        XCTAssertEqual(HTMLText.plainText(html), "Heading\nA & B\nNext <line>\nFirst\nSecond")
    }

    @MainActor
    func testHTMLToPlainTextDecodesEscapedEntityOnce() async {
        XCTAssertEqual(HTMLText.plainText("<p>&amp;lt;literal&amp;gt; &nbsp; &#39;quoted&#39;</p>"),
                       "&lt;literal&gt;   'quoted'")
        XCTAssertEqual(HTMLText.paragraphs(""), "<p><br></p>")
        XCTAssertEqual(HTMLText.plainText("<p><br></p>"), "")
    }

    func testContentRequestPreservesSubpathAndUsesRawToken() async throws {
        let html = "<p>你好 &amp; hello</p>"
        let client = try makeClient { request in
            XCTAssertEqual(request.httpMethod, "GET")
            XCTAssertEqual(request.url?.path, "/trilium/etapi/notes/sharedNote/content")
            XCTAssertEqual(request.value(forHTTPHeaderField: "Authorization"), "token-id_secret")
            return (200, Data(html.utf8))
        }
        defer { dispose(client) }

        let content = try await client.content("sharedNote")
        XCTAssertEqual(content, html)
    }

    func testHTMLUpdateSendsRawUTF8AndAcceptsEmpty204() async throws {
        let html = "<p>Quotes: \"hello\" &amp; 中文</p>"
        let client = try makeClient { request in
            XCTAssertEqual(request.httpMethod, "PUT")
            XCTAssertEqual(request.url?.path, "/trilium/etapi/notes/sharedNote/content")
            XCTAssertEqual(request.value(forHTTPHeaderField: "Content-Type"), "text/plain; charset=utf-8")
            XCTAssertEqual(try Self.body(of: request), Data(html.utf8))
            return (204, Data())
        }
        defer { dispose(client) }

        try await client.updateContent("sharedNote", content: html, mime: "text/html")
    }

    func testCreateSendsWritableFieldsAndDecodesCreatedNote() async throws {
        let response = try JSONSerialization.data(withJSONObject: [
            "note": JSONSerialization.jsonObject(with: Self.noteJSON),
            "branch": ["branchId": "root_sharedNote", "noteId": "sharedNote", "parentNoteId": "root",
                       "prefix": NSNull(), "notePosition": 10]
        ])
        let client = try makeClient { request in
            XCTAssertEqual(request.httpMethod, "POST")
            XCTAssertEqual(request.url?.path, "/trilium/etapi/create-note")
            XCTAssertEqual(request.value(forHTTPHeaderField: "Content-Type"), "application/json")
            let body = try XCTUnwrap(JSONSerialization.jsonObject(with: Self.body(of: request)) as? [String: Any])
            XCTAssertEqual(body["parentNoteId"] as? String, "root")
            XCTAssertEqual(body["title"] as? String, "Shared research")
            XCTAssertEqual(body["type"] as? String, "text")
            XCTAssertEqual(body["content"] as? String, "<p>Research</p>")
            XCTAssertNil(body["branchId"])
            XCTAssertNil(body["isProtected"])
            XCTAssertNil(body["childNoteIds"])
            XCTAssertNil(body["blobId"])
            return (201, response)
        }
        defer { dispose(client) }

        let note = try await client.create(parentID: "root", title: "Shared research", content: "<p>Research</p>")
        XCTAssertEqual(note.noteId, "sharedNote")
    }

    func testSearchEncodesSpecialCharactersWithoutAddingQueryFields() async throws {
        let query = "towers #book=\"A&B\" + 中文"
        let client = try makeClient { request in
            XCTAssertEqual(request.url?.path, "/trilium/etapi/notes")
            let url = try XCTUnwrap(request.url)
            let components = try XCTUnwrap(URLComponents(url: url, resolvingAgainstBaseURL: false))
            let searchItems = components.queryItems?.filter { $0.name == "search" }
            XCTAssertEqual(searchItems?.count, 1)
            XCTAssertEqual(searchItems?.first?.value, query)
            XCTAssertNil(components.fragment)
            // Express query parsing treats an unescaped plus as a space.
            XCTAssertTrue(components.percentEncodedQuery?.contains("%2B") ?? false)
            XCTAssertFalse(components.queryItems?.contains { $0.name == "B" } ?? true)
            return (200, Data("{\"results\":[]}".utf8))
        }
        defer { dispose(client) }

        let notes = try await client.search(query)
        XCTAssertTrue(notes.isEmpty)
    }

    func testDailyNoteUsesLocalGregorianCalendarDate() async throws {
        var calendar = Calendar(identifier: .gregorian)
        calendar.timeZone = .current
        // December 31 can belong to the following ISO week-year.
        let date = try XCTUnwrap(calendar.date(from: DateComponents(year: 2018, month: 12, day: 31, hour: 12)))
        let noteJSON = Self.noteJSON
        let client = try makeClient { request in
            XCTAssertEqual(request.httpMethod, "GET")
            XCTAssertEqual(request.url?.path, "/trilium/etapi/calendar/days/2018-12-31")
            return (200, noteJSON)
        }
        defer { dispose(client) }

        let note = try await client.dayNote(date)
        XCTAssertEqual(note.noteId, "sharedNote")
    }

    func testAIModelsUseProviderSubpathAndCurrentKeyWithoutSelectedModel() async throws {
        let fixture = try makeClient { request in
            XCTAssertEqual(request.httpMethod, "GET")
            XCTAssertEqual(request.url?.path, "/trilium/models")
            XCTAssertEqual(request.value(forHTTPHeaderField: "Authorization"), "Bearer provider-key")
            XCTAssertEqual(request.value(forHTTPHeaderField: "Accept"), "application/json")
            return (200, Data("""
            {"object":"list","data":[
                {"id":"z-model","object":"model"},{"id":"a-model"},{"id":"z-model"},{"id":"  "},
                {"id":" a-model\\n"}
            ]}
            """.utf8))
        }
        defer { dispose(fixture) }
        let client = try AIClient(address: fixture.baseURL.absoluteString, apiKey: " provider-key\n",
                                  allowHTTP: false, session: fixture.session)

        let identifiers = try await client.models()
        XCTAssertEqual(identifiers, ["a-model", "z-model"])
    }

    func testAIModelListAllowsProvidersWithoutAPIKeysAndEmptyLists() async throws {
        let fixture = try makeClient { request in
            XCTAssertNil(request.value(forHTTPHeaderField: "Authorization"))
            return (200, Data("{\"data\":[]}".utf8))
        }
        defer { dispose(fixture) }
        let client = try AIClient(address: fixture.baseURL.absoluteString, apiKey: " \n",
                                  allowHTTP: false, session: fixture.session)

        let identifiers = try await client.models()
        XCTAssertTrue(identifiers.isEmpty)
    }

    func testAIModelListReportsAuthenticationErrorsAndRedirects() async throws {
        for status in [302, 401, 403, 404, 429, 500] {
            let fixture = try makeClient { _ in
                (status, Data("{\"error\":{\"message\":\"Provider detail\"}}".utf8))
            }
            defer { dispose(fixture) }
            let client = try AIClient(address: fixture.baseURL.absoluteString, apiKey: "key",
                                      allowHTTP: false, session: fixture.session)
            do {
                _ = try await client.models()
                XCTFail("HTTP \(status) must fail")
            } catch {
                if status == 302 {
                    XCTAssertTrue(error.localizedDescription.contains("重定向"))
                } else {
                    XCTAssertTrue(error.localizedDescription.contains("HTTP \(status)"))
                    XCTAssertTrue(error.localizedDescription.contains("Provider detail"))
                }
            }
        }
    }

    func testAIModelListRejectsMalformedSuccessResponses() async throws {
        for payload in ["<html>Gateway</html>", "{}", "{\"data\":[{}]}", "{\"data\":null}"] {
            let fixture = try makeClient { _ in (200, Data(payload.utf8)) }
            defer { dispose(fixture) }
            let client = try AIClient(address: fixture.baseURL.absoluteString, apiKey: "key",
                                      allowHTTP: false, session: fixture.session)
            do {
                _ = try await client.models()
                XCTFail("Malformed model list must fail")
            } catch {
                XCTAssertTrue(error.localizedDescription.contains("无法解析的模型列表"))
            }
        }
    }

    func testAIChatRequiresManualModelSelectionBeforeSendingRequest() async throws {
        let fixture = try makeClient { _ in
            XCTFail("No request should be sent before choosing a model")
            return (200, Data())
        }
        defer { dispose(fixture) }
        XCTAssertThrowsError(try AIClient(address: fixture.baseURL.absoluteString, apiKey: "key", model: " \n",
                                         allowHTTP: false, session: fixture.session)) { error in
            XCTAssertTrue(error.localizedDescription.contains("选择 AI 模型"))
        }
        let client = try AIClient(address: fixture.baseURL.absoluteString, apiKey: "key",
                                  allowHTTP: false, session: fixture.session)
        do {
            try await client.stream(messages: []) { _ in XCTFail("No text should be delivered") }
            XCTFail("Chat without a selected model must fail")
        } catch {
            XCTAssertTrue(error.localizedDescription.contains("选择 AI 模型"))
        }
        XCTAssertTrue(ServerConfiguration().aiModel.isEmpty)
    }

    private func makeClient(handler: @escaping ContractURLProtocol.Handler) throws -> APIClient {
        let host = "test-\(UUID().uuidString.lowercased()).example.com"
        let url = try XCTUnwrap(URL(string: "https://\(host)/trilium/"))
        ContractURLProtocol.registry.register(host: host, handler: handler)
        let configuration = URLSessionConfiguration.ephemeral
        configuration.protocolClasses = [ContractURLProtocol.self]
        let session = URLSession(configuration: configuration)
        return APIClient(baseURL: url, token: "token-id_secret", session: session)
    }

    private func dispose(_ client: APIClient) {
        client.session.invalidateAndCancel()
        if let host = client.baseURL.host { ContractURLProtocol.registry.remove(host: host) }
    }

    private static func body(of request: URLRequest) throws -> Data {
        if let data = request.httpBody { return data }
        let stream = try XCTUnwrap(request.httpBodyStream)
        stream.open()
        defer { stream.close() }
        var data = Data()
        var buffer = [UInt8](repeating: 0, count: 4096)
        while true {
            let count = stream.read(&buffer, maxLength: buffer.count)
            if count == 0 { return data }
            if count < 0 { throw stream.streamError ?? URLError(.cannotDecodeRawData) }
            data.append(contentsOf: buffer.prefix(count))
        }
    }

    private static let noteJSON = Data("""
    {
      "noteId":"sharedNote","title":"Shared research","type":"text","mime":"text/html",
      "isProtected":false,"blobId":"contentHash",
      "parentNoteIds":["projects","archive"],"childNoteIds":[],
      "parentBranchIds":["projects_sharedNote","archive_sharedNote"],"childBranchIds":[],
      "attributes":[],"dateCreated":"2026-09-28 14:00:00.000+0200",
      "dateModified":"2026-09-28 14:00:00.000+0200",
      "utcDateCreated":"2026-09-28 12:00:00.000Z","utcDateModified":"2026-09-28 12:00:00.000Z"
    }
    """.utf8)
}

/// Handlers are scoped to a unique host so tests can run concurrently without sharing fixtures.
private final class ContractURLProtocol: URLProtocol {
    typealias Handler = @Sendable (URLRequest) throws -> (Int, Data)
    static let registry = Registry()

    final class Registry: @unchecked Sendable {
        private let lock = NSLock()
        private var handlers: [String: Handler] = [:]

        func register(host: String, handler: @escaping Handler) {
            lock.lock()
            defer { lock.unlock() }
            handlers[host] = handler
        }

        func remove(host: String) {
            lock.lock()
            defer { lock.unlock() }
            handlers.removeValue(forKey: host)
        }

        func handler(for host: String) -> Handler? {
            lock.lock()
            defer { lock.unlock() }
            return handlers[host]
        }
    }

    override class func canInit(with request: URLRequest) -> Bool { true }
    override class func canonicalRequest(for request: URLRequest) -> URLRequest { request }

    override func startLoading() {
        do {
            guard let url = request.url, let host = url.host,
                  let handler = Self.registry.handler(for: host) else {
                throw URLError(.unsupportedURL)
            }
            let (status, data) = try handler(request)
            guard let response = HTTPURLResponse(url: url, statusCode: status, httpVersion: "HTTP/1.1",
                                                 headerFields: nil) else {
                throw URLError(.badServerResponse)
            }
            client?.urlProtocol(self, didReceive: response, cacheStoragePolicy: .notAllowed)
            if !data.isEmpty { client?.urlProtocol(self, didLoad: data) }
            client?.urlProtocolDidFinishLoading(self)
        } catch {
            client?.urlProtocol(self, didFailWithError: error)
        }
    }

    override func stopLoading() {}
}
