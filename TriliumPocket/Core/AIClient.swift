import Foundation

/// A provider transport independent of Trilium's private session/CSRF chat API.
struct AIClient {
    let baseURL: URL
    let apiKey: String
    let model: String

    private static let session: URLSession = {
        let configuration = URLSessionConfiguration.ephemeral
        configuration.timeoutIntervalForRequest = 120
        configuration.timeoutIntervalForResource = 600
        configuration.urlCache = nil
        configuration.httpCookieStorage = nil
        return URLSession(configuration: configuration, delegate: NoRedirectDelegate(), delegateQueue: nil)
    }()

    init(address: String, apiKey: String, model: String, allowHTTP: Bool) throws {
        baseURL = try APIClient.validatedURL(address, allowHTTP: allowHTTP)
        self.apiKey = apiKey.trimmingCharacters(in: .whitespacesAndNewlines)
        self.model = model.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !self.model.isEmpty else { throw UserFacingError(message: "请先在设置中填写 AI 模型名称。") }
    }

    func stream(messages: [ChatMessage], onText: @MainActor (String) -> Void) async throws {
        var request = URLRequest(url: baseURL.appendingPathComponent("chat").appendingPathComponent("completions"))
        request.httpMethod = "POST"
        request.setValue("application/json", forHTTPHeaderField: "Content-Type")
        request.setValue("text/event-stream", forHTTPHeaderField: "Accept")
        if !apiKey.isEmpty { request.setValue("Bearer \(apiKey)", forHTTPHeaderField: "Authorization") }
        request.httpBody = try JSONSerialization.data(withJSONObject: [
            "model": model, "stream": true,
            "messages": messages.map { ["role": $0.role, "content": $0.content] }
        ])
        let (bytes, response) = try await Self.session.bytes(for: request)
        guard let http = response as? HTTPURLResponse else { throw UserFacingError(message: "AI 服务响应无效。") }
        guard (200..<300).contains(http.statusCode) else {
            // Bound and decode errors without logging headers, credentials or prompts.
            var data = Data()
            for try await byte in bytes {
                try Task.checkCancellation()
                data.append(byte)
                if data.count >= 16_384 { break }
            }
            if (300..<400).contains(http.statusCode) {
                throw UserFacingError(message: "AI 服务返回重定向，请在设置中填写最终 API 地址。")
            }
            let detail = Self.errorMessage(data)
            throw UserFacingError(message: "AI 请求失败（HTTP \(http.statusCode)）" + (detail.map { "：\($0)" } ?? "。"))
        }
        guard http.value(forHTTPHeaderField: "Content-Type")?.lowercased().contains("text/event-stream") == true else {
            throw UserFacingError(message: "AI 服务没有返回 SSE 流，请检查是否支持 OpenAI Chat Completions。")
        }

        var parser = SSEParser()
        var sawFinish = false
        var receivedCount = 0
        var pendingText = ""
        var lastDelivery = ContinuousClock.now
        do {
            for try await byte in bytes {
                try Task.checkCancellation()
                guard let payload = try parser.append(byte), !payload.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty else { continue }
                if payload.trimmingCharacters(in: .whitespacesAndNewlines) == "[DONE]" {
                    if !pendingText.isEmpty { await onText(pendingText) }
                    return
                }
                let data = Data(payload.utf8)
                if let error = Self.errorMessage(data) { throw UserFacingError(message: "AI 服务错误：\(error)") }
                let chunk: CompletionChunk
                do { chunk = try JSONDecoder().decode(CompletionChunk.self, from: data) }
                catch { throw UserFacingError(message: "AI 服务返回了无法解析的流数据。") }
                for choice in chunk.choices where choice.index == 0 {
                    if let text = choice.delta.content {
                        receivedCount += text.utf8.count
                        guard receivedCount <= 2_000_000 else { throw UserFacingError(message: "AI 回复过长，已停止接收。") }
                        pendingText += text
                    }
                    if let reason = choice.finish_reason {
                        if reason == "tool_calls" || reason == "function_call" {
                            throw UserFacingError(message: "此回复要求执行工具；当前聊天仅支持文本。")
                        }
                        if reason == "content_filter" { throw UserFacingError(message: "AI 服务过滤了此回复。") }
                        if reason == "length" { throw UserFacingError(message: "回复达到模型长度限制，已保留部分内容。") }
                        sawFinish = true
                    }
                }
                if !pendingText.isEmpty && lastDelivery.duration(to: .now) >= .milliseconds(45) {
                    await onText(pendingText)
                    pendingText = ""
                    lastDelivery = .now
                }
            }
        } catch {
            if !pendingText.isEmpty { await onText(pendingText) }
            throw error
        }
        if !pendingText.isEmpty { await onText(pendingText) }
        try Task.checkCancellation()
        guard sawFinish else { throw UserFacingError(message: "AI 连接提前结束，已保留部分回复。请重试。") }
    }

    private static func errorMessage(_ data: Data) -> String? {
        guard let root = try? JSONSerialization.jsonObject(with: data) as? [String: Any], let error = root["error"] else { return nil }
        let message = (error as? [String: Any])?["message"] as? String ?? error as? String ?? "服务返回未知错误。"
        return String(message.prefix(500))
    }
}

private struct CompletionChunk: Decodable {
    let choices: [Choice]
    struct Choice: Decodable {
        let index: Int
        let delta: Delta
        let finish_reason: String?
    }
    struct Delta: Decodable { let content: String? }
}

/// Assemble UTF-8 lines before decoding, then join all data fields of an SSE event.
/// This avoids assumptions about URLSession packet, code-point or event boundaries.
struct SSEParser {
    private var line = Data()
    private var fields: [String] = []
    private var eventSize = 0
    private var previousWasCR = false

    mutating func append(_ byte: UInt8) throws -> String? {
        if byte == 10 && previousWasCR { previousWasCR = false; return nil }
        previousWasCR = byte == 13
        if byte == 10 || byte == 13 {
            guard let value = String(data: line, encoding: .utf8) else { throw UserFacingError(message: "AI 流包含无效的 UTF-8 文本。") }
            line.removeAll(keepingCapacity: true)
            if value.isEmpty {
                defer { fields.removeAll(keepingCapacity: true); eventSize = 0 }
                return fields.isEmpty ? nil : fields.joined(separator: "\n")
            }
            if value.hasPrefix("data:") {
                var field = String(value.dropFirst(5))
                if field.first == " " { field.removeFirst() }
                fields.append(field)
                eventSize += field.utf8.count
                guard eventSize <= 1_048_576 else { throw UserFacingError(message: "AI 流事件过大。") }
            }
            return nil
        }
        line.append(byte)
        guard line.count <= 1_048_576 else { throw UserFacingError(message: "AI 流数据行过长。") }
        return nil
    }
}
