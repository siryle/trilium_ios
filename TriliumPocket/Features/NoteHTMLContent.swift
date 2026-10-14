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
struct NoteEditorLayout<Actions: View, Content: View>: View {
    @Binding var title: String
    @FocusState.Binding var titleFocused: Bool
    @Binding var command: NoteWebView.EditorCommand?
    let preview: Bool
    let busy: Bool
    let saving: Bool
    let formattingEnabled: Bool
    let onDirectory: () -> Void
    let onPreview: () -> Void
    let onDismissKeyboard: () -> Void
    @ViewBuilder let actions: () -> Actions
    @ViewBuilder let content: () -> Content

    var body: some View {
        VStack(alignment: .leading, spacing: 0) {
            HStack {
                Button(action: onDirectory) {
                    Image(systemName: "sidebar.left").frame(width: 44, height: 44)
                }
                .background(Color(.systemBackground), in: Circle())
                .shadow(color: .black.opacity(0.06), radius: 12, y: 4)
                .accessibilityLabel("打开笔记目录")
                Spacer()
                if saving { ProgressView().padding(.trailing, 12) }
                HStack(spacing: 0) {
                    Button(action: onPreview) {
                        Image(systemName: preview ? "square.and.pencil" : "book")
                            .frame(width: 48, height: 44)
                    }.accessibilityLabel(preview ? "继续编辑" : "阅读预览")
                    Menu(content: actions) {
                        Image(systemName: "ellipsis").frame(width: 44, height: 44)
                    }.accessibilityLabel("更多操作")
                }
                .padding(.horizontal, 4)
                .background(Color(.systemBackground), in: Capsule())
                .shadow(color: .black.opacity(0.06), radius: 12, y: 4)
            }
            .font(.system(size: 22)).foregroundStyle(.primary).disabled(busy)
            .padding(.horizontal, 12).padding(.top, 8)
            TextField("笔记标题", text: $title, prompt: Text("未命名").foregroundColor(.primary), axis: .vertical)
                .font(.largeTitle.bold())
                .focused($titleFocused).disabled(preview || busy)
                .padding(.horizontal, 24).padding(.top, 28).padding(.bottom, 8)
                .accessibilityLabel("笔记标题")
            content()
                .frame(maxWidth: .infinity, maxHeight: .infinity)
                .allowsHitTesting(!busy)
        }
        .background(Color(.systemBackground))
        .safeAreaInset(edge: .bottom, spacing: 0) {
            if !preview {
                NoteEditorToolbar(command: $command, formattingEnabled: formattingEnabled,
                                  onDismissKeyboard: onDismissKeyboard)
                    .disabled(busy)
            }
        }
    }
}

@MainActor
struct NoteEditorSidebar<Content: View, Directory: View>: View {
    let isPresented: Bool
    let onClose: () -> Void
    @ViewBuilder let content: () -> Content
    @ViewBuilder let directory: () -> Directory

    var body: some View {
        GeometryReader { geometry in
            let width = min(geometry.size.width * 0.84, 380)
            ZStack(alignment: .leading) {
                content()
                    .offset(x: isPresented ? width : 0)
                    .allowsHitTesting(!isPresented)
                    .accessibilityHidden(isPresented)
                if isPresented {
                    Color.black.opacity(0.12).ignoresSafeArea()
                        .onTapGesture(perform: onClose)
                        .accessibilityHidden(true)
                    directory()
                        .frame(width: width)
                        .transition(.move(edge: .leading))
                        .shadow(color: .black.opacity(0.08), radius: 12, x: 4)
                }
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

@MainActor
struct NoteDirectorySidebar: View {
    @EnvironmentObject private var model: AppModel
    var location: Note? = nil
    var directoryID: String? = nil
    var draftTitle: String? = nil
    let onClose: () -> Void
    @State private var directory: Note?
    @State private var failure: String?

    var body: some View {
        NavigationStack {
            Group {
                if let directory {
                    NotebookView(noteID: directory.id, title: "笔记目录", highlightedNoteID: location?.id ?? directory.id,
                                 draftTitle: draftTitle.map { $0.isEmpty ? "未命名" : $0 },
                                 onResumeDraft: onClose, onHighlightedNote: onClose)
                        .safeAreaInset(edge: .bottom) {
                            NavigationLink {
                                NotebookView(noteID: "root", title: "文件列表")
                            } label: {
                                Label("文件列表", systemImage: "folder")
                                    .font(.headline).frame(maxWidth: .infinity, alignment: .leading)
                                    .padding(16)
                                    .background(Color(.systemGray6), in: Capsule())
                            }.padding(16).background(Color(.systemBackground))
                        }
                } else if let failure {
                    ContentUnavailableView {
                        Label("无法加载目录", systemImage: "folder.badge.questionmark")
                    } description: { Text(failure) } actions: {
                        Button("重试") { Task { await load() } }
                    }
                } else {
                    ProgressView("定位笔记目录…").frame(maxWidth: .infinity, maxHeight: .infinity)
                }
            }
            .navigationTitle("笔记目录").navigationBarTitleDisplayMode(.inline)
            .toolbar(.visible, for: .navigationBar)
            .toolbar {
                ToolbarItem(placement: .topBarLeading) {
                    Button(action: onClose) { Image(systemName: "sidebar.left") }
                        .accessibilityLabel("收起目录，继续编辑")
                }
            }
        }
        .background(Color(.systemBackground).ignoresSafeArea())
        .task { await load() }
    }

    private func load() async {
        failure = nil
        do {
            let api = try model.client()
            let result: Note
            if let location {
                result = try await api.note(directoryID ?? location.parentNoteIds.first ?? "root")
            } else {
                result = try await api.dayNote()
            }
            try Task.checkCancellation()
            directory = result
        } catch {
            if error is CancellationError || (error as? URLError)?.code == .cancelled { return }
            failure = error.localizedDescription
        }
    }
}
