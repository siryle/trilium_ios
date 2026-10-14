#!/usr/bin/env node
// Verify embedded Markdown sizing using the shipped observer, without a browser.
const assert = require('node:assert/strict');
const fs = require('node:fs');
const path = require('node:path');
const vm = require('node:vm');
const { test } = require('node:test');

const source = fs.readFileSync(path.join(__dirname, '../TriliumPocket/Features/NoteWebView.swift'), 'utf8');
const script = source.match(/<script>\n([\s\S]*?)<\/script>/)[1]
  .replace(/\\([\\"nrt])/g, (_, c) => ({ '\\': '\\', '"': '"', n: '\n', r: '\r', t: '\t' }[c]));
const sizing = script.slice(script.indexOf('function setEmbedded('), script.indexOf("document.addEventListener('selectionchange'"));

function fixture() {
  let resize;
  let height = 0;
  const classes = new Set();
  const reported = [];
  const note = { getBoundingClientRect: () => ({ height }) };
  const setEmbedded = vm.runInNewContext(`${sizing}\nsetEmbedded`, {
    note,
    document: {
      documentElement: {
        classList: {
          contains: value => classes.has(value),
          toggle: (value, enabled) => enabled ? classes.add(value) : classes.delete(value),
        },
      },
    },
    window: { webkit: { messageHandlers: { height: { postMessage: value => reported.push(value) } } } },
    ResizeObserver: class {
      constructor(callback) { resize = callback; }
      observe(element) { assert.equal(element, note); }
    },
  });
  return {
    setEmbedded, reported,
    resize(value) { height = value; resize(); },
  };
}

test('streaming growth, shrinkage and width changes report the latest content height', () => {
  const view = fixture();
  view.setEmbedded(true);
  for (const height of [24.2, 120, 240.8, 80]) view.resize(height);
  assert.deepEqual(view.reported, [25, 120, 241, 80]);
});

test('unchanged rounded heights and empty layout do not cause update loops', () => {
  const view = fixture();
  view.setEmbedded(true);
  for (const height of [0, 24.1, 24.8, 25, 0, 25]) view.resize(height);
  assert.deepEqual(view.reported, [25]);
});

test('full page notes keep their own layout and never publish embedded sizing', () => {
  const view = fixture();
  view.resize(800);
  view.setEmbedded(true);
  view.resize(200);
  view.setEmbedded(false);
  view.resize(1000);
  assert.deepEqual(view.reported, [200]);
});
