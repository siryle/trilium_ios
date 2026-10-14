import SwiftUI
import UIKit

struct TodayView: View {
    @EnvironmentObject private var model: AppModel
    @State private var note: Note?
    @State private var loading = false
    @State private var draft = QuickCaptureDraft()
    @State private var showCapture = false
    @State private var lastCapture: Note?
    @State private var draftLoaded = false

    var body: some View {
        Group {
            if !model.isConfigured { ConnectionPlaceholder() }
            else {
                ScrollView {
                    VStack(alignment: .leading, spacing: 24) {
                        VStack(alignment: .leading, spacing: 8) {
                            Text(Date.now, format: .dateTime.weekday(.wide)).font(.headline).foregroundStyle(.teal)
                            Text(Date.now, format: .dateTime.year().month(.wide).day()).font(.largeTitle.bold())
                            Text("把今天值得记住的事留下来。").foregroundStyle(.secondary)
                        }
                        Button { Task { await openToday() } } label: {
                            Label(loading ? "打开中…" : "打开 / 创建今日日记", systemImage: "calendar.badge.plus")
                                .frame(maxWidth: .infinity).padding(10)
                        }.buttonStyle(.borderedProminent).disabled(loading)
                        VStack(alignment: .leading, spacing: 12) {
                            Label("快速记录", systemImage: "square.and.pencil").font(.headline)
                            Text("保存为今日日记下面的一条子笔记，保留日记模板和已有内容。")
                                .font(.footnote).foregroundStyle(.secondary)
                            if !draft.isEmpty {
                                if !draft.title.isEmpty { Text(draft.title).font(.headline) }
                                Text(draft.plainText).lineLimit(3).foregroundStyle(.secondary)
                                Label("本机草稿已保留", systemImage: "doc.badge.clock").font(.caption).foregroundStyle(.secondary)
                            }
                            Button(draft.isEmpty ? "写一条记录" : "继续草稿") { showCapture = true }
                                .buttonStyle(.bordered).disabled(loading)
                        }
                        if let lastCapture {
                            VStack(alignment: .leading, spacing: 10) {
                                Label("已保存到今天", systemImage: "checkmark.circle.fill").foregroundStyle(.teal)
                                Button { note = lastCapture } label: {
                                    Label(lastCapture.title, systemImage: "doc.text").lineLimit(2)
                                }
                            }
                        }
                    }.padding(24)
                }
                .background(Color(.systemGroupedBackground))
            }
        }
        .navigationTitle("今天").navigationBarTitleDisplayMode(.inline)
        .toolbar(.visible, for: .navigationBar, .tabBar)
        .navigationDestination(item: $note) { NoteDetailView(noteID: $0.id) }
        .fullScreenCover(isPresented: $showCapture) {
            QuickCaptureView(draft: $draft) { saved in lastCapture = saved }
        }
        .onAppear {
            guard !draftLoaded else { return }; draftLoaded = true
            let store = LocalStore()
            draft = store.load(draftName, as: QuickCaptureDraft.self)
                ?? QuickCaptureDraft(plainText: store.load(draftName, as: String.self) ?? "")
        }
        .onChange(of: draft) { _, value in
            do { try LocalStore().save(value, name: draftName) } catch { model.report(error) }
        }
    }
    private var draftName: String { LocalStore.scopedName("capture", server: model.configuration.address) }
    private func openToday() async {
        loading = true; defer { loading = false }
        do { note = try await model.client().dayNote(); model.changeVersion += 1 } catch { model.report(error) }
    }
}

struct QuickCaptureDraft: Codable, Equatable {
    var title = ""
    var content = ""

    init(title: String = "", content: String = "") {
        self.title = title; self.content = content
    }
    @MainActor init(plainText: String) {
        content = plainText.isEmpty ? "" : HTMLText.paragraphs(plainText)
    }
    @MainActor var plainText: String { HTMLText.plainText(content) }
    @MainActor var isEmpty: Bool { title.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty && plainText.isEmpty }
    @MainActor func noteTitle(at date: Date = .now) -> String {
        let title = self.title.trimmingCharacters(in: .whitespacesAndNewlines)
        if !title.isEmpty { return title }
        let formatter = DateFormatter(); formatter.dateFormat = "HH:mm"
        let firstLine = plainText.components(separatedBy: .newlines).first ?? ""
        return "\(formatter.string(from: date)) · \(firstLine.isEmpty ? "随手记" : String(firstLine.prefix(40)))"
    }
}

@MainActor
private struct QuickCaptureView: View {
    @EnvironmentObject private var model: AppModel
    @Environment(\.dismiss) private var dismiss
    @Binding var draft: QuickCaptureDraft
    let onSaved: (Note) -> Void
    @State private var saving = false
    @State private var preparingSave = false
    @State private var preview = false
    @State private var sourceEditing = false
    @State private var error: String?
    @State private var command: NoteWebView.EditorCommand?
    @State private var requestedFocus = false
    @State private var showDirectory = false
    @StateObject private var bridge = WebEditorBridge()
    @FocusState private var titleFocused: Bool

    private var busy: Bool { saving || preparingSave }

    var body: some View {
        NoteEditorSidebar(isPresented: showDirectory, onClose: closeDirectory) {
            editor
        } directory: {
            NoteDirectorySidebar(draftTitle: draft.title.trimmingCharacters(in: .whitespacesAndNewlines),
                                 onClose: closeDirectory)
        }
        .interactiveDismissDisabled(busy)
        .alert("无法完成操作", isPresented: Binding(get: { error != nil }, set: { if !$0 { error = nil } })) {
            Button("好", role: .cancel) { error = nil }
        } message: { Text(error ?? "") }
    }

    private var editor: some View {
        NoteEditorLayout(title: $draft.title, titleFocused: $titleFocused, command: $command,
                         preview: preview, busy: busy, saving: saving,
                         formattingEnabled: !sourceEditing && bridge.ready,
                         onDirectory: { Task { await openDirectory() } },
                         onPreview: { Task { await togglePreview() } },
                         onDismissKeyboard: hideKeyboard) {
            Button("保存到今日日记", systemImage: "checkmark") { Task { await capture() } }
                .disabled(draft.isEmpty || (!sourceEditing && !bridge.ready))
            Button("收起键盘", systemImage: "keyboard.chevron.compact.down", action: hideKeyboard)
            if sourceEditing {
                Button("切换到富文本编辑", systemImage: "textformat") { hideKeyboard(); sourceEditing = false }
                    .disabled(HTMLText.requiresSourceEditing(draft.content))
            }
            Button("返回今天，保留草稿", systemImage: "arrow.backward") { Task { await leave() } }
        } content: {
            if sourceEditing && !preview {
                TextEditor(text: $draft.content)
                    .font(.system(.body, design: .monospaced))
                    .textInputAutocapitalization(.never).autocorrectionDisabled()
                    .scrollContentBackground(.hidden).padding(.horizontal, 16)
                    .disabled(busy)
            } else if let api = try? model.client() {
                NoteHTMLContent(content: draft.content, editing: !preview && !saving,
                                api: api, bridge: bridge, command: command,
                                onChange: { draft.content = $0 },
                                onSourceEdit: { sourceEditing = true; preview = false },
                                onNoteLink: { _ in })
                    .frame(maxWidth: .infinity, maxHeight: .infinity)
                    .allowsHitTesting(!preparingSave)
            }
        }
        .onChange(of: bridge.isLoading) { _, loading in
            guard !loading, bridge.ready, !requestedFocus, !preview, !sourceEditing, !titleFocused, !busy, !showDirectory else { return }
            requestedFocus = true
            bridge.web?.evaluateJavaScript("document.getElementById('note').focus()", completionHandler: nil)
        }
    }

    private func hideKeyboard() {
        titleFocused = false
        bridge.web?.endEditing(true)
        // Also dismiss the native source editor when the renderer is not mounted.
        UIApplication.shared.sendAction(#selector(UIResponder.resignFirstResponder), to: nil, from: nil, for: nil)
    }
    private func flushEditor() async throws {
        titleFocused = false
        if !preview && !sourceEditing && bridge.ready {
            let previous = draft.content
            if let latest = try await bridge.flush() {
                guard draft.content == previous || draft.content == latest else {
                    throw UserFacingError(message: "编辑内容发生变化，草稿已保留，请重试。")
                }
                draft.content = latest
            }
        }
        hideKeyboard()
    }
    private func leave() async {
        guard !busy else { return }
        preparingSave = true; defer { preparingSave = false }
        do { try await flushEditor(); dismiss() } catch { self.error = error.localizedDescription }
    }
    private func openDirectory() async {
        guard !busy else { return }
        preparingSave = true; defer { preparingSave = false }
        do {
            try await flushEditor()
            requestedFocus = true
            withAnimation(.easeInOut(duration: 0.25)) { showDirectory = true }
        } catch { self.error = error.localizedDescription }
    }
    private func closeDirectory() {
        withAnimation(.easeInOut(duration: 0.25)) { showDirectory = false }
    }
    private func togglePreview() async {
        guard !busy else { return }
        preparingSave = true; defer { preparingSave = false }
        do { try await flushEditor(); preview.toggle() } catch { self.error = error.localizedDescription }
    }
    private func capture() async {
        guard !busy, !draft.isEmpty else { return }
        preparingSave = true
        defer { preparingSave = false; saving = false }
        do {
            try await flushEditor()
            let snapshot = draft
            saving = true
            let api = try model.client()
            let day = try await api.dayNote()
            let result = try await api.create(parentID: day.id, title: snapshot.noteTitle(), content: snapshot.content)
            draft = QuickCaptureDraft(); onSaved(result); model.changeVersion += 1; dismiss()
        } catch { self.error = error.localizedDescription }
    }
}
