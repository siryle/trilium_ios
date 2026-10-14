import SwiftUI

struct NotebookView: View {
    @EnvironmentObject private var model: AppModel
    let noteID: String
    let title: String
    var picking: ((Note) -> Void)? = nil
    var highlightedNoteID: String? = nil
    var draftTitle: String? = nil
    var onResumeDraft: (() -> Void)? = nil
    var onHighlightedNote: (() -> Void)? = nil
    @State private var entries: [TreeEntry] = []
    @State private var parent: Note?
    @State private var loading = false
    @State private var failure: String?
    @State private var showCreate = false
    var body: some View {
        Group {
            if !model.isConfigured { ConnectionPlaceholder() }
            else {
                ScrollViewReader { proxy in
                    List {
                        if let parent, picking != nil {
                            Button { picking?(parent) } label: { Label("选择此目录", systemImage: "checkmark.circle") }
                        } else if let parent, noteID != "root" {
                            NavigationLink { NoteDetailView(noteID: parent.id) } label: {
                                Label(parent.id == highlightedNoteID ? parent.title : "查看本笔记", systemImage: "doc.text.magnifyingglass")
                            }
                            .listRowBackground(parent.id == highlightedNoteID ? Color(.systemGray5) : nil)
                        }
                        if let draftTitle, let onResumeDraft {
                            Button(action: onResumeDraft) {
                                VStack(alignment: .leading, spacing: 4) {
                                    Text(draftTitle).foregroundStyle(.primary)
                                    Text("本机草稿").font(.caption).foregroundStyle(.secondary)
                                }.padding(.vertical, 6)
                            }
                        }
                        ForEach(entries) { entry in
                            HStack {
                                if let picking {
                                    Button { picking(entry.note) } label: { NoteRow(note: entry.note, title: entry.title) }
                                        .buttonStyle(.plain)
                                } else if entry.note.id == highlightedNoteID, let onHighlightedNote {
                                    Button(action: onHighlightedNote) { NoteRow(note: entry.note, title: entry.title) }
                                        .buttonStyle(.plain)
                                } else {
                                    NavigationLink { NoteDetailView(noteID: entry.note.id, directoryID: noteID) } label: { NoteRow(note: entry.note, title: entry.title) }
                                }
                                if !entry.note.childNoteIds.isEmpty || picking != nil {
                                    NavigationLink {
                                        NotebookView(noteID: entry.note.id, title: entry.title, picking: picking)
                                    } label: {
                                        Image(systemName: "folder").padding(12).accessibilityLabel("打开 \(entry.title) 的子目录")
                                    }.buttonStyle(.borderless).fixedSize()
                                }
                            }
                            .id(entry.id)
                            .listRowBackground(entry.note.id == highlightedNoteID ? Color(.systemGray5) : nil)
                        }
                        if let failure {
                            Text(failure).foregroundStyle(.secondary)
                            Button("重试") { Task { await load() } }
                        }
                    }
                    .overlay {
                        if loading && entries.isEmpty { ProgressView("加载目录…") }
                        else if entries.isEmpty && failure == nil && parent != nil && picking == nil && draftTitle == nil {
                            ContentUnavailableView("暂无子笔记", systemImage: "folder", description: Text("点击右上角 + 在此目录创建笔记。"))
                                .allowsHitTesting(false)
                        }
                    }
                    .refreshable { await load() }
                    .onChange(of: entries.map(\.id)) { _, _ in
                        if let entry = entries.first(where: { $0.note.id == highlightedNoteID }) {
                            proxy.scrollTo(entry.id, anchor: .center)
                        }
                    }
                }
            }
        }
        .navigationTitle(title)
        .toolbar {
            if picking == nil && model.isConfigured {
                ToolbarItem(placement: .topBarTrailing) { Button { showCreate = true } label: { Image(systemName: "plus") }.accessibilityLabel("新建笔记") }
            }
        }
        .sheet(isPresented: $showCreate) { CreateNoteView(parentID: noteID) { _ in Task { await load() } } }
        .task(id: model.changeVersion) { await load() }
    }
    private func load() async {
        guard model.isConfigured else { return }
        loading = true; failure = nil
        defer { loading = false }
        do {
            let api = try model.client()
            async let metadata = api.note(noteID)
            async let children = api.children(noteID)
            let result = try await (metadata, children)
            try Task.checkCancellation()
            parent = result.0; entries = result.1
        } catch {
            if error is CancellationError || (error as? URLError)?.code == .cancelled { return }
            failure = error.localizedDescription
        }
    }
}

struct CreateNoteView: View {
    @EnvironmentObject private var model: AppModel
    @Environment(\.dismiss) private var dismiss
    let parentID: String
    let onCreated: (Note) -> Void
    @State private var title = ""
    @State private var text = ""
    @State private var saving = false
    @State private var confirmDiscard = false
    var body: some View {
        NavigationStack {
            Form {
                Section("标题") { TextField("新笔记", text: $title) }
                Section("内容") { TextEditor(text: $text).frame(minHeight: 220) }
            }
            .disabled(saving)
            .navigationTitle("新建笔记")
            .toolbar {
                ToolbarItem(placement: .cancellationAction) {
                    Button("取消") {
                        if title.isEmpty && text.isEmpty { dismiss() } else { confirmDiscard = true }
                    }.disabled(saving)
                }
                ToolbarItem(placement: .confirmationAction) {
                    Button(saving ? "保存中…" : "创建") {
                        saving = true
                        Task {
                            defer { saving = false }
                            do {
                                let note = try await model.client().create(parentID: parentID, title: title.trimmingCharacters(in: .whitespacesAndNewlines), content: HTMLText.paragraphs(text))
                                model.changeVersion += 1; onCreated(note); dismiss()
                            } catch { model.report(error) }
                        }
                    }.disabled(saving || title.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty)
                }
            }
            .interactiveDismissDisabled(saving || !title.isEmpty || !text.isEmpty)
            .confirmationDialog("放弃这条未保存的新笔记？", isPresented: $confirmDiscard, titleVisibility: .visible) {
                Button("放弃", role: .destructive) { dismiss() }
                Button("继续编辑", role: .cancel) { }
            }
        }
    }
}
