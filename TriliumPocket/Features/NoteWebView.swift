import SwiftUI
import UIKit
import WebKit

@MainActor
private final class NoteEditorWebView: WKWebView {
    // The editor supplies its own formatting and keyboard dismissal controls.
    override var inputAccessoryView: UIView? { nil }
}

@MainActor
final class WebEditorBridge: ObservableObject {
    weak var web: WKWebView?
    var ready = false
    @Published var isLoading = true
    @Published var displayError: String?
    func flush() async throws -> String? {
        guard ready, let web else { throw UserFacingError(message: "编辑器正在准备，请稍后保存。") }
        web.endEditing(true)
        return try await web.evaluateJavaScript("flushNote()") as? String
    }
}

@MainActor
struct NoteWebView: UIViewRepresentable {
    let content: String
    let editing: Bool
    let api: APIClient
    let bridge: WebEditorBridge
    let command: EditorCommand?
    let onChange: (String) -> Void
    let onNoteLink: (String) -> Void
    struct EditorCommand: Equatable { let id = UUID(); let name: String; var value: String? = nil }

    // Reuse one in-memory store so opening another note does not create a new networking session.
    private static let dataStore = WKWebsiteDataStore.nonPersistent()
    func makeCoordinator() -> Coordinator { Coordinator(self) }
    func makeUIView(context: Context) -> WKWebView { makeWebView(coordinator: context.coordinator) }
    func makeWebView(coordinator: Coordinator) -> WKWebView {
        let configuration = WKWebViewConfiguration()
        configuration.websiteDataStore = Self.dataStore
        configuration.defaultWebpagePreferences.allowsContentJavaScript = true
        configuration.userContentController.add(coordinator, name: "edited")
        configuration.setURLSchemeHandler(coordinator, forURLScheme: "trilium-resource")
        let web = NoteEditorWebView(frame: .zero, configuration: configuration)
        web.inputAssistantItem.leadingBarButtonGroups = []
        web.inputAssistantItem.trailingBarButtonGroups = []
        web.navigationDelegate = coordinator
        web.isOpaque = false; web.backgroundColor = .systemBackground
        web.scrollView.backgroundColor = .systemBackground
        web.scrollView.contentInsetAdjustmentBehavior = .never
        web.scrollView.keyboardDismissMode = .interactive
        coordinator.web = web
        bridge.web = web; bridge.ready = false
        // makeUIView runs inside a SwiftUI update; published state belongs to the next main-actor turn.
        Task { @MainActor [weak coordinator, weak web] in
            guard let coordinator, let web, !coordinator.ready, coordinator.parent.bridge.web === web else { return }
            coordinator.parent.bridge.isLoading = true
            coordinator.parent.bridge.displayError = nil
        }
        coordinator.navigation = web.loadHTMLString(Self.document, baseURL: nil)
        return web
    }
    func updateUIView(_ web: WKWebView, context: Context) {
        context.coordinator.parent = self
        if context.coordinator.ready { context.coordinator.sync() }
    }
    static func dismantleUIView(_ web: WKWebView, coordinator: Coordinator) {
        coordinator.ready = false
        coordinator.renderRevision += 1
        coordinator.pendingContent = nil; coordinator.pendingEditing = nil
        if coordinator.parent.bridge.web === web {
            coordinator.parent.bridge.ready = false
            coordinator.parent.bridge.web = nil
        }
        web.configuration.userContentController.removeScriptMessageHandler(forName: "edited")
        coordinator.cancelResourceTasks()
        coordinator.navigation = nil
        coordinator.web = nil
        web.navigationDelegate = nil
        web.stopLoading()
    }
    @MainActor
    final class Coordinator: NSObject, WKNavigationDelegate, WKScriptMessageHandler, WKURLSchemeHandler {
        var parent: NoteWebView
        weak var web: WKWebView?
        var navigation: WKNavigation?
        var ready = false
        private var recoveryCount = 0
        private var resourceGeneration = 0
        var applied = ""
        var appliedEditing: Bool?
        var lastCommand: UUID?
        var renderRevision = 0
        var pendingContent: String?
        var pendingEditing: Bool?
        var tasks: [ObjectIdentifier: Task<Void, Never>] = [:]
        func cancelResourceTasks() {
            resourceGeneration += 1
            tasks.values.forEach { $0.cancel() }
            tasks.removeAll()
        }
        init(_ parent: NoteWebView) { self.parent = parent; lastCommand = parent.command?.id }
        func webView(_ webView: WKWebView, didFinish navigation: WKNavigation!) {
            guard navigation === self.navigation else { return }
            let revision = renderRevision
            webView.evaluateJavaScript("typeof setNote === 'function' && typeof flushNote === 'function'") { [weak self] result, error in
                guard let self, self.renderRevision == revision, self.parent.bridge.web === webView else { return }
                guard error == nil, result as? Bool == true else { self.failDisplay(); return }
                self.ready = true
                self.sync()
            }
        }
        func webView(_ webView: WKWebView, didFail navigation: WKNavigation!, withError error: Error) {
            if navigation === self.navigation { failDisplay() }
        }
        func webView(_ webView: WKWebView, didFailProvisionalNavigation navigation: WKNavigation!, withError error: Error) {
            if navigation === self.navigation { failDisplay() }
        }
        func webViewWebContentProcessDidTerminate(_ webView: WKWebView) {
            guard parent.bridge.web === webView else { return }
            guard recoveryCount < 1 else { failDisplay(); return }
            recoveryCount += 1
            cancelResourceTasks()
            renderRevision += 1; pendingContent = nil; pendingEditing = nil
            ready = false; parent.bridge.ready = false
            applied = ""; appliedEditing = nil
            // The model owns the latest draft. Recreate only the document, then inject that draft.
            parent.bridge.isLoading = true
            parent.bridge.displayError = nil
            navigation = webView.loadHTMLString(NoteWebView.document, baseURL: nil)
        }
        private func failDisplay() {
            guard let web, parent.bridge.web === web else { return }
            cancelResourceTasks()
            renderRevision += 1; pendingContent = nil; pendingEditing = nil
            ready = false; parent.bridge.ready = false
            parent.bridge.displayError = "笔记排版未能加载，已显示文字内容。可重试排版或编辑 HTML 源码。"
            parent.bridge.isLoading = false
        }
        func sync() {
            guard ready, let web else { return }
            if applied != parent.content || appliedEditing != parent.editing {
                if pendingContent == parent.content && pendingEditing == parent.editing { return }
                let content = parent.content
                let editing = parent.editing
                let encoded = Data(content.utf8).base64EncodedString()
                renderRevision += 1
                let revision = renderRevision
                pendingContent = content; pendingEditing = editing
                web.evaluateJavaScript("setNote('\(encoded)', \(editing ? "true" : "false")); true") { [weak self] _, error in
                    guard let self, self.renderRevision == revision, self.parent.bridge.web === web else { return }
                    self.pendingContent = nil; self.pendingEditing = nil
                    guard error == nil else { self.failDisplay(); return }
                    self.applied = content; self.appliedEditing = editing
                    self.parent.bridge.ready = true
                    self.parent.bridge.displayError = nil
                    self.parent.bridge.isLoading = false
                    self.sync()
                }
                return
            }
            if parent.editing, let command = parent.command, command.id != lastCommand {
                lastCommand = command.id
                let args: [Any] = [command.name, command.value as Any? ?? NSNull()]
                if let data = try? JSONSerialization.data(withJSONObject: args), let json = String(data: data, encoding: .utf8) {
                    let revision = renderRevision
                    web.evaluateJavaScript("runCommand(...\(json))") { [weak self] _, error in
                        guard let self, self.renderRevision == revision, self.parent.bridge.web === web else { return }
                        if error != nil { self.failDisplay() }
                    }
                }
            }
        }
        func userContentController(_ userContentController: WKUserContentController, didReceive message: WKScriptMessage) {
            guard parent.editing, let value = message.body as? String else { return }
            applied = value
            parent.onChange(value)
        }
        func webView(_ webView: WKWebView, decidePolicyFor navigationAction: WKNavigationAction,
                     decisionHandler: @escaping (WKNavigationActionPolicy) -> Void) {
            guard navigationAction.navigationType == .linkActivated, let url = navigationAction.request.url else { decisionHandler(.allow); return }
            decisionHandler(.cancel)
            if let fragment = url.fragment, let id = fragment.split(separator: "/").last,
               id.allSatisfy({ $0.isLetter || $0.isNumber || $0 == "_" || $0 == "-" }) {
                parent.onNoteLink(String(id))
            } else if ["https", "http", "mailto"].contains(url.scheme?.lowercased() ?? "") {
                UIApplication.shared.open(url)
            }
        }
        func webView(_ webView: WKWebView, start urlSchemeTask: WKURLSchemeTask) {
            let key = ObjectIdentifier(urlSchemeTask as AnyObject)
            guard let url = urlSchemeTask.request.url, url.host == "local" else { urlSchemeTask.didFailWithError(URLError(.badURL)); return }
            let parts = url.path.split(separator: "/").map(String.init)
            guard parts.count == 3, ["notes", "attachments"].contains(parts[0]), parts[2] == "content" else { urlSchemeTask.didFailWithError(URLError(.badURL)); return }
            let api = parent.api
            let generation = resourceGeneration
            tasks[key] = Task { @MainActor in
                defer { if resourceGeneration == generation { tasks[key] = nil } }
                do {
                    let data = try await api.request(parts.joined(separator: "/"))
                    try Task.checkCancellation()
                    guard resourceGeneration == generation, tasks[key] != nil,
                          let web, parent.bridge.web === web else { return }
                    let mime: String
                    if data.starts(with: [0x89, 0x50, 0x4e, 0x47]) { mime = "image/png" }
                    else if data.starts(with: [0xff, 0xd8]) { mime = "image/jpeg" }
                    else if data.starts(with: Array("GIF8".utf8)) { mime = "image/gif" }
                    else if data.starts(with: Array("RIFF".utf8)) { mime = "image/webp" }
                    else { throw UserFacingError(message: "不支持的内嵌图片格式。") }
                    urlSchemeTask.didReceive(URLResponse(url: url, mimeType: mime, expectedContentLength: data.count, textEncodingName: nil))
                    urlSchemeTask.didReceive(data); urlSchemeTask.didFinish()
                } catch {
                    if !Task.isCancelled, resourceGeneration == generation, tasks[key] != nil {
                        urlSchemeTask.didFailWithError(error)
                    }
                }
            }
        }
        func webView(_ webView: WKWebView, stop urlSchemeTask: WKURLSchemeTask) {
            let key = ObjectIdentifier(urlSchemeTask as AnyObject)
            tasks[key]?.cancel(); tasks[key] = nil
        }
    }
    private static let document = """
    <!doctype html><html><head><meta name="viewport" content="width=device-width,initial-scale=1,maximum-scale=5">
    <meta http-equiv="Content-Security-Policy" content="default-src 'none'; script-src 'unsafe-inline'; style-src 'unsafe-inline'; img-src trilium-resource: data:;">
    <style>:root{color-scheme:light dark}body{font:17px -apple-system,BlinkMacSystemFont,sans-serif;line-height:1.65;margin:20px;color:#1c1c1e;background:#fff;overflow-wrap:anywhere}@media(prefers-color-scheme:dark){body{color:#f2f2f7;background:#1c1c1e}}#note{outline:none;min-height:75vh}img{max-width:100%;height:auto}table{max-width:100%;display:block;overflow:auto;border-collapse:collapse}td,th{border:1px solid #8885;padding:8px}pre{overflow:auto;background:#8881;padding:12px;border-radius:10px}blockquote{border-left:3px solid #00a99d;margin-left:0;padding-left:16px}a{color:#009e92}h1,h2,h3{line-height:1.3}input{pointer-events:none}
    #note ul{padding-inline-start:0}
    #note li ul{padding-inline-start:1.5em}
    </style></head>
    <body><article id="note"></article><script>
    const note=document.getElementById('note');let timer;let selection;let modified=false;let rendered='';
    document.addEventListener('selectionchange',()=>{const s=getSelection();if(s.rangeCount&&note.contains(s.anchorNode))selection=s.getRangeAt(0).cloneRange()});
    function sanitize(html){const t=document.createElement('template');t.innerHTML=html;
      t.content.querySelectorAll('script,style,iframe,object,embed,link,meta,base,form').forEach(e=>e.remove());
      t.content.querySelectorAll('*').forEach(e=>{for(const a of [...e.attributes]){if(a.name.startsWith('on')||['srcset','action','formaction','contenteditable','data-trilium-original-src','data-trilium-original-alt'].includes(a.name))e.removeAttribute(a.name)}
        if(e.hasAttribute('href')){const h=e.getAttribute('href').trim();if(!/^(https?:|mailto:|#|\\/)/i.test(h))e.removeAttribute('href')}
        if(e.tagName==='IMG'){const src=e.getAttribute('src')||'';e.setAttribute('data-trilium-original-src',src);e.setAttribute('data-trilium-original-alt',JSON.stringify(e.getAttribute('alt')));const match=src.match(/(?:^|\\/)api\\/(images|attachments)\\/([^/]+)\\//);if(match){e.src='trilium-resource://local/'+(match[1]==='images'?'notes':'attachments')+'/'+encodeURIComponent(match[2])+'/content'}else if(!/^data:image\\/(png|jpeg|gif|webp);base64,/i.test(src)){e.removeAttribute('src');e.alt=e.alt||'外部图片未加载'}}
      });return t.innerHTML}
    function setNote(encoded,editing){clearTimeout(timer);note.innerHTML=sanitize(new TextDecoder().decode(Uint8Array.from(atob(encoded),c=>c.charCodeAt(0))));note.contentEditable=editing?'true':'false';selection=null;modified=false;rendered=note.innerHTML;}
    function exportHTML(){const t=note.cloneNode(true);t.querySelectorAll('img').forEach(e=>{const src=e.getAttribute('data-trilium-original-src');if(src!==null)e.setAttribute('src',src);const alt=e.getAttribute('data-trilium-original-alt');if(alt!==null){const original=JSON.parse(alt);if(original===null)e.removeAttribute('alt');else e.setAttribute('alt',original)}e.removeAttribute('data-trilium-original-src');e.removeAttribute('data-trilium-original-alt')});return t.innerHTML;}
    function flushNote(){note.blur();return modified||note.innerHTML!==rendered?exportHTML():null}
    function changed(){modified=true;clearTimeout(timer);window.webkit.messageHandlers.edited.postMessage(exportHTML())}
    note.addEventListener('input',changed);note.addEventListener('blur',()=>{clearTimeout(timer);if(note.isContentEditable&&modified)window.webkit.messageHandlers.edited.postMessage(exportHTML())});
    note.addEventListener('paste',e=>{e.preventDefault();document.execCommand('insertText',false,e.clipboardData.getData('text/plain'));changed()});
    function runCommand(name,value){note.focus();if(selection){const s=getSelection();s.removeAllRanges();s.addRange(selection)}document.execCommand(name,false,value);changed()}
    </script></body></html>
    """
}
