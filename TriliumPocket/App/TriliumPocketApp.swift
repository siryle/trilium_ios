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
                .tabItem { AppTab.notes.label }.tag(AppTab.notes.rawValue)
            NavigationStack { TodayView() }
                .tabItem { AppTab.today.label }.tag(AppTab.today.rawValue)
            NavigationStack { SearchView() }
                .tabItem { AppTab.search.label }.tag(AppTab.search.rawValue)
            NavigationStack { ChatView() }
                .tabItem { AppTab.chat.label }.tag(AppTab.chat.rawValue)
            NavigationStack { SettingsView() }
                .tabItem { AppTab.settings.label }.tag(AppTab.settings.rawValue)
        }
        .id(model.connectionID)
        .alert("操作未完成", isPresented: Binding(get: { model.error != nil }, set: { if !$0 { model.error = nil } })) {
            Button("知道了", role: .cancel) { model.error = nil }
        } message: { Text(model.error ?? "") }
    }
}

enum AppTab: Int, CaseIterable, Identifiable {
    case notes, today, search, chat, settings
    var id: Int { rawValue }
    var title: String {
        switch self {
        case .notes: return "笔记"
        case .today: return "今天"
        case .search: return "搜索"
        case .chat: return "AI"
        case .settings: return "设置"
        }
    }
    var icon: String {
        switch self {
        case .notes: return "books.vertical"
        case .today: return "calendar"
        case .search: return "magnifyingglass"
        case .chat: return "bubble.left.and.bubble.right"
        case .settings: return "gearshape"
        }
    }
    @MainActor var label: some View { Label(title, systemImage: icon) }
}

@MainActor
struct FloatingAppNavigation: View {
    let selectedTab: Int
    let onSelect: (AppTab) -> Void

    var body: some View {
        HStack(spacing: 0) {
            ForEach(AppTab.allCases) { tab in
                Button { onSelect(tab) } label: {
                    VStack(spacing: 4) {
                        Image(systemName: tab.icon).font(.system(size: 21))
                        Text(tab.title).font(.caption2)
                    }
                    .frame(maxWidth: .infinity, minHeight: 54)
                    .contentShape(Rectangle())
                }
                .foregroundStyle(selectedTab == tab.rawValue ? Color.teal : Color.secondary)
                .accessibilityLabel(tab.title)
                .accessibilityAddTraits(selectedTab == tab.rawValue ? .isSelected : [])
            }
        }
        .buttonStyle(.plain)
        .padding(.horizontal, 8).padding(.vertical, 4)
        .background(.regularMaterial, in: Capsule())
        .shadow(color: .black.opacity(0.12), radius: 14, y: 4)
        .padding(.horizontal, 16).padding(.top, 4).padding(.bottom, 8)
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
