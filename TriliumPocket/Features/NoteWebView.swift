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
    code{font-family:ui-monospace,monospace;background:#8881;border-radius:4px;padding:2px 4px}pre code{background:none;padding:0}
    #note ul.todo-list{list-style:none}ul.todo-list>li{position:relative;padding-inline-start:26px}
    .todo-list__label>input{position:absolute;inset-inline-start:0;top:5px;width:18px;height:18px;margin:0;accent-color:#009e92}
    #note[contenteditable=true] .todo-list__label>input{pointer-events:auto}
    </style></head>
    <body><article id="note"></article><script>
    const note=document.getElementById('note');let timer;let selection;let modified=false;let rendered='';let insertingHTML=false;
    document.addEventListener('selectionchange',()=>{const s=getSelection();if(s.rangeCount&&note.contains(s.anchorNode))selection=s.getRangeAt(0).cloneRange()});
    function sanitize(html){const t=document.createElement('template');t.innerHTML=html;
      t.content.querySelectorAll('script,style,iframe,object,embed,link,meta,base,form').forEach(e=>e.remove());
      t.content.querySelectorAll('*').forEach(e=>{for(const a of [...e.attributes]){if(a.name.startsWith('on')||['srcset','action','formaction','contenteditable','data-trilium-original-src','data-trilium-original-alt'].includes(a.name))e.removeAttribute(a.name)}
        if(e.hasAttribute('href')){const h=e.getAttribute('href').trim();if(!/^(https?:|mailto:|#|\\/)/i.test(h))e.removeAttribute('href')}
        if(e.tagName==='IMG'){const src=e.getAttribute('src')||'';e.setAttribute('data-trilium-original-src',src);e.setAttribute('data-trilium-original-alt',JSON.stringify(e.getAttribute('alt')));const match=src.match(/(?:^|\\/)api\\/(images|attachments)\\/([^/]+)\\//);if(match){e.src='trilium-resource://local/'+(match[1]==='images'?'notes':'attachments')+'/'+encodeURIComponent(match[2])+'/content'}else if(!/^data:image\\/(png|jpeg|gif|webp);base64,/i.test(src)){e.removeAttribute('src');e.alt=e.alt||'外部图片未加载'}}
      });return t.innerHTML}
    function setNote(encoded,editing){clearTimeout(timer);note.innerHTML=sanitize(new TextDecoder().decode(Uint8Array.from(atob(encoded),c=>c.charCodeAt(0))));note.contentEditable=editing?'true':'false';note.querySelectorAll('.todo-list input[type=checkbox]').forEach(e=>e.disabled=!editing);selection=null;modified=false;rendered=note.innerHTML;}
    function exportHTML(){const t=note.cloneNode(true);t.querySelectorAll('img').forEach(e=>{const src=e.getAttribute('data-trilium-original-src');if(src!==null)e.setAttribute('src',src);const alt=e.getAttribute('data-trilium-original-alt');if(alt!==null){const original=JSON.parse(alt);if(original===null)e.removeAttribute('alt');else e.setAttribute('alt',original)}e.removeAttribute('data-trilium-original-src');e.removeAttribute('data-trilium-original-alt')});t.querySelectorAll('.todo-list input[type=checkbox]').forEach(e=>e.setAttribute('disabled','disabled'));return t.innerHTML;}
    function flushNote(){note.blur();return modified||note.innerHTML!==rendered?exportHTML():null}
    function elementAtCaret(){const node=getSelection()?.anchorNode;return node?.nodeType===Node.ELEMENT_NODE?node:node?.parentElement}
    function decorateTaskItem(item){
      let label=[...item.children].find(e=>e.matches('label.todo-list__label'));
      if(!label){
        label=document.createElement('label');label.className='todo-list__label';
        const box=document.createElement('input');box.type='checkbox';
        const text=document.createElement('span');text.className='todo-list__label__description';
        [...item.childNodes].filter(e=>!['UL','OL'].includes(e.nodeName)).forEach(e=>text.append(e));
        if(!text.hasChildNodes())text.append(document.createElement('br'));
        label.append(box,text);item.prepend(label);
      }
      let box=label.querySelector('input[type=checkbox]');
      if(!box){box=document.createElement('input');box.type='checkbox';label.prepend(box)}
      box.disabled=false;
    }
    function changed(event){
      if(insertingHTML)return;
      modified=true;clearTimeout(timer);
      note.querySelectorAll('ul').forEach(list=>{
        if([...list.children].some(item=>[...item.children].some(e=>e.matches('label.todo-list__label'))))list.classList.add('todo-list');
      });
      note.querySelectorAll('ul.todo-list>li').forEach(decorateTaskItem);
      if(event?.inputType==='insertParagraph'){
        const item=elementAtCaret()?.closest('ul.todo-list>li');const box=item?.querySelector('input[type=checkbox]');if(box)box.checked=false;
      }
      note.querySelectorAll('.todo-list input[type=checkbox]').forEach(e=>e.toggleAttribute('checked',e.checked));
      window.webkit.messageHandlers.edited.postMessage(exportHTML());
    }
    note.addEventListener('input',changed);note.addEventListener('blur',()=>{clearTimeout(timer);if(note.isContentEditable&&modified)window.webkit.messageHandlers.edited.postMessage(exportHTML())});
    note.addEventListener('paste',e=>{e.preventDefault();document.execCommand('insertText',false,e.clipboardData.getData('text/plain'));changed()});
    function escapeHTML(text){const span=document.createElement('span');span.textContent=text;return span.innerHTML}
    function selectRange(range){const s=getSelection();s.removeAllRanges();s.addRange(range)}
    function placeCaret(element){
      if(!element||!note.contains(element))return;
      const range=document.createRange();const walker=document.createTreeWalker(element,NodeFilter.SHOW_TEXT);
      let lastText;for(let text=walker.nextNode();text;text=walker.nextNode())lastText=text;
      // Element-end positions can resolve outside a newly inserted list in WebKit.
      if(lastText)range.setStart(lastText,lastText.length);
      else{range.selectNodeContents(element);range.collapse(true)}
      range.collapse(true);selectRange(range);selection=range.cloneRange();
    }
    function finishEdit(restoreCaret){
      changed();if(restoreCaret)restoreCaret();
      selection=getSelection().rangeCount?getSelection().getRangeAt(0).cloneRange():null;
    }
    // Native editing transactions keep custom code and checklist insertions undoable.
    function insertHTML(html,caretSelector){
      const previous=new Set(caretSelector?note.querySelectorAll(caretSelector):[]);
      // Normalize task markup after the native edit has finished dispatching input.
      insertingHTML=true;
      try{document.execCommand('insertHTML',false,html)}finally{insertingHTML=false}
      // Resolve the caret after normalization has created or moved task descriptions.
      return caretSelector?()=>{
        const inserted=[...note.querySelectorAll(caretSelector)].filter(e=>!previous.has(e)).pop();
        placeCaret(inserted);
      }:null;
    }
    function replaceBlock(block,html,caretSelector){
      // Treat the old block as atomic so native insertion cannot retain or merge its list markup.
      const editable=block.getAttribute('contenteditable');block.contentEditable='false';
      const range=document.createRange();range.selectNode(block);selectRange(range);
      try{return insertHTML(html,caretSelector)}
      finally{
        // Undo restores this same node, which must remain editable.
        if(editable===null)block.removeAttribute('contenteditable');else block.setAttribute('contenteditable',editable);
      }
    }
    function inlineCode(){
      const range=getSelection().getRangeAt(0);const code=elementAtCaret()?.closest('code');
      if(code&&!code.closest('pre')&&code.contains(range.endContainer)){range.selectNode(code);selectRange(range);return insertHTML(code.innerHTML)}
      return insertHTML('<code>'+(range.collapsed?'&#8203;':escapeHTML(range.toString()))+'</code>','code');
    }
    function plainTaskList(source,tag){
      const list=document.createElement(tag);list.innerHTML=source.innerHTML;
      [...list.children].forEach(item=>{const label=[...item.children].find(e=>e.matches('label.todo-list__label'));const text=label?.querySelector('.todo-list__label__description');if(text)label.replaceWith(...text.childNodes)});
      return list;
    }
    function taskList(){
      const range=getSelection().getRangeAt(0);const existing=elementAtCaret()?.closest('ul,ol');
      const list=document.createElement('ul');
      if(existing&&note.contains(existing)){
        list.innerHTML=existing.innerHTML;
        if(existing.classList.contains('todo-list')){
          return replaceBlock(existing,plainTaskList(existing,'ul').outerHTML,'li');
        }
      }else{
        const block=elementAtCaret()?.closest('p,div,h1,h2,h3,h4,h5,h6,pre');
        const fragment=document.createElement('div');
        if(range.collapsed&&block&&note.contains(block)){fragment.innerHTML=block.innerHTML;range.selectNode(block);selectRange(range)}
        else fragment.append(range.cloneContents());
        let item=document.createElement('li');
        for(const child of [...fragment.childNodes]){
          if(child.nodeType===Node.ELEMENT_NODE&&child.matches('p,div,h1,h2,h3,h4,h5,h6,pre')){
            if(item.hasChildNodes()){list.append(item);item=document.createElement('li')}
            const paragraph=document.createElement('li');paragraph.innerHTML=child.innerHTML;list.append(paragraph);
          }else item.append(child);
        }
        if(item.hasChildNodes()||!list.hasChildNodes())list.append(item);
      }
      list.className='todo-list';[...list.children].forEach(decorateTaskItem);
      if(existing&&note.contains(existing))return replaceBlock(existing,list.outerHTML,'.todo-list__label__description');
      return insertHTML(list.outerHTML,'.todo-list__label__description');
    }
    note.addEventListener('beforeinput',event=>{
      if(event.inputType!=='insertParagraph'||event.isComposing||!note.isContentEditable)return;
      const item=elementAtCaret()?.closest('ul.todo-list>li');const text=item?.querySelector('.todo-list__label__description');
      if(!item||!text||text.textContent.trim()||item.querySelector('img,hr,ul,ol')||item!==item.parentElement.lastElementChild)return;
      event.preventDefault();const list=item.parentElement;const remaining=list.cloneNode(true);remaining.lastElementChild.remove();
      finishEdit(replaceBlock(list,(remaining.children.length?remaining.outerHTML:'')+'<p><br></p>','p'));
    });
    note.addEventListener('click',event=>{
      if(!(event.target instanceof Element))return;
      const box=event.target.closest('.todo-list input[type=checkbox]');
      if(!note.isContentEditable)return;
      if(!box){if(event.target.closest('label.todo-list__label'))event.preventDefault();return}
      const text=box.closest('li')?.querySelector('.todo-list__label__description');
      event.preventDefault();const replacement=box.cloneNode();replacement.toggleAttribute('checked',!box.hasAttribute('checked'));
      const range=document.createRange();range.selectNode(box);selectRange(range);
      insertHTML(replacement.outerHTML);
      finishEdit(()=>placeCaret(text));
    });
    function runCommand(name,value){
      if(!note.isContentEditable)return;
      const saved=selection;note.focus();
      if(saved&&note.contains(saved.commonAncestorContainer))selectRange(saved);
      if(!getSelection().rangeCount){const range=document.createRange();range.selectNodeContents(note);range.collapse(false);selectRange(range)}
      let restoreCaret;
      if(name==='inlineCode')restoreCaret=inlineCode();
      else if(name==='taskList')restoreCaret=taskList();
      else if(['insertUnorderedList','insertOrderedList'].includes(name)&&elementAtCaret()?.closest('ul.todo-list')){
        const list=elementAtCaret().closest('ul.todo-list');
        restoreCaret=replaceBlock(list,plainTaskList(list,name==='insertOrderedList'?'ol':'ul').outerHTML,'li');
      }
      else if(name==='createLink'){
        if(typeof value!=='string'||!/^(https?:|mailto:|#|\\/)/i.test(value.trim()))return;
        if(getSelection().isCollapsed){const link=document.createElement('a');link.setAttribute('href',value);link.textContent=value;insertHTML(link.outerHTML)}
        else document.execCommand(name,false,value);
      }else document.execCommand(name,false,value);
      finishEdit(restoreCaret);
    }
    </script></body></html>
    """
}
