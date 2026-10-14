#!/usr/bin/env node
// Exercise the actual embedded history implementation without a browser or dependencies.
const assert = require('node:assert/strict');
const fs = require('node:fs');
const path = require('node:path');
const vm = require('node:vm');
const { test } = require('node:test');

const root = path.resolve(__dirname, '..');
const source = fs.readFileSync(path.join(root, 'TriliumPocket/Features/NoteWebView.swift'), 'utf8');
const script = source.match(/<script>\n([\s\S]*?)<\/script>/)[1]
  .replace(/\\([\\"nrt])/g, (_, c) => ({ '\\': '\\', '"': '"', n: '\n', r: '\r', t: '\t' }[c]));
new vm.Script(script);
const historySource = script.slice(script.indexOf('class EditorHistory {'), script.indexOf('const editorHistory='));
const EditorHistory = vm.runInNewContext(`${historySource}\nEditorHistory`);
const plain = value => JSON.parse(JSON.stringify(value));
const caret = offset => ({ anchor: [0, 0], anchorOffset: offset, focus: [0, 0], focusOffset: offset });

test('mixed edits restore exact HTML and selections in both directions', () => {
  const history = new EditorHistory();
  const states = ['<p>你好🙂</p>', '<p><b>你好🙂</b></p>',
    '<ul class="todo-list"><li><input type="checkbox">你好🙂</li></ul>',
    '<ul class="todo-list"><li><input type="checkbox" checked>你好🙂</li></ul>',
    '<ol><li><b>你好🙂</b></li></ol>', '<ol><li><b>你好🙂!</b></li></ol>'];
  history.reset(states[0]);
  for (let i = 1; i < states.length; i++) {
    history.capture(caret(i - 1));
    history.record(states[i], caret(i));
  }
  for (let i = states.length - 2; i >= 0; i--)
    assert.deepEqual(plain(history.move(-1)), { html: states[i], bookmark: caret(i) });
  assert.equal(history.move(-1), null);
  for (let i = 1; i < states.length; i++)
    assert.deepEqual(plain(history.move(1)), { html: states[i], bookmark: caret(i) });
  assert.equal(history.move(1), null);
});

test('typing and deletion coalesce only at contiguous carets within the time window', () => {
  for (const [group, states] of [['insertText', ['', 'a', 'ab']],
    ['deleteContentBackward', ['abc', 'ab', 'a']], ['deleteContentForward', ['abc', 'bc', 'c']]]) {
    const history = new EditorHistory();
    history.reset(states[0]);
    history.capture(caret(0));
    history.record(states[1], caret(1), group, 100);
    history.capture(caret(1));
    history.record(states[2], caret(2), group, 200);
    assert.equal(history.entries.length, 1);
    assert.equal(history.move(-1).html, states[0]);
    assert.equal(history.move(1).html, states[2]);
    history.capture(caret(2));
    history.record(states[2] + 'x', caret(3), group, 300);
    assert.equal(history.entries.length, 2, 'redo ends an input group');
    history.capture(caret(0));
    history.record('y' + history.html, caret(1), group, 400);
    assert.equal(history.entries.length, 3, 'moving the caret starts another group');
    history.capture(caret(1));
    history.record('z' + history.html, caret(2), group, 1500);
    assert.equal(history.entries.length, 4, 'a pause starts another group');
  }
});

test('no-op edits preserve redo and new edits replace its branch', () => {
  const history = new EditorHistory();
  history.reset('a');
  history.record('ab', caret(2));
  history.record('abc', caret(3));
  history.move(-1);
  history.record('ab', caret(1));
  assert.equal(history.move(1).html, 'abc');
  history.move(-1);
  history.record('ab新', caret(3));
  assert.equal(history.move(1), null);
  assert.equal(history.move(-1).html, 'ab');
  assert.equal(history.move(-1).html, 'a');
  history.reset('another note');
  assert.equal(history.move(-1), null);
  assert.equal(history.move(1), null);
  assert.equal(history.characters, 0);
});

test('format commands and input type changes end a typing group', () => {
  const history = new EditorHistory();
  history.capture(caret(0));
  history.record('a', caret(1), 'insertText', 100);
  history.record('a', caret(1)); // Toggling formatting at a collapsed caret changes no HTML yet.
  history.capture(caret(1));
  history.record('ab', caret(2), 'insertText', 200);
  history.capture(caret(2));
  history.record('a', caret(1), 'deleteContentBackward', 300);
  assert.equal(history.entries.length, 3);
  assert.equal(history.move(-1).html, 'ab');
  assert.equal(history.move(-1).html, 'a');
  assert.equal(history.move(-1).html, '');
});

test('count and character limits retain a valid undo baseline', () => {
  const history = new EditorHistory(3, 100);
  history.reset('');
  for (let i = 1; i <= 8; i++) history.record('x'.repeat(i), caret(i));
  assert.equal(history.entries.length, 3);
  for (let i = 7; i >= 5; i--) assert.equal(history.move(-1).html, 'x'.repeat(i));
  assert.equal(history.move(-1), null);
  for (let i = 6; i <= 8; i++) assert.equal(history.move(1).html, 'x'.repeat(i));
  const limited = new EditorHistory(100, 5);
  limited.reset('');
  for (let i = 1; i <= 10; i++) limited.record('x'.repeat(i), caret(i));
  assert.equal(limited.characters, 5);
  limited.record('y'.repeat(20), caret(20));
  assert.equal(limited.entries.length, 1, 'keep the most recent edit even when it exceeds the budget');
  assert.equal(limited.move(-1).html, 'x'.repeat(10));
  assert.equal(limited.move(1).html, 'y'.repeat(20));
});

test('small changes to large notes store differences instead of complete snapshots', () => {
  const history = new EditorHistory();
  const content = '正文'.repeat(100000);
  history.reset(content);
  history.record(content + '🙂', caret(2));
  assert.equal(history.characters, 2);
  assert.equal(history.move(-1).html, content);
});

test('random Unicode edits and history branches match a reference stack', () => {
  let seed = 42;
  const random = max => { seed = (Math.imul(seed, 1664525) + 1013904223) >>> 0; return seed % max; };
  const history = new EditorHistory(10000, 10000000);
  const states = [''];
  let index = 0;
  for (let i = 0; i < 3000; i++) {
    const action = random(5);
    if (action === 0 || action === 1) {
      const direction = action === 0 ? -1 : 1;
      const next = index + direction;
      const result = history.move(direction);
      if (next < 0 || next >= states.length) assert.equal(result, null);
      else { index = next; assert.equal(result.html, states[index]); }
    } else {
      const text = states[index];
      const start = random(text.length + 1);
      const end = start + random(text.length - start + 1);
      const next = text.slice(0, start) + ['中文', '🙂', '<p>', '&amp;', ''][random(5)] + text.slice(end);
      history.capture(caret(start));
      history.record(next, caret(start + 1));
      if (next !== text) { states.splice(index + 1); states.push(next); index++; }
    }
    assert.equal(history.html, states[index]);
    assert.equal(history.index, index);
    assert.equal(history.characters, history.entries.reduce((sum, entry) => sum + entry.removed.length + entry.inserted.length, 0));
  }
});
