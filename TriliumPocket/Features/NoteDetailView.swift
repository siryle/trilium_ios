import SwiftUI

@MainActor
final class NoteEditorModel: ObservableObject {
    @Published var note: Note?
    @Published var title = ""
    @Published var content = ""
    @Published var editing = false
    @Published var sourceEditing = false
    @Published var loading = false
    @Published var saving = false
    @Published var failure: String?
    @Published var conflict = false
    @Published var draftWarning: String?
    @Published var imageData: Data?
    private var baselineTitle = ""
    private var baselineContent = ""
    private var baselineModified: String?
    private var draftName = ""
    private let store = LocalStore()
    private var didLoad = false
    private var loadTask: Task<Void, Never>?
    private var ownsDraft = false
    var dirty: Bool { note != nil && (title != baselineTitle || content != baselineContent) }

    func load(id: String, api: APIClient, server: String) async {
        guard !didLoad, !saving else { return }
        if let loadTask { await loadTask.value; return }
        // Sharing an editor also shares its load; navigation cancellation cannot reset another screen.
        let task = Task { await fetch(id: id, api: api, server: server) }
        loadTask = task
        await task.value
        loadTask = nil
    }
    func reload(id: String, api: APIClient, server: String) async {
        guard !dirty, !saving, !loading else { return }
        didLoad = false; imageData = nil
        await load(id: id, api: api, server: server)
    }
    private func fetch(id: String, api: APIClient, server: String) async {
        loading = true; failure = nil
        defer { loading = false }
        draftName = LocalStore.scopedName("note", server: server, noteID: id)
        do {
            let metadata = try await api.note(id)
            note = metadata; title = metadata.title; baselineTitle = metadata.title
            guard !metadata.isProtected else { didLoad = true; return }
            if metadata.type == "image" {
                imageData = try await api.request("notes/\(id)/content")
                didLoad = true
                return
            }
            guard metadata.type != "file" else { didLoad = true; return }
            let text = try await api.content(id)
            try Task.checkCancellation()
            content = text; baselineContent = text; baselineModified = metadata.utcDateModified
            if let draft = store.load(draftName, as: NoteDraft.self), metadata.isEditable {
                title = draft.title; content = draft.content
                baselineTitle = draft.originalTitle; baselineContent = draft.originalContent
                baselineModified = draft.originalModified
                editing = true; ownsDraft = true
                draftWarning = "已恢复本机未保存草稿。"
            }
            sourceEditing = metadata.type == "text" && HTMLText.requiresSourceEditing(content)
            didLoad = true
        } catch {
            if error is CancellationError || (error as? URLError)?.code == .cancelled { return }
            failure = error.localizedDescription
        }
    }
    func persistDraft() {
        guard note?.isEditable == true, !loading, !draftName.isEmpty else { return }
        do {
            if dirty {
                try store.save(NoteDraft(title: title, content: content, originalTitle: baselineTitle,
                                         originalContent: baselineContent, originalModified: baselineModified), name: draftName)
                ownsDraft = true
            } else { try removeOwnedDraft() }
        } catch { draftWarning = "本机草稿保存失败，请在离开前保存到服务器：\(error.localizedDescription)" }
    }
    func save(api: APIClient) async throws {
        guard !saving else { return }
        guard let note, dirty else { editing = false; return }
        let sentTitle = title
        let sentContent = content
        saving = true; defer { saving = false }
        let remote = try await api.note(note.id)
        let remoteContent = try await api.content(note.id)
        guard remote.title == baselineTitle, remoteContent == baselineContent else { conflict = true; return }
        // Rebase to exactly what each request sent; late editor events remain a local draft.
        if sentContent != baselineContent {
            try await api.updateContent(note.id, content: sentContent, mime: note.mime)
            baselineContent = sentContent; persistDraft()
        }
        if sentTitle != baselineTitle {
            try await api.updateTitle(note.id, title: sentTitle)
            baselineTitle = sentTitle; persistDraft()
        }
        self.note?.title = sentTitle
        if dirty { persistDraft() }
        else { try removeOwnedDraft(); editing = false; draftWarning = nil }
    }
    func saveCopy(api: APIClient) async throws -> Note {
        guard let note, !saving else { throw UserFacingError(message: "笔记尚未加载或正在保存，请稍后重试。") }
        saving = true; defer { saving = false }
        let result = try await api.create(parentID: note.parentNoteIds.first ?? "root", title: title + "（副本）",
                                         content: content, type: note.type, mime: note.mime)
        return result
    }
    private func removeOwnedDraft() throws {
        guard ownsDraft else { return }
        try store.remove(draftName)
        ownsDraft = false
    }
    func discardDraft() {
        title = baselineTitle; content = baselineContent; editing = false; draftWarning = nil
        do { try removeOwnedDraft() } catch { draftWarning = error.localizedDescription }
    }
}

struct NoteDetailView: View {
    @EnvironmentObject private var model: AppModel
    let noteID: String
    var body: some View { NoteDetailContent(editor: model.editor(for: noteID), noteID: noteID) }
}

@MainActor
private struct NoteDetailContent: View {
    @EnvironmentObject private var model: AppModel
    @ObservedObject var editor: NoteEditorModel
    let noteID: String
    @State private var command: NoteWebView.EditorCommand?
    @StateObject private var webBridge = WebEditorBridge()
    @State private var preparingSave = false
    @State private var linkedNote: Note?
    @State private var discard = false
    var body: some View {
        Group {
            if editor.loading { ProgressView("加载笔记…") }
            else if let failure = editor.failure {
                ContentUnavailableView {
                    Label("无法加载笔记", systemImage: "wifi.exclamationmark")
                } description: { Text(failure) } actions: {
                    Button("重试") { Task { await load() } }
                }
            } else if let note = editor.note {
                VStack(spacing: 0) {
                    if let warning = editor.draftWarning {
                        Text(warning).font(.footnote).foregroundStyle(.secondary).padding(10).frame(maxWidth: .infinity).background(.thinMaterial)
                    }
                    if editor.editing {
                        TextField("标题", text: $editor.title).font(.title2.bold()).padding()
                            .disabled(editor.saving || preparingSave)
                    }
                    if note.isProtected {
                        ContentUnavailableView("受保护笔记", systemImage: "lock", description: Text("ETAPI 无法读取受保护笔记的正文，请在 Trilium 中解锁和查看。"))
                    } else if note.type == "image", let data = editor.imageData, let image = UIImage(data: data) {
                        ScrollView { Image(uiImage: image).resizable().scaledToFit().padding() }
                    } else if note.type == "file" {
                        ContentUnavailableView("附件笔记", systemImage: "paperclip", description: Text("当前版本支持文本和图片阅读。此附件请在 Trilium 中查看。"))
                    } else if note.type == "text", (!editor.editing || !editor.sourceEditing), let api = try? model.client() {
                        NoteHTMLContent(content: editor.content, editing: editor.editing && !editor.saving,
                                        api: api, bridge: webBridge, command: command,
                                        onChange: { editor.content = $0; editor.persistDraft() },
                                        onSourceEdit: { editor.sourceEditing = true; editor.editing = true },
                                        onNoteLink: { id in Task {
                                            do { linkedNote = try await model.client().note(id) } catch { model.report(error) }
                                        } })
                            .frame(maxWidth: .infinity, maxHeight: .infinity)
                            .layoutPriority(1)
                    } else if editor.editing {
                        if editor.sourceEditing {
                            Text("HTML 源码编辑：保留此笔记的复杂结构和格式。").font(.caption).foregroundStyle(.secondary).padding(.horizontal)
                        }
                        TextEditor(text: $editor.content).font(.system(.body, design: .monospaced)).textInputAutocapitalization(.never).autocorrectionDisabled().padding(12).disabled(editor.saving || preparingSave)
                    } else {
                        ScrollView {
                            VStack(alignment: .leading, spacing: 12) {
                                if !note.isEditable { Text("\(note.type) · 只读内容").font(.caption).foregroundStyle(.secondary) }
                                if note.mime.contains("markdown"), let markdown = try? AttributedString(markdown: editor.content, options: .init(interpretedSyntax: .full)) {
                                    Text(markdown).frame(maxWidth: .infinity, alignment: .leading).textSelection(.enabled)
                                } else {
                                    Text(editor.content).font(.system(.body, design: .monospaced)).frame(maxWidth: .infinity, alignment: .leading).textSelection(.enabled)
                                }
                            }.padding(20)
                        }
                    }
                }
                .frame(maxWidth: .infinity, maxHeight: .infinity)
                .allowsHitTesting(!preparingSave)
                .safeAreaInset(edge: .bottom) {
                    if editor.editing && note.type == "text" && !editor.sourceEditing {
                        ScrollView(.horizontal, showsIndicators: false) {
                            HStack(spacing: 20) {
                                formatButton("加粗", icon: "bold", command: "bold")
                                formatButton("斜体", icon: "italic", command: "italic")
                                formatButton("标题", icon: "textformat.size", command: "formatBlock", value: "h2")
                                formatButton("正文", icon: "paragraph", command: "formatBlock", value: "p")
                                formatButton("列表", icon: "list.bullet", command: "insertUnorderedList")
                                formatButton("编号", icon: "list.number", command: "insertOrderedList")
                                formatButton("引用", icon: "text.quote", command: "formatBlock", value: "blockquote")
                                formatButton("撤销", icon: "arrow.uturn.backward", command: "undo")
                                formatButton("重做", icon: "arrow.uturn.forward", command: "redo")
                            }.padding(.horizontal, 20).padding(.vertical, 10)
                        }.background(.bar).disabled(editor.saving || preparingSave)
                    }
                }
            }
        }
        .navigationTitle(editor.note?.title ?? "笔记")
        .navigationBarTitleDisplayMode(.inline)
        .toolbar(.visible, for: .navigationBar, .tabBar)
        .toolbar {
            if let note = editor.note, editor.failure == nil {
                ToolbarItemGroup(placement: .topBarTrailing) {
                    if note.isEditable {
                        if editor.editing {
                            Button(editor.saving ? "保存中…" : "保存") { Task { await save() } }
                                .disabled(editor.saving || preparingSave || editor.title.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty)
                        } else { Button("编辑") { editor.editing = true } }
                    }
                    Menu {
                        Button("重新加载", systemImage: "arrow.clockwise") { Task {
                            do {
                                let api = try model.client()
                                await editor.reload(id: noteID, api: api, server: model.configuration.address)
                            } catch { model.report(error) }
                        } }.disabled(editor.dirty)
                        if note.isEditable {
                            Button("另存为副本", systemImage: "doc.on.doc") { Task {
                                await saveCopy()
                            } }
                        }
                        if note.isEditable && note.type == "text" {
                            Button("编辑 HTML 源码", systemImage: "chevron.left.forwardslash.chevron.right") { editor.sourceEditing = true; editor.editing = true }
                            if editor.sourceEditing && editor.editing {
                                Button("切换到富文本编辑", systemImage: "textformat") { editor.sourceEditing = false }
                                    .disabled(HTMLText.requiresSourceEditing(editor.content))
                            }
                        }
                        if !note.childNoteIds.isEmpty {
                            NavigationLink { NotebookView(noteID: note.id, title: editor.title) } label: { Label("子笔记", systemImage: "folder") }
                        }
                        if !note.isProtected && note.type != "file" && note.type != "image" {
                            Button { model.contextNote = note; model.contextContent = editor.content; model.selectedTab = 3 } label: { Label("附加到 AI 对话", systemImage: "bubble.left.and.text.bubble.right") }
                        }
                        if editor.dirty { Button("放弃本机草稿", role: .destructive) { discard = true } }
                    } label: { Image(systemName: "ellipsis.circle") }.disabled(editor.saving || preparingSave)
                }
            }
        }
        .task { await load() }
        .onChange(of: editor.title) { _, _ in editor.persistDraft() }
        .onChange(of: editor.content) { _, _ in editor.persistDraft() }
        .onDisappear { editor.persistDraft() }
        .navigationDestination(item: $linkedNote) { NoteDetailView(noteID: $0.id) }
        .confirmationDialog("放弃未保存的本机修改？", isPresented: $discard, titleVisibility: .visible) {
            Button("放弃草稿", role: .destructive) { editor.discardDraft() }
            Button("继续编辑", role: .cancel) { }
        }
        .alert("服务端笔记已有修改", isPresented: $editor.conflict) {
            Button("保存为新副本") { Task {
                await saveCopy()
            } }
            Button("保留本机草稿", role: .cancel) { }
        } message: { Text("为避免覆盖其他设备的修改，当前草稿已保留。可以保存为新副本，再对照整理。") }
    }
    private func formatButton(_ title: String, icon: String, command name: String, value: String? = nil) -> some View {
        Button { command = NoteWebView.EditorCommand(name: name, value: value) } label: {
            Image(systemName: icon).frame(minWidth: 24, minHeight: 24)
        }.accessibilityLabel(title)
    }
    private func load() async {
        do {
            let api = try model.client()
            await editor.load(id: noteID, api: api, server: model.configuration.address)
        } catch { model.report(error) }
    }
    private func flushEditor() async throws {
        if editor.editing && !editor.sourceEditing && editor.note?.type == "text" {
            let beforeFlush = editor.content
            if let latest = try await webBridge.flush() {
                guard editor.content == beforeFlush || editor.content == latest else {
                    throw UserFacingError(message: "编辑内容在保存准备期间发生变化，草稿已保留，请重新保存。")
                }
                editor.content = latest; editor.persistDraft()
            }
        }
    }
    private func save() async {
        guard !preparingSave, !editor.saving else { return }
        preparingSave = true; defer { preparingSave = false }
        do {
            // Commit input/IME and export the live DOM before disabling it or taking a snapshot.
            try await flushEditor()
            try await editor.save(api: model.client())
            model.changeVersion += 1
        } catch { editor.persistDraft(); model.report(error) }
    }
    private func saveCopy() async {
        guard !preparingSave, !editor.saving else { return }
        preparingSave = true; defer { preparingSave = false }
        do {
            try await flushEditor()
            linkedNote = try await editor.saveCopy(api: model.client())
            model.changeVersion += 1
        } catch { editor.persistDraft(); model.report(error) }
    }
}
