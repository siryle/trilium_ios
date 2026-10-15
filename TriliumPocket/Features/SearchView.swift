import SwiftUI

struct SearchView: View {
    @EnvironmentObject private var model: AppModel
    @State private var query = ""
    @State private var results: [Note] = []
    @State private var searching = false
    @State private var failure: String?
    @State private var scope: Note?
    @State private var picking = false
    @State private var revision = 0
    var body: some View {
        Group {
            if !model.isConfigured { ConnectionPlaceholder() }
            else {
                List {
                    Section {
                        Button { picking = true } label: {
                            Label(scope.map { "搜索目录：\($0.title)" } ?? "搜索全部笔记", systemImage: "folder")
                        }
                        if scope != nil { Button("清除目录范围") { scope = nil; revision += 1 } }
                    }
                    ForEach(results) { note in
                        NavigationLink { NoteDetailView(noteID: note.id) } label: { NoteRow(note: note) }
                    }
                    if results.count == 100 { Text("已显示 100 条结果，请增加关键词缩小范围。").font(.footnote).foregroundStyle(.secondary) }
                    if let failure { Text(failure).foregroundStyle(.secondary); Button("重试") { revision += 1 } }
                }
                .overlay {
                    if searching { ProgressView("搜索中…") }
                    else if results.isEmpty && failure == nil {
                        ContentUnavailableView(query.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty ? "搜索你的知识库" : "没有找到笔记", systemImage: "magnifyingglass", description: Text("支持标题和正文搜索，也可使用 #标签 或 Trilium 搜索语法。"))
                            .allowsHitTesting(false).padding(.top, 90)
                    }
                }
            }
        }
        .navigationTitle("搜索")
        .searchable(text: $query, prompt: "标题、正文或 #标签")
        .task(id: "\(query)|\(scope?.id ?? "root")|\(revision)|\(model.changeVersion)") { await search() }
        .onChange(of: model.changeVersion) { _, _ in
            if let scope, model.isNoteDeleted(scope.id) { self.scope = nil }
        }
        .sheet(isPresented: $picking) {
            NavigationStack {
                NotebookView(noteID: "root", title: "选择搜索目录", picking: { scope = $0; picking = false; revision += 1 })
                    .toolbar { ToolbarItem(placement: .cancellationAction) { Button("取消") { picking = false } } }
            }
        }
    }
    private func search() async {
        results = []; failure = nil
        let value = query.trimmingCharacters(in: .whitespacesAndNewlines)
        guard model.isConfigured, !value.isEmpty else { searching = false; return }
        searching = true
        do {
            try await Task.sleep(for: .milliseconds(350))
            let response: SearchResponse = try await model.client().decode("notes", query: [
                URLQueryItem(name: "search", value: value), URLQueryItem(name: "ancestorNoteId", value: scope?.id ?? "root"),
                URLQueryItem(name: "fastSearch", value: "false"), URLQueryItem(name: "limit", value: "100")])
            try Task.checkCancellation()
            results = response.results; searching = false
        } catch {
            guard !Task.isCancelled else { return }
            failure = error.localizedDescription; searching = false
        }
    }
}
