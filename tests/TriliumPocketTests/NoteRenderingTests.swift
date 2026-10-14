import Combine
import UIKit
import WebKit
import XCTest
@testable import TriliumPocket

final class NoteRenderingTests: XCTestCase {
    @MainActor
    func testUnicodeHTMLRendersAfterInitialization() async throws {
        let renderer = try Renderer(content: "<p>你好 &amp; hello</p>")
        defer { renderer.close() }
        try await waitForRender(renderer.bridge)

        let text = try await renderer.web.evaluateJavaScript("document.getElementById('note').textContent")
        XCTAssertEqual(text as? String, "你好 & hello")
        XCTAssertGreaterThan(renderer.web.bounds.width, 0)
        XCTAssertGreaterThan(renderer.web.bounds.height, 0)
        XCTAssertTrue(renderer.bridge.ready)
        XCTAssertNil(renderer.bridge.displayError)
    }

    @MainActor
    func testUntouchedEditableDocumentDoesNotRewriteSource() async throws {
        let source = "<p class='custom'>你好 <strong>world</strong> &amp; friends</p>"
        let renderer = try Renderer(content: source, editing: true)
        defer { renderer.close() }
        try await waitForRender(renderer.bridge)

        let editable = try await renderer.web.evaluateJavaScript("document.getElementById('note').isContentEditable")
        XCTAssertEqual(editable as? Bool, true)
        let changedContent = try await renderer.bridge.flush()
        XCTAssertNil(changedContent, "Entering the editor and flushing must preserve the original HTML until actual edits occur.")
        XCTAssertEqual(renderer.view.content, source)
    }

    @MainActor
    func testInlineCodeEscapesSelectedTextAndSupportsUndoRedo() async throws {
        let renderer = try Renderer(content: "<p>&lt;tag&gt; &amp; 中文</p>", editing: true)
        defer { renderer.close() }
        try await waitForRender(renderer.bridge)
        try await selectContents("p", in: renderer.web)

        _ = try await renderer.web.evaluateJavaScript("runCommand('inlineCode'); true")
        let code = try await renderer.web.evaluateJavaScript("note.querySelector('code')?.textContent")
        XCTAssertEqual(code as? String, "<tag> & 中文")
        let tagCount = try await renderer.web.evaluateJavaScript("note.querySelectorAll('tag').length")
        XCTAssertEqual((tagCount as? NSNumber)?.intValue, 0)

        _ = try await renderer.web.evaluateJavaScript("runCommand('undo'); true")
        let undone = try await renderer.web.evaluateJavaScript("note.querySelector('code') === null && note.textContent === '<tag> & 中文'")
        XCTAssertEqual(undone as? Bool, true)
        _ = try await renderer.web.evaluateJavaScript("runCommand('redo'); true")
        let redone = try await renderer.web.evaluateJavaScript("note.querySelector('code')?.textContent")
        XCTAssertEqual(redone as? String, "<tag> & 中文")
    }

    @MainActor
    func testStrikethroughAndHighlightPreserveSelectedText() async throws {
        let renderer = try Renderer(content: "<p>需要标记的文字</p>", editing: true)
        defer { renderer.close() }
        try await waitForRender(renderer.bridge)
        try await selectContents("p", in: renderer.web)

        _ = try await renderer.web.evaluateJavaScript("runCommand('strikeThrough'); runCommand('hiliteColor', '#fff2a8'); true")
        let result = try await renderer.web.evaluateJavaScript("""
        (() => {
          const walker = document.createTreeWalker(note, NodeFilter.SHOW_TEXT);
          const text = walker.nextNode(); let element = text.parentElement;
          let strike = false; let highlighted = false;
          while (element && element !== note) {
            const style = getComputedStyle(element);
            strike ||= style.textDecorationLine.includes('line-through');
            highlighted ||= style.backgroundColor === 'rgb(255, 242, 168)';
            element = element.parentElement;
          }
          return { text: note.textContent, strike, highlighted };
        })()
        """)
        let values = try XCTUnwrap(result as? [String: Any])
        XCTAssertEqual(values["text"] as? String, "需要标记的文字")
        XCTAssertEqual(values["strike"] as? Bool, true)
        XCTAssertEqual(values["highlighted"] as? Bool, true)
    }

    @MainActor
    func testLinkCommandRestoresSelectionAfterNativeDialogAndRejectsScriptURLs() async throws {
        let renderer = try Renderer(content: "<p>选中的文字</p>", editing: true)
        defer { renderer.close() }
        try await waitForRender(renderer.bridge)
        try await selectContents("p", in: renderer.web)

        // A native URL prompt takes focus away from the web editor.
        _ = try await renderer.web.evaluateJavaScript("""
        note.blur(); getSelection().removeAllRanges();
        runCommand('createLink', 'https://example.com/?a=1&b=2'); true
        """)
        let link = try await renderer.web.evaluateJavaScript("""
        (() => { const link = note.querySelector('a'); return { text: link?.textContent, href: link?.getAttribute('href') }; })()
        """)
        let values = try XCTUnwrap(link as? [String: Any])
        XCTAssertEqual(values["text"] as? String, "选中的文字")
        XCTAssertEqual(values["href"] as? String, "https://example.com/?a=1&b=2")

        let before = try await renderer.web.evaluateJavaScript("note.innerHTML") as? String
        _ = try await renderer.web.evaluateJavaScript("runCommand('createLink', 'javascript:alert(1)'); true")
        let after = try await renderer.web.evaluateJavaScript("note.innerHTML") as? String
        XCTAssertEqual(after, before)
    }

    @MainActor
    func testTaskListCheckStateSurvivesExportAndReadOnlyReload() async throws {
        let renderer = try Renderer(content: "<p><strong>待办事项</strong></p>", editing: true)
        defer { renderer.close() }
        try await waitForRender(renderer.bridge)
        try await selectContents("p", in: renderer.web)

        _ = try await renderer.web.evaluateJavaScript("runCommand('taskList'); true")
        let formatting = try await renderer.web.evaluateJavaScript("note.querySelector('.todo-list__label__description strong')?.textContent")
        XCTAssertEqual(formatting as? String, "待办事项")
        _ = try await renderer.web.evaluateJavaScript("note.querySelector('.todo-list input').click(); true")
        try await assertUndoRedo(
            in: renderer.web,
            undone: "note.querySelector('.todo-list input')?.checked === false",
            redone: "note.querySelector('.todo-list input')?.checked === true"
        )
        let exported = try await renderer.bridge.flush()
        let content = try XCTUnwrap(exported)
        XCTAssertFalse(HTMLText.requiresSourceEditing(content))

        let encoded = Data(content.utf8).base64EncodedString()
        _ = try await renderer.web.evaluateJavaScript("setNote('\(encoded)', false); true")
        let state = try await renderer.web.evaluateJavaScript("""
        (() => { const box = note.querySelector('.todo-list input'); return { checked: box.checked, disabled: box.disabled, text: note.textContent }; })()
        """)
        let values = try XCTUnwrap(state as? [String: Any])
        XCTAssertEqual(values["checked"] as? Bool, true)
        XCTAssertEqual(values["disabled"] as? Bool, true)
        XCTAssertEqual(values["text"] as? String, "待办事项")
        let untouched = try await renderer.bridge.flush()
        XCTAssertNil(untouched, "Reading a saved checklist must not rewrite its source.")
    }

    @MainActor
    func testTaskListConvertsMultipleParagraphsAndTogglesBackWithoutLosingFormatting() async throws {
        let renderer = try Renderer(content: "<p><strong>第一项</strong></p><p>第二项</p>", editing: true)
        defer { renderer.close() }
        try await waitForRender(renderer.bridge)
        try await selectContents("#note", in: renderer.web)

        _ = try await renderer.web.evaluateJavaScript("runCommand('taskList'); true")
        let count = try await renderer.web.evaluateJavaScript("note.querySelectorAll('ul.todo-list > li').length")
        XCTAssertEqual((count as? NSNumber)?.intValue, 2)
        try await assertEditorState(
            "note.querySelector('ul.todo-list > li:last-child .todo-list__label__description')?.contains(getSelection().anchorNode) === true",
            in: renderer.web
        )
        _ = try await renderer.web.evaluateJavaScript("runCommand('taskList'); true")
        try await assertEditorState("note.querySelector('input') === null", in: renderer.web)
        let result = try await renderer.web.evaluateJavaScript("""
        ({ count: note.querySelectorAll('ul > li').length, tasks: note.querySelectorAll('input').length, bold: note.querySelector('strong')?.textContent, text: note.textContent })
        """)
        let values = try XCTUnwrap(result as? [String: Any])
        XCTAssertEqual((values["count"] as? NSNumber)?.intValue, 2)
        XCTAssertEqual((values["tasks"] as? NSNumber)?.intValue, 0)
        XCTAssertEqual(values["bold"] as? String, "第一项")
        XCTAssertEqual(values["text"] as? String, "第一项第二项")
        try await assertUndoRedo(
            in: renderer.web,
            undone: "note.querySelectorAll('ul.todo-list > li input').length === 2 && note.querySelector('strong')?.textContent === '第一项'",
            redone: "note.querySelectorAll('ul > li').length === 2 && note.querySelector('input') === null && note.textContent === '第一项第二项'"
        )
    }

    @MainActor
    func testEnterOnAnEmptyLastTaskReturnsToNormalParagraph() async throws {
        let renderer = try Renderer(content: "", editing: true)
        defer { renderer.close() }
        try await waitForRender(renderer.bridge)
        try await selectContents("#note", in: renderer.web)

        _ = try await renderer.web.evaluateJavaScript("runCommand('taskList'); true")
        try await assertEditorState(
            "note.querySelector('.todo-list__label__description')?.contains(getSelection().anchorNode) === true",
            in: renderer.web
        )
        _ = try await renderer.web.evaluateJavaScript("""
        note.dispatchEvent(new InputEvent('beforeinput', { inputType: 'insertParagraph', bubbles: true, cancelable: true })); true
        """)
        try await assertEditorState("note.querySelector('ul') === null && note.querySelector('p') !== null", in: renderer.web)
        let result = try await renderer.web.evaluateJavaScript("note.querySelector('ul') === null && note.querySelector('p') !== null")
        XCTAssertEqual(result as? Bool, true)
        try await assertUndoRedo(
            in: renderer.web,
            undone: "note.querySelector('ul.todo-list > li input') !== null",
            redone: "note.querySelector('ul') === null && note.querySelector('p') !== null"
        )
    }

    @MainActor
    func testLeavingEmptyTaskPreservesPreviousTasksAndSurroundingParagraphs() async throws {
        let renderer = try Renderer(content: """
        <p>列表之前</p><ul class="todo-list">
        <li><label class="todo-list__label"><input type="checkbox" checked><span class="todo-list__label__description"><strong>保留事项</strong></span></label></li>
        <li><label class="todo-list__label"><input type="checkbox"><span class="todo-list__label__description"><br></span></label></li>
        </ul><p>列表之后</p>
        """, editing: true)
        defer { renderer.close() }
        try await waitForRender(renderer.bridge)
        try await selectContents("li:last-child .todo-list__label__description", in: renderer.web)

        _ = try await renderer.web.evaluateJavaScript("""
        note.dispatchEvent(new InputEvent('beforeinput', { inputType: 'insertParagraph', bubbles: true, cancelable: true })); true
        """)
        let result = try await renderer.web.evaluateJavaScript("""
        (() => {
          const list = note.querySelector('ul.todo-list');
          return list?.children.length === 1
            && list.querySelector('input').checked
            && list.querySelector('strong')?.textContent === '保留事项'
            && note.firstElementChild.textContent === '列表之前'
            && note.lastElementChild.textContent === '列表之后'
            && list.nextElementSibling?.tagName === 'P'
            && list.nextElementSibling.textContent === ''
            && list.nextElementSibling.contains(getSelection().anchorNode);
        })()
        """)
        XCTAssertEqual(result as? Bool, true)
        let content = try await renderer.bridge.flush()
        let exported = try XCTUnwrap(content)
        XCTAssertFalse(exported.contains("contenteditable"), "Temporary replacement attributes must not leak into saved notes.")
    }

    @MainActor
    func testTaskListCanBecomeANumberedListWithoutLosingText() async throws {
        let renderer = try Renderer(content: "<p><em>待办事项</em></p>", editing: true)
        defer { renderer.close() }
        try await waitForRender(renderer.bridge)
        try await selectContents("p", in: renderer.web)

        let initialCaret = try await renderer.web.evaluateJavaScript("""
        (() => {
          runCommand('taskList');
          const inside = note.querySelector('.todo-list__label__description')?.contains(getSelection().anchorNode) === true;
          runCommand('insertOrderedList');
          return inside;
        })()
        """)
        XCTAssertEqual(initialCaret as? Bool, true, "Creating a task list must leave the caret inside its description.")
        try await assertEditorState("note.querySelector('ol > li em')?.textContent === '待办事项' && note.querySelector('input') === null", in: renderer.web)
        let result = try await renderer.web.evaluateJavaScript("""
        ({ numbered: note.querySelector('ol > li em')?.textContent, tasks: note.querySelectorAll('input').length })
        """)
        let values = try XCTUnwrap(result as? [String: Any])
        XCTAssertEqual(values["numbered"] as? String, "待办事项")
        XCTAssertEqual((values["tasks"] as? NSNumber)?.intValue, 0)
        try await assertUndoRedo(
            in: renderer.web,
            undone: "note.querySelector('ul.todo-list > li em')?.textContent === '待办事项' && note.querySelectorAll('input').length === 1",
            redone: "note.querySelector('ol > li em')?.textContent === '待办事项' && note.querySelector('input') === null"
        )
    }

    @MainActor
    func testLoadedTaskListCanBecomeANumberedListAndSupportsUndoRedo() async throws {
        let renderer = try Renderer(content: """
        <ul class="todo-list"><li><label class="todo-list__label"><input type="checkbox" checked><span class="todo-list__label__description"><em>待办事项</em></span></label></li></ul>
        """, editing: true)
        defer { renderer.close() }
        try await waitForRender(renderer.bridge)
        try await selectContents(".todo-list__label__description", in: renderer.web)

        _ = try await renderer.web.evaluateJavaScript("runCommand('insertOrderedList'); true")
        let numbered = "note.querySelector('ol > li em')?.textContent === '待办事项' && note.querySelector('input') === null"
        try await assertEditorState(numbered, in: renderer.web)
        try await assertUndoRedo(
            in: renderer.web,
            undone: "note.querySelector('ul.todo-list input')?.checked === true && note.querySelector('em')?.textContent === '待办事项'",
            redone: numbered
        )
    }

    @MainActor
    func testNativeFormattingTextAndStructuralEditsShareOneUndoHistory() async throws {
        let renderer = try Renderer(content: "<p>中文任务</p>", editing: true)
        defer { renderer.close() }
        try await waitForRender(renderer.bridge)
        try await selectContents("p", in: renderer.web)

        let initial = try await renderer.web.evaluateJavaScript("note.innerHTML") as? String
        var snapshots = [try XCTUnwrap(initial)]
        let commands = [
            ("runCommand('bold')", "note.querySelector('p b, p strong')?.textContent === '中文任务'"),
            ("runCommand('taskList')", "note.querySelector('.todo-list__label__description b, .todo-list__label__description strong')?.textContent === '中文任务'"),
            ("runCommand('insertOrderedList')", "note.querySelector('ol li b, ol li strong')?.textContent === '中文任务' && note.querySelector('input') === null"),
            ("runCommand('insertText', '追加')", "note.querySelector('ol li')?.textContent === '中文任务追加' && note.querySelector('b, strong') !== null && note.querySelector('input') === null")
        ]
        for (command, condition) in commands {
            _ = try await renderer.web.evaluateJavaScript("\(command); true")
            try await assertEditorState(condition, in: renderer.web)
            let snapshot = try await renderer.web.evaluateJavaScript("note.innerHTML") as? String
            snapshots.append(try XCTUnwrap(snapshot))
        }
        for expected in snapshots.dropLast().reversed() {
            _ = try await renderer.web.evaluateJavaScript("runCommand('undo'); true")
            let actual = try await renderer.web.evaluateJavaScript("note.innerHTML") as? String
            XCTAssertEqual(actual, expected)
        }
        for expected in snapshots.dropFirst() {
            _ = try await renderer.web.evaluateJavaScript("runCommand('redo'); true")
            let actual = try await renderer.web.evaluateJavaScript("note.innerHTML") as? String
            XCTAssertEqual(actual, expected)
        }
    }

    @MainActor
    func testTaskListPreservesWholeParagraphWhenOnlyPartOfItsTextIsSelected() async throws {
        let renderer = try Renderer(content: "<p>列表之前</p><p>保留<strong>选中</strong>文字</p><p>列表之后</p>", editing: true)
        defer { renderer.close() }
        try await waitForRender(renderer.bridge)
        try await selectContents("strong", in: renderer.web)

        let before = try await renderer.web.evaluateJavaScript("note.innerHTML") as? String
        _ = try await renderer.web.evaluateJavaScript("runCommand('taskList'); true")
        let taskState = """
        note.children.length === 3 && note.firstElementChild.textContent === '列表之前'
          && note.lastElementChild.textContent === '列表之后'
          && note.querySelector('.todo-list__label__description')?.textContent === '保留选中文字'
          && note.querySelector('.todo-list__label__description strong')?.textContent === '选中'
          && note.querySelector('.todo-list__label__description')?.contains(getSelection().anchorNode) === true
        """
        try await assertEditorState(taskState, in: renderer.web)
        _ = try await renderer.web.evaluateJavaScript("runCommand('undo'); true")
        let undone = try await renderer.web.evaluateJavaScript("note.innerHTML") as? String
        XCTAssertEqual(undone, before)
        _ = try await renderer.web.evaluateJavaScript("runCommand('redo'); true")
        try await assertEditorState(taskState, in: renderer.web)
    }

    @MainActor
    func testHistoryInputAndKeyboardShortcutsRestoreListsAndCaret() async throws {
        let renderer = try Renderer(content: """
        <ul class="todo-list"><li><label class="todo-list__label"><input type="checkbox" checked><span class="todo-list__label__description"><em>待办事项</em></span></label></li></ul>
        """, editing: true)
        defer { renderer.close() }
        try await waitForRender(renderer.bridge)
        try await selectContents(".todo-list__label__description", in: renderer.web)
        _ = try await renderer.web.evaluateJavaScript("runCommand('insertOrderedList'); true")

        let taskState = "note.querySelector('ul.todo-list input')?.checked === true && note.querySelector('.todo-list__label__description')?.contains(getSelection().anchorNode) === true"
        let numberedState = "note.querySelector('ol li em')?.textContent === '待办事项' && note.querySelector('input') === null && note.querySelector('ol li')?.contains(getSelection().anchorNode) === true"
        for (type, expected) in [("historyUndo", taskState), ("historyRedo", numberedState)] {
            let canceled = try await renderer.web.evaluateJavaScript("""
            !note.dispatchEvent(new InputEvent('beforeinput', { inputType: '\(type)', bubbles: true, cancelable: true }))
            """)
            XCTAssertEqual(canceled as? Bool, true)
            try await assertEditorState(expected, in: renderer.web)
        }
        for (shift, expected) in [(false, taskState), (true, numberedState)] {
            let canceled = try await renderer.web.evaluateJavaScript("""
            !note.dispatchEvent(new KeyboardEvent('keydown', { key: 'z', metaKey: true, shiftKey: \(shift), bubbles: true, cancelable: true }))
            """)
            XCTAssertEqual(canceled as? Bool, true)
            try await assertEditorState(expected, in: renderer.web)
        }

        // Starting another document discards both directions of the previous history.
        let encoded = Data("<p>另一篇笔记</p>".utf8).base64EncodedString()
        _ = try await renderer.web.evaluateJavaScript("setNote('\(encoded)', true); runCommand('undo'); runCommand('redo'); true")
        try await assertEditorState("note.innerHTML === '<p>另一篇笔记</p>'", in: renderer.web)
    }

    @MainActor
    func testTextInputAndChineseCompositionRemainUndoableAfterListReplacement() async throws {
        let renderer = try Renderer(content: "<p>起点</p>", editing: true)
        defer { renderer.close() }
        try await waitForRender(renderer.bridge)
        try await selectContents("p", in: renderer.web)
        _ = try await renderer.web.evaluateJavaScript("runCommand('taskList'); runCommand('insertOrderedList'); true")
        let before = try await renderer.web.evaluateJavaScript("note.innerHTML") as? String

        // Exercise the input listener directly, outside the toolbar's native-command wrapper.
        _ = try await renderer.web.evaluateJavaScript("""
        note.dispatchEvent(new InputEvent('beforeinput', { inputType: 'insertText', bubbles: true, cancelable: true }));
        document.execCommand('insertText', false, '!'); true
        """)
        let typed = try await renderer.web.evaluateJavaScript("note.innerHTML") as? String
        XCTAssertNotEqual(typed, before)
        try await assertEditorState("note.textContent === '起点!'", in: renderer.web)
        _ = try await renderer.web.evaluateJavaScript("""
        note.dispatchEvent(new CompositionEvent('compositionstart', { bubbles: true }));
        for (const text of ['中', '中文']) {
          const item = note.querySelector('li');
          item.textContent = '起点!' + text;
          placeCaret(item);
          note.dispatchEvent(new InputEvent('input', { inputType: 'insertCompositionText', isComposing: true, bubbles: true }));
        }
        note.dispatchEvent(new CompositionEvent('compositionend', { data: '中文', bubbles: true })); true
        """)
        try await assertUndoRedo(in: renderer.web,
                                undone: "note.textContent === '起点!'",
                                redone: "note.textContent === '起点!中文'")
        _ = try await renderer.web.evaluateJavaScript("runCommand('undo'); runCommand('undo'); true")
        let undone = try await renderer.web.evaluateJavaScript("note.innerHTML") as? String
        XCTAssertEqual(undone, before)
        _ = try await renderer.web.evaluateJavaScript("runCommand('insertText', '新分支'); runCommand('redo'); true")
        try await assertEditorState("note.textContent === '起点新分支'", in: renderer.web)
    }

    @MainActor
    private func assertEditorState(_ condition: String, in web: WKWebView,
                                   file: StaticString = #filePath, line: UInt = #line) async throws {
        let result = try await web.evaluateJavaScript("""
        (() => {
          const current = getSelection();
          return { matches: Boolean(\(condition)), diagnostic: JSON.stringify({
            html: note.innerHTML, anchor: current.anchorNode?.nodeName, anchorOffset: current.anchorOffset,
            focus: current.focusNode?.nodeName, focusOffset: current.focusOffset,
            savedStart: selection?.startContainer.nodeName, savedOffset: selection?.startOffset
          }) };
        })()
        """)
        let values = try XCTUnwrap(result as? [String: Any], file: file, line: line)
        XCTAssertEqual(values["matches"] as? Bool, true, values["diagnostic"] as? String ?? "Missing editor state.", file: file, line: line)
    }

    @MainActor
    private func assertUndoRedo(in web: WKWebView, undone: String, redone: String,
                               file: StaticString = #filePath, line: UInt = #line) async throws {
        _ = try await web.evaluateJavaScript("runCommand('undo'); true")
        try await assertEditorState("(\(undone)) && note.querySelector('[contenteditable]') === null", in: web, file: file, line: line)
        _ = try await web.evaluateJavaScript("runCommand('redo'); true")
        try await assertEditorState("(\(redone)) && note.querySelector('[contenteditable]') === null", in: web, file: file, line: line)
    }

    @MainActor
    private func selectContents(_ selector: String, in web: WKWebView) async throws {
        _ = try await web.evaluateJavaScript("""
        (() => {
          note.focus();
          const element = document.querySelector('\(selector)');
          const range = document.createRange(); range.selectNodeContents(element);
          const current = getSelection(); current.removeAllRanges(); current.addRange(range);
          document.dispatchEvent(new Event('selectionchange'));
          return true;
        })()
        """)
    }

    @MainActor
    func testSanitizationRetainsTextWithoutExecutingUntrustedScript() async throws {
        let source = """
        <script>window.untrustedExecuted = true;</script>
        <p onclick="window.untrustedExecuted = true">可见正文</p>
        <a href="javascript:window.untrustedExecuted=true">链接文字</a>
        """
        let renderer = try Renderer(content: source)
        defer { renderer.close() }
        try await waitForRender(renderer.bridge)

        let result = try await renderer.web.evaluateJavaScript("""
        (() => {
          const article = document.getElementById('note');
          article.querySelector('p').click();
          return {
            text: article.textContent,
            scriptCount: article.querySelectorAll('script').length,
            eventCount: article.querySelectorAll('[onclick]').length,
            unsafeLinkCount: article.querySelectorAll('a[href]').length,
            executed: window.untrustedExecuted === true
          };
        })()
        """)
        let values = try XCTUnwrap(result as? [String: Any])
        XCTAssertTrue((values["text"] as? String)?.contains("可见正文") == true)
        XCTAssertTrue((values["text"] as? String)?.contains("链接文字") == true)
        XCTAssertEqual((values["scriptCount"] as? NSNumber)?.intValue, 0)
        XCTAssertEqual((values["eventCount"] as? NSNumber)?.intValue, 0)
        XCTAssertEqual((values["unsafeLinkCount"] as? NSNumber)?.intValue, 0)
        XCTAssertEqual((values["executed"] as? NSNumber)?.boolValue, false)
    }

    @MainActor
    func testRendererCreationDoesNotPublishDuringSwiftUIViewUpdate() async throws {
        let bridge = WebEditorBridge()
        bridge.isLoading = false
        let api = APIClient(baseURL: try XCTUnwrap(URL(string: "https://rendering.invalid")), token: "unused")
        let view = NoteWebView(content: "<p>正文</p>", editing: false, api: api, bridge: bridge,
                               command: nil, onChange: { _ in }, onNoteLink: { _ in })
        let coordinator = view.makeCoordinator()
        var publications = 0
        let observation = bridge.objectWillChange.sink { publications += 1 }
        let web = view.makeWebView(coordinator: coordinator)
        defer {
            observation.cancel()
            web.stopLoading()
            NoteWebView.dismantleUIView(web, coordinator: coordinator)
        }
        XCTAssertEqual(publications, 0, "makeUIView must not publish synchronously during a SwiftUI view update.")
        XCTAssertFalse(bridge.isLoading)
        // Teardown before deferred initialization must not reactivate a discarded renderer.
        NoteWebView.dismantleUIView(web, coordinator: coordinator)
        await Task.yield()
        XCTAssertEqual(publications, 0)
    }

    @MainActor
    func testContentProcessRecoveryReinjectsLatestDraft() async throws {
        let renderer = try Renderer(content: "<p>原始正文</p>")
        defer { renderer.close() }
        try await waitForRender(renderer.bridge)
        renderer.coordinator.parent = NoteWebView(content: "<p>最新草稿</p>", editing: true,
                                                 api: renderer.view.api, bridge: renderer.bridge,
                                                 command: nil, onChange: { _ in }, onNoteLink: { _ in })
        let previousNavigation = renderer.coordinator.navigation
        renderer.coordinator.webViewWebContentProcessDidTerminate(renderer.web)
        if let previousNavigation {
            renderer.coordinator.webView(renderer.web, didFail: previousNavigation, withError: URLError(.cancelled))
            renderer.coordinator.webView(renderer.web, didFailProvisionalNavigation: previousNavigation, withError: URLError(.cancelled))
        }
        XCTAssertNil(renderer.bridge.displayError, "Callbacks from the previous document must not invalidate recovery.")
        XCTAssertFalse(renderer.bridge.ready)
        XCTAssertTrue(renderer.bridge.isLoading)
        try await waitForRender(renderer.bridge)
        let text = try await renderer.web.evaluateJavaScript("document.getElementById('note').textContent")
        XCTAssertEqual(text as? String, "最新草稿")
        // Bound automatic recovery; a repeated failure must expose the native fallback.
        renderer.coordinator.webViewWebContentProcessDidTerminate(renderer.web)
        XCTAssertNotNil(renderer.bridge.displayError)
        XCTAssertFalse(renderer.bridge.isLoading)
    }

    @MainActor
    private func waitForRender(_ bridge: WebEditorBridge) async throws {
        let finished = expectation(description: "Renderer finishes bootstrap and initial content injection")
        // Subscribe before yielding to WebKit; a ready renderer also completes immediately.
        let observation = bridge.$isLoading.filter { !$0 }.prefix(1).sink { _ in finished.fulfill() }
        await fulfillment(of: [finished], timeout: 60)
        observation.cancel()
        XCTAssertFalse(bridge.isLoading)
        XCTAssertNil(bridge.displayError)
        guard bridge.ready else {
            throw UserFacingError(message: bridge.displayError ?? "WebKit renderer did not become ready.")
        }
    }
}

/// Retain the coordinator and a visible native viewport until asynchronous WebKit work completes.
@MainActor
private final class Renderer {
    let view: NoteWebView
    let coordinator: NoteWebView.Coordinator
    let bridge: WebEditorBridge
    let web: WKWebView
    let window: UIWindow
    private let controller: UIViewController

    init(content: String, editing: Bool = false) throws {
        let bridge = WebEditorBridge()
        let api = APIClient(baseURL: try XCTUnwrap(URL(string: "https://rendering.invalid")), token: "unused-test-token")
        let view = NoteWebView(content: content, editing: editing, api: api, bridge: bridge,
                               command: nil, onChange: { _ in }, onNoteLink: { _ in })
        let coordinator = view.makeCoordinator()
        let web = view.makeWebView(coordinator: coordinator)
        let frame = CGRect(x: 0, y: 0, width: 390, height: 640)
        let window: UIWindow
        if let scene = UIApplication.shared.connectedScenes.compactMap({ $0 as? UIWindowScene }).first {
            window = UIWindow(windowScene: scene)
            window.frame = frame
        } else {
            window = UIWindow(frame: frame)
        }
        let controller = UIViewController()
        window.rootViewController = controller
        controller.loadViewIfNeeded()
        controller.view.frame = frame
        web.frame = controller.view.bounds
        web.autoresizingMask = [.flexibleWidth, .flexibleHeight]
        controller.view.addSubview(web)
        window.isHidden = false
        controller.view.layoutIfNeeded()
        self.bridge = bridge
        self.view = view
        self.coordinator = coordinator
        self.web = web
        self.window = window
        self.controller = controller
    }

    func close() {
        web.stopLoading()
        NoteWebView.dismantleUIView(web, coordinator: coordinator)
        web.navigationDelegate = nil
        web.removeFromSuperview()
        window.isHidden = true
        window.rootViewController = nil
    }
}
