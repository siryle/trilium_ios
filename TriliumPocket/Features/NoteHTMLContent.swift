import SwiftUI

@MainActor
struct NoteHTMLContent: View {
    let content: String
    let editing: Bool
    let api: APIClient
    @ObservedObject var bridge: WebEditorBridge
    let command: NoteWebView.EditorCommand?
    let onChange: (String) -> Void
    let onSourceEdit: () -> Void
    let onNoteLink: (String) -> Void
    @State private var rendererID = UUID()

    var body: some View {
        ZStack {
            NoteWebView(content: content, editing: editing, api: api, bridge: bridge, command: command,
                        onChange: onChange, onNoteLink: onNoteLink)
                .id(rendererID)
                .frame(maxWidth: .infinity, maxHeight: .infinity)
                .opacity(bridge.displayError == nil ? 1 : 0)
                .allowsHitTesting(bridge.displayError == nil)
            if let error = bridge.displayError {
                ScrollView {
                    VStack(alignment: .leading, spacing: 16) {
                        Label(error, systemImage: "doc.text.magnifyingglass")
                            .font(.footnote).foregroundStyle(.secondary)
                        HStack {
                            Button("重试排版") {
                                bridge.displayError = nil; bridge.isLoading = true
                                rendererID = UUID()
                            }
                            Button("编辑源码", action: onSourceEdit)
                        }.buttonStyle(.bordered)
                        let text = HTMLText.plainText(content)
                        Text(text.isEmpty ? "此笔记没有可显示的文字，可查看 HTML 源码。" : text)
                            .frame(maxWidth: .infinity, alignment: .leading)
                            .textSelection(.enabled)
                    }.padding(20)
                }.background(Color(.systemBackground))
            } else if bridge.isLoading {
                ScrollView {
                    VStack(alignment: .leading, spacing: 16) {
                        ProgressView("准备笔记排版…")
                        let text = HTMLText.plainText(content)
                        if !text.isEmpty {
                            Text(text).frame(maxWidth: .infinity, alignment: .leading).textSelection(.enabled)
                        }
                    }.padding(20)
                }.background(Color(.systemBackground))
            } else if content.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty && !editing {
                ContentUnavailableView("这条笔记还没有正文", systemImage: "doc", description: Text("点击右上角编辑开始记录。"))
                    .allowsHitTesting(false)
            }
        }
        .task(id: rendererID) {
            // A failed WebKit bootstrap must not leave an unexplained blank screen.
            do { try await Task.sleep(for: .seconds(45)) } catch { return }
            if bridge.isLoading {
                bridge.ready = false
                bridge.displayError = "笔记排版加载超时，已显示文字内容。"
                bridge.isLoading = false
            }
        }
    }
}
