#!/usr/bin/env node
// Exercise the embedded table serializer with lightweight node fixtures, without a browser.
const assert = require('node:assert/strict');
const fs = require('node:fs');
const path = require('node:path');
const vm = require('node:vm');
const { test } = require('node:test');

const source = fs.readFileSync(path.join(__dirname, '../TriliumPocket/Features/NoteWebView.swift'), 'utf8');
const script = source.match(/<script>\n([\s\S]*?)<\/script>/)[1]
  .replace(/\\([\\"nrt])/g, (_, c) => ({ '\\': '\\', '"': '"', n: '\n', r: '\r', t: '\t' }[c]));
const serializer = script.slice(script.indexOf('function tableMarkdown('), script.indexOf('function editTable('));
const tableMarkdown = vm.runInNewContext(`${serializer}\ntableMarkdown`, {
  Node: { TEXT_NODE: 3, ELEMENT_NODE: 1 },
});
const text = value => ({ nodeType: 3, textContent: value });
function element(tagName, children, attributes = {}) {
  const style = Object.keys(attributes.style || {});
  Object.assign(style, attributes.style);
  return {
    nodeType: 1, nodeName: tagName, tagName, childNodes: children, style, colSpan: 1, rowSpan: 1,
    get textContent() { return children.map(child => child.textContent).join(''); },
    hasAttribute: name => Object.hasOwn(attributes, name),
    getAttribute: name => attributes[name] ?? null,
  };
}
const cell = (...children) => element('TD', children);
function table(rows) {
  const cells = rows.flat();
  return {
    rows: rows.map(cells => ({ cells })),
    querySelector: () => null,
    querySelectorAll: () => cells,
  };
}

test('ordinary Trilium table cells become Markdown with alignment and escaped punctuation', () => {
  const heading = cell(text('Name'));
  heading.style.textAlign = 'left';
  const size = cell(text('Size'));
  size.style.textAlign = 'right';
  const result = tableMarkdown(table([[heading, size],
    [cell(element('P', [text('Windows | *data*')])), cell(text('320G'))]]));
  assert.equal(result, '| Name | Size |\n| :--- | ---: |\n| Windows \\| \\*data\\* | 320G |');
});

test('inline formatting, code delimiters, links and literal HTML survive serialization', () => {
  const result = tableMarkdown(table([[cell(text('Content'))], [cell(
    element('STRONG', [text('Bold')]), text(' '), element('EM', [text('italic')]),
    element('BR', []), element('CODE', [text('a`|b')]), text(' <br> '),
    element('A', [text('Link')], { href: 'https://example.com/a(b)' }),
  )]]));
  assert.ok(result.includes('**Bold** *italic*<br>`` a`\\|b ``'));
  assert.ok(result.includes('\\<br\\>'));
  assert.ok(result.includes('[Link](https://example.com/a\\(b\\))'));
  assert.ok(tableMarkdown(table([[cell(element('CODE', [text('   ')]))]])).includes('`   `'));
  assert.ok(tableMarkdown(table([[cell(text('Line'), element('BR', []))]])).includes('Line<br>'));
});

test('complex structures and cell formatting fail before any edit can be applied', () => {
  const merged = cell(text('Merged'));
  merged.colSpan = 2;
  assert.throws(() => tableMarkdown(table([[merged]])), /HTML/);
  assert.throws(() => tableMarkdown(table([[cell(text('A'))], []])), /HTML/);
  assert.throws(() => tableMarkdown(table([[cell(element('IMG', []))]])), /HTML/);
  assert.throws(() => tableMarkdown(table([[cell(element('SPAN', [text('Styled')], { class: 'special' }))]])), /HTML/);
  const styled = cell(text('Color'));
  styled.style.push('background-color');
  assert.throws(() => tableMarkdown(table([[styled]])), /HTML/);
  assert.throws(() => tableMarkdown(table([])), /HTML/);
});
