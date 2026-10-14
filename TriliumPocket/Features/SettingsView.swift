import SwiftUI

struct SettingsView: View {
    @EnvironmentObject private var model: AppModel
    @State private var config = ServerConfiguration()
    @State private var token = ""
    @State private var aiKey = ""
    @State private var testing = false
    @State private var status: String?
    @State private var loaded = false
    @State private var visible = false
    @State private var availableModels: [String] = []
    @State private var refreshingModels = false
    @State private var modelStatus: String?
    @State private var modelRefreshID: UUID?
    @FocusState private var focusedField: Field?

    private enum Field: Hashable { case address, token, aiAddress, aiKey, saveParentID }
    private struct ModelSource: Equatable {
        let address: String
        let key: String
        let allowHTTP: Bool
    }

    private var modelSource: ModelSource {
        ModelSource(address: config.aiAddress, key: aiKey, allowHTTP: config.allowHTTP)
    }

    var body: some View {
        Form {
            Section {
                TextField("https://notes.example.com", text: $config.address)
                    .keyboardType(.URL).focused($focusedField, equals: .address)
                SecureField("ETAPI 令牌", text: $token).focused($focusedField, equals: .token)
                Button {
                    focusedField = nil
                    Task { await test() }
                } label: {
                    HStack { Text("测试连接"); if testing { Spacer(); ProgressView() } }
                }.disabled(testing || token.isEmpty)
                if let status { Text(status).font(.footnote).foregroundStyle(.secondary) }
            } header: { Text("Trilium 服务") } footer: {
                Text("在 Trilium 设置 → ETAPI 中创建令牌。填写服务的基础地址，支持子路径，无需添加 /etapi。")
            }
            Section {
                TextField("https://api.openai.com/v1", text: $config.aiAddress)
                    .keyboardType(.URL).focused($focusedField, equals: .aiAddress)
                SecureField("模型 API Key", text: $aiKey).focused($focusedField, equals: .aiKey)
                Button {
                    focusedField = nil
                    modelRefreshID = UUID()
                } label: {
                    HStack {
                        Text("刷新模型列表")
                        if refreshingModels { Spacer(); ProgressView() }
                    }
                }.disabled(refreshingModels || config.aiAddress.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty)
                Picker("AI 模型", selection: $config.aiModel) {
                    Text("请选择模型").tag("")
                    if !config.aiModel.isEmpty && !availableModels.contains(config.aiModel) {
                        Text("\(config.aiModel)（当前配置，待刷新）").tag(config.aiModel)
                    }
                    ForEach(availableModels, id: \.self) { Text($0).tag($0) }
                }
                .pickerStyle(.menu)
                .disabled(refreshingModels || availableModels.isEmpty)
                if let modelStatus { Text(modelStatus).font(.footnote).foregroundStyle(.secondary) }
                TextField("默认保存目录的笔记 ID", text: $config.aiSaveParentID)
                    .focused($focusedField, equals: .saveParentID)
            } header: { Text("AI · OpenAI 兼容接口") } footer: {
                Text("填写包含 /v1 的 API 基础地址和 API Key，刷新模型列表后手动选择模型。AI 独立连接模型服务；API Key 与 ETAPI 令牌保存在本机 Keychain。对话发送给所配置的模型服务。")
            }
            Section {
                Toggle("允许 HTTP 连接", isOn: $config.allowHTTP)
            } footer: { Text("仅在你信任的网络使用 HTTP；HTTP 会明文传输笔记、令牌和模型密钥。HTTPS 为默认选项。") }
            Section {
                Button("保存设置") {
                    focusedField = nil
                    do {
                        config.address = config.address.trimmingCharacters(in: .whitespacesAndNewlines)
                        config.aiAddress = config.aiAddress.trimmingCharacters(in: .whitespacesAndNewlines)
                        config.aiSaveParentID = config.aiSaveParentID.trimmingCharacters(in: .whitespacesAndNewlines)
                        if config.aiSaveParentID.isEmpty { config.aiSaveParentID = "root" }
                        try model.saveConfiguration(config, token: token, aiKey: aiKey)
                        model.selectedTab = 0
                    } catch { model.report(error) }
                }.disabled(testing || token.isEmpty || config.address.isEmpty)
            }
            Section("关于") {
                LabeledContent("客户端", value: "Trilium Pocket")
                Text("为 iPhone 设计的独立客户端，使用 Trilium ETAPI。受保护笔记和特殊笔记类型暂不编辑。")
                    .font(.footnote).foregroundStyle(.secondary)
            }
        }
        .background(KeyboardDismissOnTap(isEnabled: visible) { focusedField = nil })
        .scrollDismissesKeyboard(.interactively)
        .textInputAutocapitalization(.never).autocorrectionDisabled()
        .navigationTitle("设置")
        .toolbar {
            ToolbarItemGroup(placement: .keyboard) {
                Spacer()
                Button("收起键盘") { focusedField = nil }
            }
        }
        .onAppear {
            visible = true
            guard !loaded else { return }; loaded = true
            config = model.configuration; token = model.token; aiKey = model.aiKey
        }
        .onDisappear {
            visible = false
            focusedField = nil
            modelRefreshID = nil
            refreshingModels = false
        }
        .onChange(of: modelSource) { invalidateModels() }
        .task(id: modelRefreshID) {
            guard let id = modelRefreshID else { return }
            await refreshModels(id: id)
        }
    }

    private func invalidateModels() {
        modelRefreshID = nil
        refreshingModels = false
        availableModels = []
        modelStatus = nil
    }

    @MainActor
    private func refreshModels(id: UUID) async {
        guard !Task.isCancelled, modelRefreshID == id else { return }
        let source = modelSource
        refreshingModels = true
        modelStatus = nil
        defer { if modelRefreshID == id { refreshingModels = false } }
        do {
            let client = try AIClient(address: source.address, apiKey: source.key, allowHTTP: source.allowHTTP)
            let identifiers = try await client.models()
            guard !Task.isCancelled, modelRefreshID == id, modelSource == source else { return }
            availableModels = identifiers
            if !identifiers.contains(config.aiModel) { config.aiModel = "" }
            modelStatus = identifiers.isEmpty ? "服务未返回可用模型，请检查接口配置后重试。" : "已获取 \(identifiers.count) 个模型，请手动选择。"
        } catch {
            guard !Task.isCancelled, modelRefreshID == id, modelSource == source else { return }
            modelStatus = error.localizedDescription
        }
    }
    private func test() async {
        testing = true; status = nil
        defer { testing = false }
        do {
            let client = APIClient(baseURL: try APIClient.validatedURL(config.address, allowHTTP: config.allowHTTP), token: token.trimmingCharacters(in: .whitespacesAndNewlines))
            let info = try await client.appInfo()
            status = "连接成功 · Trilium \(info.appVersion)"
        } catch { model.report(error) }
    }
}
