import Foundation

/// Never forward ETAPI or model credentials through redirects to other endpoints.
final class NoRedirectDelegate: NSObject, URLSessionTaskDelegate {
    func urlSession(_ session: URLSession, task: URLSessionTask,
                    willPerformHTTPRedirection response: HTTPURLResponse, newRequest request: URLRequest,
                    completionHandler: @escaping (URLRequest?) -> Void) { completionHandler(nil) }
}

struct APIClient {
    let baseURL: URL
    let token: String
    let session: URLSession
    init(baseURL: URL, token: String, session: URLSession? = nil) {
        self.baseURL = baseURL
        self.token = token
        self.session = session ?? Self.sharedSession
    }
    private static let sharedSession: URLSession = {
        let config = URLSessionConfiguration.ephemeral
        config.timeoutIntervalForRequest = 45
        config.timeoutIntervalForResource = 120
        config.httpMaximumConnectionsPerHost = 6
        config.httpCookieStorage = nil
        return URLSession(configuration: config, delegate: NoRedirectDelegate(), delegateQueue: nil)
    }()

    static func validatedURL(_ address: String, allowHTTP: Bool) throws -> URL {
        guard let url = URL(string: address.trimmingCharacters(in: .whitespacesAndNewlines)),
              let scheme = url.scheme?.lowercased(), ["https", "http"].contains(scheme),
              url.host != nil, url.user == nil, url.password == nil, url.query == nil, url.fragment == nil else {
            throw UserFacingError(message: "请输入完整的服务器地址，例如 https://notes.example.com。")
        }
        guard scheme == "https" || allowHTTP else {
            throw UserFacingError(message: "HTTP 会明文传输令牌。请使用 HTTPS，或在设置中明确允许 HTTP。")
        }
        return url
    }
    func request(_ path: String, method: String = "GET", query: [URLQueryItem] = [],
                 body: Data? = nil, contentType: String = "application/json") async throws -> Data {
        var url = baseURL
        for segment in ["etapi"] + path.split(separator: "/").map(String.init) {
            url.appendPathComponent(segment)
        }
        var components = URLComponents(url: url, resolvingAgainstBaseURL: false)!
        if !query.isEmpty {
            components.queryItems = query
            // Express decodes a literal + as a space; preserve it in search expressions.
            components.percentEncodedQuery = components.percentEncodedQuery?.replacingOccurrences(of: "+", with: "%2B")
        }
        var request = URLRequest(url: components.url!)
        request.httpMethod = method
        request.setValue(token, forHTTPHeaderField: "Authorization")
        request.setValue(contentType, forHTTPHeaderField: "Content-Type")
        request.httpBody = body
        let (data, response) = try await session.data(for: request)
        try Self.check(response, data: data)
        return data
    }
    static func check(_ response: URLResponse, data: Data) throws {
        guard let response = response as? HTTPURLResponse else { throw UserFacingError(message: "服务器响应无效。") }
        guard (200..<300).contains(response.statusCode) else {
            let message: String
            let payload = (try? JSONSerialization.jsonObject(with: data)) as? [String: Any]
            switch (payload?["code"] as? String, response.statusCode) {
            case ("NOTE_IS_PROTECTED", _): message = "ETAPI 无法读取或修改受保护笔记。"
            case ("DATE_INVALID", _): message = "日期格式无效，请检查设备日期。"
            case (_, 301...399): message = "服务器返回重定向，请在设置中填写最终地址。"
            case (_, 401), (_, 403): message = "认证失败，请检查令牌或 API Key。"
            case (_, 404): message = "接口或笔记不存在，请检查服务器地址与版本。"
            case (_, 409): message = "内容冲突，请重新加载后保存。"
            case (_, 429): message = "请求过于频繁，请稍后重试。"
            default: message = "服务器请求失败（HTTP \(response.statusCode)）。"
            }
            throw UserFacingError(message: message)
        }
    }
    func decode<T: Decodable>(_ path: String, query: [URLQueryItem] = []) async throws -> T {
        try JSONDecoder().decode(T.self, from: await request(path, query: query))
    }
    func appInfo() async throws -> AppInfo { try await decode("app-info") }
    func note(_ id: String) async throws -> Note { try await decode("notes/\(id)") }
    func content(_ id: String) async throws -> String {
        let data = try await request("notes/\(id)/content")
        guard let value = String(data: data, encoding: .utf8) else { throw UserFacingError(message: "此笔记不是 UTF-8 文本，暂不支持编辑。") }
        return value
    }
    func children(_ id: String) async throws -> [TreeEntry] {
        let parent = try await note(id)
        return try await withThrowingTaskGroup(of: TreeEntry.self) { group in
            // Keep at most eight placements in flight, even for very large folders.
            var iterator = parent.childBranchIds.makeIterator()
            for _ in 0..<min(8, parent.childBranchIds.count) {
                if let id = iterator.next() { group.addTask { try await entry(id) } }
            }
            var entries: [TreeEntry] = []
            while let result = try await group.next() {
                entries.append(result)
                if let id = iterator.next() { group.addTask { try await entry(id) } }
            }
            return entries.sorted {
                if $0.branch.notePosition == $1.branch.notePosition { return $0.id < $1.id }
                return $0.branch.notePosition < $1.branch.notePosition
            }
        }
    }
    private func entry(_ branchID: String) async throws -> TreeEntry {
        let branch: Branch = try await decode("branches/\(branchID)")
        return TreeEntry(branch: branch, note: try await note(branch.noteId))
    }
    func search(_ text: String) async throws -> [Note] {
        let response: SearchResponse = try await decode("notes", query: [URLQueryItem(name: "search", value: text),
                                                                        URLQueryItem(name: "ancestorNoteId", value: "root"),
                                                                        URLQueryItem(name: "fastSearch", value: "false"),
                                                                        URLQueryItem(name: "limit", value: "100")])
        return response.results
    }
    func dayNote(_ date: Date = Date()) async throws -> Note {
        let formatter = DateFormatter()
        formatter.locale = Locale(identifier: "en_US_POSIX")
        formatter.calendar = Calendar(identifier: .gregorian)
        formatter.dateFormat = "yyyy-MM-dd"
        return try await decode("calendar/days/\(formatter.string(from: date))")
    }
    func create(parentID: String, title: String, content: String, type: String = "text", mime: String = "text/html") async throws -> Note {
        let body = try JSONSerialization.data(withJSONObject: ["parentNoteId": parentID, "title": title,
                                                               "type": type, "mime": mime, "content": content])
        let data = try await request("create-note", method: "POST", body: body)
        return try JSONDecoder().decode(CreatedNote.self, from: data).note
    }
    func updateContent(_ id: String, content: String, mime: String) async throws {
        _ = try await request("notes/\(id)/content", method: "PUT", body: Data(content.utf8), contentType: "text/plain; charset=utf-8")
    }
    func updateTitle(_ id: String, title: String) async throws {
        let body = try JSONSerialization.data(withJSONObject: ["title": title])
        _ = try await request("notes/\(id)", method: "PATCH", body: body)
    }
}
