import SwiftUI

@main
struct TriliumPocketApp: App {
    @StateObject private var model = AppModel()
    var body: some Scene {
        WindowGroup { RootView().environmentObject(model).tint(.teal) }
    }
}

struct RootView: View {
    @EnvironmentObject private var model: AppModel
    var body: some View {
        TabView(selection: $model.selectedTab) {
            NavigationStack { NotebookView(noteID: "root", title: "笔记") }
                .tabItem { Label("笔记", systemImage: "books.vertical") }.tag(0)
            NavigationStack { TodayView() }
                .tabItem { Label("今天", systemImage: "calendar") }.tag(1)
            NavigationStack { SearchView() }
                .tabItem { Label("搜索", systemImage: "magnifyingglass") }.tag(2)
            NavigationStack { ChatView() }
                .tabItem { Label("AI", systemImage: "bubble.left.and.bubble.right") }.tag(3)
            NavigationStack { SettingsView() }
                .tabItem { Label("设置", systemImage: "gearshape") }.tag(4)
        }
        .id(model.connectionID)
        .alert("操作未完成", isPresented: Binding(get: { model.error != nil }, set: { if !$0 { model.error = nil } })) {
            Button("知道了", role: .cancel) { model.error = nil }
        } message: { Text(model.error ?? "") }
    }
}

struct ConnectionPlaceholder: View {
    @EnvironmentObject private var model: AppModel
    var body: some View {
        ContentUnavailableView {
            Label("连接你的知识库", systemImage: "books.vertical")
        } description: {
            Text("填写 Trilium 服务地址和 ETAPI 令牌，即可浏览和编辑你的笔记。")
        } actions: {
            Button("前往设置") { model.selectedTab = 4 }.buttonStyle(.borderedProminent)
        }
    }
}

struct NoteRow: View {
    let note: Note
    var title: String? = nil
    var body: some View {
        HStack(spacing: 12) {
            Image(systemName: note.icon).foregroundStyle(.teal).frame(width: 24)
            VStack(alignment: .leading, spacing: 4) {
                Text(title ?? note.title).lineLimit(2)
                if !note.childNoteIds.isEmpty {
                    Text("\(note.childNoteIds.count) 个子笔记").font(.caption).foregroundStyle(.secondary)
                }
            }
            Spacer(minLength: 0)
        }.padding(.vertical, 6)
    }
}
