import SwiftUI

struct TodayView: View {
    @EnvironmentObject private var model: AppModel
    @State private var note: Note?
    @State private var loading = false
    @State private var quickText = ""
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
                            if !quickText.isEmpty {
                                Text(quickText).lineLimit(3).foregroundStyle(.secondary)
                                Label("本机草稿已保留", systemImage: "doc.badge.clock").font(.caption).foregroundStyle(.secondary)
                            }
                            Button(quickText.isEmpty ? "写一条记录" : "继续草稿") { showCapture = true }
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
        .sheet(isPresented: $showCapture) {
            QuickCaptureView(text: $quickText) { saved in lastCapture = saved }
        }
        .onAppear {
            guard !draftLoaded else { return }; draftLoaded = true
            quickText = LocalStore().load(draftName, as: String.self) ?? ""
        }
        .onChange(of: quickText) { _, value in
            do { try LocalStore().save(value, name: draftName) } catch { model.report(error) }
        }
    }
    private var draftName: String { LocalStore.scopedName("capture", server: model.configuration.address) }
    private func openToday() async {
        loading = true; defer { loading = false }
        do { note = try await model.client().dayNote(); model.changeVersion += 1 } catch { model.report(error) }
    }
}

private struct QuickCaptureView: View {
    @EnvironmentObject private var model: AppModel
    @Environment(\.dismiss) private var dismiss
    @Binding var text: String
    let onSaved: (Note) -> Void
    @State private var saving = false
    @FocusState private var focused: Bool

    var body: some View {
        NavigationStack {
            VStack(alignment: .leading, spacing: 12) {
                Text("记录会保存为今日日记的子笔记。返回今天时，未保存的草稿会保留。")
                    .font(.footnote).foregroundStyle(.secondary)
                TextEditor(text: $text).focused($focused).disabled(saving)
                    .scrollContentBackground(.hidden)
                    .frame(maxWidth: .infinity, maxHeight: .infinity)
            }.padding(20)
            .background(Color(.systemBackground))
            .navigationTitle("快速记录").navigationBarTitleDisplayMode(.inline)
            .toolbar {
                ToolbarItem(placement: .cancellationAction) {
                    Button("返回今天") { focused = false; dismiss() }.disabled(saving)
                }
                ToolbarItem(placement: .confirmationAction) {
                    Button(saving ? "保存中…" : "保存") { Task { await capture() } }
                        .disabled(saving || text.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty)
                }
                ToolbarItemGroup(placement: .keyboard) {
                    Spacer()
                    Button("完成") { focused = false }
                }
            }
            .interactiveDismissDisabled(saving)
        }
    }
    private func capture() async {
        guard !saving else { return }
        focused = false
        let snapshot = text
        saving = true; defer { saving = false }
        do {
            let api = try model.client()
            let day = try await api.dayNote()
            let firstLine = snapshot.components(separatedBy: .newlines).first ?? "随手记"
            let formatter = DateFormatter(); formatter.dateFormat = "HH:mm"
            let result = try await api.create(parentID: day.id, title: "\(formatter.string(from: Date())) · \(firstLine.prefix(40))", content: HTMLText.paragraphs(snapshot))
            text = ""; onSaved(result); model.changeVersion += 1; dismiss()
        } catch { model.report(error) }
    }
}
