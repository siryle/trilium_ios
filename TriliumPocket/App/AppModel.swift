import SwiftUI

@MainActor
final class AppModel: ObservableObject {
    @Published private(set) var configuration: ServerConfiguration
    @Published private(set) var connectionID = UUID()
    @Published var selectedTab = 0
    @Published var error: String?
    @Published var contextNote: Note?
    @Published var contextContent: String?
    @Published var changeVersion = 0
    private let keychain = Keychain()
    private let store = LocalStore()
    private let injectedClient: APIClient?
    private var editors: [String: NoteEditorModel] = [:]

    func editor(for noteID: String) -> NoteEditorModel {
        if let editor = editors[noteID] { return editor }
        let editor = NoteEditorModel()
        editors[noteID] = editor
        return editor
    }

    func isNoteDeleted(_ noteID: String) -> Bool { editors[noteID]?.deleted == true }

    func didDeleteNote(_ noteID: String) {
        if contextNote?.id == noteID {
            contextNote = nil
            contextContent = nil
        }
        changeVersion += 1
    }

    init(client: APIClient? = nil) {
        injectedClient = client
        if let client {
            var settings = ServerConfiguration()
            settings.address = client.baseURL.absoluteString
            configuration = settings
        } else {
            configuration = store.load("configuration", as: ServerConfiguration.self) ?? ServerConfiguration()
        }
    }
    var isConfigured: Bool { injectedClient != nil || (!configuration.address.isEmpty && !token.isEmpty) }
    var token: String { keychain.read("etapi") }
    var aiKey: String { keychain.read("ai") }
    func client() throws -> APIClient {
        if let injectedClient { return injectedClient }
        guard !token.isEmpty else { throw UserFacingError(message: "请先在设置中填写 ETAPI 令牌。") }
        return APIClient(baseURL: try APIClient.validatedURL(configuration.address, allowHTTP: configuration.allowHTTP), token: token)
    }
    func saveConfiguration(_ value: ServerConfiguration, token: String, aiKey: String) throws {
        _ = try APIClient.validatedURL(value.address, allowHTTP: value.allowHTTP)
        _ = try APIClient.validatedURL(value.aiAddress, allowHTTP: value.allowHTTP)
        let oldToken = self.token
        let oldAIKey = self.aiKey
        do {
            try keychain.write(token.trimmingCharacters(in: .whitespacesAndNewlines), account: "etapi")
            try keychain.write(aiKey.trimmingCharacters(in: .whitespacesAndNewlines), account: "ai")
            try store.save(value, name: "configuration")
        } catch {
            try? keychain.write(oldToken, account: "etapi")
            try? keychain.write(oldAIKey, account: "ai")
            throw error
        }
        configuration = value
        editors.removeAll()
        contextNote = nil
        contextContent = nil
        connectionID = UUID()
    }
    func report(_ error: Error) {
        if error is CancellationError || (error as? URLError)?.code == .cancelled { return }
        self.error = error.localizedDescription
    }
}
