import SwiftUI

struct SettingsView: View {
    @EnvironmentObject private var model: AppModel
    @State private var config = ServerConfiguration()
    @State private var token = ""
    @State private var aiKey = ""
    @State private var testing = false
    @State private var status: String?
    @State private var loaded = false
    var body: some View {
        Form {
            Section {
                TextField("https://notes.example.com", text: $config.address).keyboardType(.URL)
                SecureField("ETAPI 令牌", text: $token)
                Button {
                    Task { await test() }
                } label: {
                    HStack { Text("测试连接"); if testing { Spacer(); ProgressView() } }
                }.disabled(testing || token.isEmpty)
                if let status { Text(status).font(.footnote).foregroundStyle(.secondary) }
            } header: { Text("Trilium 服务") } footer: {
                Text("在 Trilium 设置 → ETAPI 中创建令牌。填写服务的基础地址，支持子路径，无需添加 /etapi。")
            }
            Section {
                TextField("https://api.openai.com/v1", text: $config.aiAddress).keyboardType(.URL)
                SecureField("模型 API Key", text: $aiKey)
                TextField("模型名称", text: $config.aiModel)
                TextField("默认保存目录的笔记 ID", text: $config.aiSaveParentID)
            } header: { Text("AI · OpenAI 兼容接口") } footer: {
                Text("填写包含 /v1 的 API 基础地址。AI 独立连接模型服务；API Key 与 ETAPI 令牌保存在本机 Keychain。对话发送给所配置的模型服务。")
            }
            Section {
                Toggle("允许 HTTP 连接", isOn: $config.allowHTTP)
            } footer: { Text("仅在你信任的网络使用 HTTP；HTTP 会明文传输笔记、令牌和模型密钥。HTTPS 为默认选项。") }
            Section {
                Button("保存设置") {
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
        .textInputAutocapitalization(.never).autocorrectionDisabled()
        .navigationTitle("设置")
        .onAppear {
            guard !loaded else { return }; loaded = true
            config = model.configuration; token = model.token; aiKey = model.aiKey
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
