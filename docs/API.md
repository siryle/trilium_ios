# 接口实现依据

核对版本：TriliumNext v0.106.0 与当前 main。未调用私有浏览器 API。各服务端可通过 `/etapi/etapi.openapi.yaml` 查看自己的契约。

| 行为 | 接口与关键约定 |
| --- | --- |
| 认证 | `Authorization: <ETAPI token>`，使用原始令牌；客户端不收集 Trilium 登录密码。 |
| 连接检查 | `GET /etapi/app-info`，读取 `appVersion`。 |
| 目录 | `GET /etapi/notes/root` 或 `/notes/{id}`；从 `childBranchIds` 读取 `/branches/{id}`，按 `notePosition` 排序并显示 `prefix`。branch 标识一个位置，同一 note 可属于多个目录。最多 8 个位置读取任务并发，URLSession 同主机最多 6 个连接。 |
| 正文 | `GET /etapi/notes/{id}/content` 返回原始数据，不是 JSON。 |
| 保存正文 | `PUT /etapi/notes/{id}/content` 发送 UTF-8 原始字符串，传输 MIME 必须为 `text/plain; charset=utf-8`，即使笔记 MIME 为 `text/html`。成功返回 204。 |
| 保存标题 | `PATCH /etapi/notes/{id}` 只发送 `{title}`；不能回传只读字段。 |
| 新建 | `POST /etapi/create-note` 发送 `parentNoteId,title,type,mime,content`，读取 `{note,branch}`；不强制 ID。 |
| 今天 | `GET /etapi/calendar/days/yyyy-MM-dd` 获取或创建日期笔记，并遵循服务端模板。仅在用户主动操作时调用。使用本地时区、Gregorian 日历和小写 `yyyy`。 |
| 搜索 | `GET /etapi/notes?search=...&ancestorNoteId=root&fastSearch=false&limit=100`；结果 `{results:[Note]}`。目录选择时替换 `ancestorNoteId`。使用 URLQueryItem 并额外编码 `+`，避免 Express 将字面加号解释为空格。 |

保护笔记通过 ETAPI 无法解锁。DTO 的 `type` 保留为字符串，以兼容新版本类型；未知类型不开放编辑。元数据日期保留字符串，因为笔记时间戳并非统一 ISO 8601。

搜索未提供 offset、cursor、total 或 snippet，不宣称实现无限分页。没有使用实现存在歧义的 `orderDirection` 参数。

ETAPI 更新没有 `If-Match` 或原子条件保存。客户端先比较正文与标题，只能发现检查之前的修改；检查与写入之间仍存在竞态。标题和正文部分成功时，分别更新本地保存基线并保留剩余草稿。

## AI 服务

Trilium 官方 AI 浏览器接口 `/api/llm-chat/stream` 受浏览器会话和 CSRF 中间件保护，不接受 ETAPI 令牌。客户端使用单独配置的 OpenAI 兼容服务：

```http
POST <provider-base>/chat/completions
Content-Type: application/json
Accept: text/event-stream
Authorization: Bearer <user-api-key>
```

```json
{"model":"user-configured-model","messages":[{"role":"user","content":"hello"}],"stream":true}
```

模型服务基础地址按用户填写保留子路径，不自动补 `/v1`。兼容无密钥的本地模型服务，空密钥时省略 Authorization。

SSE 按字节组装 UTF-8 行，处理 CR/LF、空行事件边界、注释心跳及多行 data。读取 `choices[0].delta.content`，`[DONE]` 或 finish_reason 确认正常结束；内容过滤、长度限制、工具请求及异常关闭标记为未完成。未完成回复排除在后续 assistant 历史之外。

保存采用 ETAPI 普通 HTML 笔记，不依赖版本变化较快的原生 `llmChat` JSON schema。不保存 API Key。

## 官方来源

- [v0.106.0 OpenAPI](https://github.com/TriliumNext/Trilium/blob/v0.106.0/apps/server/src/assets/etapi.openapi.yaml)
- [Note routes](https://github.com/TriliumNext/Trilium/blob/v0.106.0/apps/server/src/etapi/notes.ts)
- [DTO mapping](https://github.com/TriliumNext/Trilium/blob/main/apps/server/src/etapi/mappers.ts)
- [Calendar routes](https://github.com/TriliumNext/Trilium/blob/main/apps/server/src/etapi/special_notes.ts)
- [Calendar service](https://github.com/TriliumNext/Trilium/blob/main/packages/trilium-core/src/services/date_notes.ts)
- [ETAPI guide](https://github.com/TriliumNext/Trilium/blob/main/docs/User%20Guide/User%20Guide/Advanced%20Usage/ETAPI%20%28REST%20API%29.md)
- [Browser route authentication](https://github.com/TriliumNext/Trilium/blob/main/apps/server/src/routes/routes.ts)
- [Browser chat implementation](https://github.com/TriliumNext/Trilium/blob/main/apps/server/src/routes/api/llm_chat.ts)
