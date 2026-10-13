import SwiftUI

struct TodayView: View {
    @EnvironmentObject private var model: AppModel
    @State private var note: Note?
    @State private var loading = false
    @State private var quickText = ""
    @State private var creating = false
    @State private var created: Note?
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
                        }.buttonStyle(.borderedProminent).disabled(loading || creating)
                        VStack(alignment: .leading, spacing: 12) {
                            Label("快速记录", systemImage: "square.and.pencil").font(.headline)
                            TextEditor(text: $quickText).frame(minHeight: 180).padding(8).disabled(creating)
                                .background(.background, in: RoundedRectangle(cornerRadius: 14))
                                .overlay(RoundedRectangle(cornerRadius: 14).stroke(.quaternary))
                            Text("保存为今日日记下面的一条子笔记，保留日记模板和已有内容。").font(.footnote).foregroundStyle(.secondary)
                            Button(creating ? "保存中…" : "保存到今天") { Task { await capture() } }
                                .buttonStyle(.bordered).disabled(quickText.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty || creating || loading)
                        }
                    }.padding(24)
                }
                .background(Color(.systemGroupedBackground))
            }
        }
        .navigationTitle("今天").navigationBarTitleDisplayMode(.inline)
        .navigationDestination(item: $note) { NoteDetailView(noteID: $0.id) }
        .navigationDestination(item: $created) { NoteDetailView(noteID: $0.id) }
        .onAppear { quickText = LocalStore().load(draftName, as: String.self) ?? "" }
        .onChange(of: quickText) { _, value in
            do { try LocalStore().save(value, name: draftName) } catch { model.report(error) }
        }
    }
    private var draftName: String { LocalStore.scopedName("capture", server: model.configuration.address) }
    private func openToday() async {
        loading = true; defer { loading = false }
        do { note = try await model.client().dayNote(); model.changeVersion += 1 } catch { model.report(error) }
    }
    private func capture() async {
        creating = true; defer { creating = false }
        do {
            let api = try model.client()
            let day = try await api.dayNote()
            let firstLine = quickText.components(separatedBy: .newlines).first ?? "随手记"
            let formatter = DateFormatter(); formatter.dateFormat = "HH:mm"
            let result = try await api.create(parentID: day.id, title: "\(formatter.string(from: Date())) · \(firstLine.prefix(40))", content: HTMLText.paragraphs(quickText))
            quickText = ""; created = result; model.changeVersion += 1
        } catch { model.report(error) }
    }
}
