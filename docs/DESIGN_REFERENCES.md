# iPhone 阅读与记录设计参考

本次正文空白及快速记录返回体验修复参考 [StephenArg/Trinote](https://github.com/StephenArg/Trinote)，核对提交 `4afea60dae7d0c2e6a857e213733485758f4381e`。参考其架构和交互思路，当前代码独立实现，没有复制该项目源码或引入依赖。

- [HTMLNoteView](https://github.com/StephenArg/Trinote/blob/4afea60dae7d0c2e6a857e213733485758f4381e/Trinote/Features/NoteDetail/HTMLNoteView.swift) 为 HTML 阅读器提供明确的显示尺寸和浅色／深色文字颜色。本项目让 WebView 填满笔记正文区域，保留 WebKit 原生滚动作为唯一正文滚动容器。
- [RichTextEditorView](https://github.com/StephenArg/Trinote/blob/4afea60dae7d0c2e6a857e213733485758f4381e/Trinote/Features/NoteDetail/RichTextEditorView.swift) 区分编辑页面准备完成和正文注入。本项目在页面导航完成后验证 JavaScript 函数，等待正文执行成功才记录已应用内容；失败则显示文字回退、重试或源码编辑入口。
- [MainTabView](https://github.com/StephenArg/Trinote/blob/4afea60dae7d0c2e6a857e213733485758f4381e/Trinote/App/MainTabView.swift) 与 [CalendarNoteView](https://github.com/StephenArg/Trinote/blob/4afea60dae7d0c2e6a857e213733485758f4381e/Trinote/Features/NoteDetail/CalendarNoteView.swift) 保留标签页独立导航根。本项目保留今天首页，在独立 sheet 内记录；有明确的「返回今天」和键盘「完成」按钮，保存后回到今天页，再由用户选择查看笔记。

Trinote 采用浏览器会话／CSRF 认证并要求 iOS 18；本项目继续使用 ETAPI 与 iOS 17。没有引入该项目的 iOS 18 专属 tab bar UIKit 调整。

本次静态分析确认了原实现忽略 JavaScript 执行错误并过早缓存已应用正文的问题；显示区域缺少明确尺寸也是可能导致空白的因素。具体真机根因仍需新版 IPA 验证。新增原生 WKWebView XCTest 覆盖中文正文、未编辑的源码保持及脚本净化，由 GitHub Actions 执行；不进行本地构建或浏览器测试。

后续继续报告完全空白后，检查发现详情页首次状态 `note == nil && loading == false` 没有任何实际子视图，加载任务依附于空的条件 Group。详情页改为始终存在的 VStack，在元数据到达前显示加载占位，保障 task 的生命周期。此前只直接创建 WKWebView 的测试无法覆盖这一步；补充从 SwiftUI NoteDetailView 挂载开始的测试，覆盖请求发起、正文显示、服务端失败及缓存内容。正文菜单也提供独立于 WebKit 的纯文字阅读入口。
