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

@MainActor
struct NoteEditorToolbar: View {
    @Binding var command: NoteWebView.EditorCommand?
    var formattingEnabled = true
    let onDismissKeyboard: () -> Void

    var body: some View {
        HStack(spacing: 8) {
            ScrollView(.horizontal, showsIndicators: false) {
                HStack(spacing: 4) {
                    formatButton("撤销", icon: "arrow.uturn.backward", name: "undo")
                    formatButton("重做", icon: "arrow.uturn.forward", name: "redo")
                    formatButton("列表", icon: "list.bullet", name: "insertUnorderedList")
                    formatButton("编号", icon: "list.number", name: "insertOrderedList")
                    formatButton("引用", icon: "text.quote", name: "formatBlock", value: "blockquote")
                    Menu {
                        Button("标题") { run("formatBlock", value: "h2") }
                        Button("正文") { run("formatBlock", value: "p") }
                    } label: {
                        Image(systemName: "textformat.size").frame(width: 40, height: 44)
                    }.accessibilityLabel("标题与正文")
                    formatButton("加粗", icon: "bold", name: "bold")
                    formatButton("斜体", icon: "italic", name: "italic")
                }.padding(.horizontal, 8)
            }
            .disabled(!formattingEnabled)
            .background(Color(.systemBackground), in: Capsule())
            Button(action: onDismissKeyboard) {
                Image(systemName: "keyboard.chevron.compact.down").frame(width: 44, height: 44)
            }
            .background(Color(.systemBackground), in: Circle())
            .accessibilityLabel("收起键盘")
        }
        .font(.system(size: 21)).foregroundStyle(.primary).buttonStyle(.plain)
        .shadow(color: .black.opacity(0.06), radius: 12, y: 4)
        .padding(.horizontal, 8).padding(.vertical, 8)
        .background(Color(.systemBackground).opacity(0.95))
    }

    private func formatButton(_ title: String, icon: String, name: String, value: String? = nil) -> some View {
        Button { run(name, value: value) } label: {
            Image(systemName: icon).frame(width: 40, height: 44)
        }.accessibilityLabel(title)
    }
    private func run(_ name: String, value: String? = nil) {
        command = NoteWebView.EditorCommand(name: name, value: value)
    }
}
