import Foundation

struct Note: Codable, Identifiable, Hashable {
    let noteId: String
    var title: String
    let type: String
    let mime: String
    let isProtected: Bool
    let parentNoteIds: [String]
    let childNoteIds: [String]
    let childBranchIds: [String]
    let utcDateModified: String?
    var id: String { noteId }
    var isEditable: Bool { !isProtected && (type == "text" || type == "code") }
    var icon: String {
        if isProtected { return "lock" }
        switch type {
        case "text": return "doc.text"
        case "code": return "chevron.left.forwardslash.chevron.right"
        case "image": return "photo"
        case "file": return "paperclip"
        default: return "doc"
        }
    }
}

struct Branch: Decodable, Identifiable {
    let branchId: String
    let noteId: String
    let parentNoteId: String
    let notePosition: Int
    let prefix: String?
    var id: String { branchId }
}

struct TreeEntry: Identifiable {
    let branch: Branch
    let note: Note
    var id: String { branch.id }
    var title: String {
        guard let prefix = branch.prefix, !prefix.isEmpty else { return note.title }
        return "\(prefix) - \(note.title)"
    }
}

struct SearchResponse: Decodable { let results: [Note] }
struct CreatedNote: Decodable { let note: Note; let branch: Branch }
struct AppInfo: Decodable { let appVersion: String }

struct ServerConfiguration: Codable, Equatable {
    var address = ""
    var aiAddress = "https://api.openai.com/v1"
    var aiModel = "gpt-4o-mini"
    var aiSaveParentID = "root"
    var allowHTTP = false
}

struct NoteDraft: Codable {
    var title: String
    var content: String
    let originalTitle: String
    let originalContent: String
    let originalModified: String?
}

struct ChatMessage: Codable, Identifiable, Equatable {
    let id: UUID
    let role: String
    var content: String
    init(role: String, content: String) { self.id = UUID(); self.role = role; self.content = content }
}

struct Conversation: Codable {
    var messages: [ChatMessage] = []
    var savedNoteID: String?
    var savedTitle: String?
}

struct UserFacingError: LocalizedError {
    let message: String
    var errorDescription: String? { message }
}
