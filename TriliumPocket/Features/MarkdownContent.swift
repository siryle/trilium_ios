import SwiftUI

@MainActor
struct MarkdownContent: View {
    let source: String
    var api: APIClient? = nil
    var onNoteLink: (String) -> Void = { _ in }
    @StateObject private var bridge = WebEditorBridge()
    @State private var html = ""
    @State private var height: CGFloat = 24

    var body: some View {
        ZStack(alignment: .topLeading) {
            NoteWebView(content: html, editing: false, api: api, bridge: bridge, command: nil,
                        onChange: { _ in }, onNoteLink: onNoteLink,
                        onHeightChange: { height = max(24, $0) })
                .frame(height: height)
                .opacity(bridge.isLoading || bridge.displayError != nil ? 0 : 1)
            if bridge.displayError != nil {
                Text(source).frame(maxWidth: .infinity, alignment: .leading).textSelection(.enabled)
            } else if bridge.isLoading {
                ProgressView().frame(maxWidth: .infinity, alignment: .leading)
            }
        }
        .frame(maxWidth: .infinity, alignment: .leading)
        .onChange(of: source, initial: true) { _, value in
            html = MarkdownHTML.html(from: value)
        }
    }
}
