#!/usr/bin/env node
// src/tooling/browser/playwright-bridge.js
//
// Playwright stdio bridge: a long-running Node process that proxies Playwright
// API calls over line-delimited JSON-RPC on stdio.
//
// This is the GENERIC browser engine layer. It has ZERO app-specific knowledge:
// no CLOG, no data-testid, no localhost:18080 hardcoded. Callers (e.g. a Lisp
// side) send JSON commands on stdin and receive JSON responses on stdout.
//
// Protocol:
//   request : {"id": <number>, "method": "<name>", "params": {...}}\n
//   response: {"id": <number>, "result": {...}}\n
//   error   : {"id": <number>, "error": {"message": "..."}}\n
//
// On startup it prints a single ready marker line:
//   READY {"videoPath":"..."}

'use strict';

const fs = require('fs');
const path = require('path');
const readline = require('readline');
const { chromium } = require('playwright');

// Write a single JSON line to stdout. Use process.stdout.write (not console.log)
// to avoid line buffering and keep the protocol strictly line-delimited.
function send(obj) {
  process.stdout.write(JSON.stringify(obj) + '\n');
}

// Buffer of console messages and page errors captured from the page.
const consoleBuffer = [];

async function main() {
  // Launch headless Chromium. The browser binary lives under the path pointed
  // to by PLAYWRIGHT_BROWSERS_PATH (set in the Dockerfile); Playwright reads it
  // automatically, so no explicit executablePath is needed here.
  const browser = await chromium.launch({ headless: true });

  // One context with video recording enabled. The video file path is reported
  // in the ready marker so callers can collect it after the run.
  const videoDir = '/tmp/pw-videos';
  fs.mkdirSync(videoDir, { recursive: true });
  const context = await browser.newContext({ recordVideo: { dir: videoDir } });
  let page = await context.newPage();

  // Capture browser console messages and uncaught page errors for get_console.
  page.on('console', (msg) => {
    consoleBuffer.push({ type: 'console', kind: msg.type(), text: msg.text() });
  });
  page.on('pageerror', (err) => {
    consoleBuffer.push({ type: 'pageerror', text: err.message });
  });

  // The video path is only known once the context/page is closed, but
  // recordVideo.dir gives us the directory; report the dir as the video path
  // placeholder so the Lisp side knows where recordings land.
  send({ ready: true, videoPath: videoDir });

  // Dispatch table for the supported methods. Each handler receives `params`
  // and returns a plain object that becomes the `result` of the response.
  const methods = {
    // Navigate to a URL and return the final URL plus the page title.
    // `timeout` is in milliseconds and defaults to 30000 when omitted by the
    // caller (the Lisp side passes *browser-default-timeout* in seconds,
    // converted to ms here).
    async navigate({ url, timeout }) {
      await page.goto(url, { waitUntil: 'networkidle', timeout: timeout || 30000 });
      return { url: page.url(), title: await page.title() };
    },

    // Click an element and return its text content.
    async click({ selector }) {
      await page.locator(selector).click();
      const text = await page.locator(selector).textContent();
      return { ok: true, text };
    },

    // Fill an input/textarea with a value.
    async fill({ selector, value }) {
      await page.locator(selector).fill(value);
      return { ok: true };
    },

    // Read the text content of an element.
    async get_text({ selector }) {
      const text = await page.locator(selector).textContent();
      return { text };
    },

    // Escape hatch: evaluate arbitrary JS in the page and return its value.
    async eval({ expression }) {
      const value = await page.evaluate(expression);
      return { value };
    },

    // Take a full-page screenshot to `path` and report the byte size.
    async screenshot({ path: p }) {
      await page.screenshot({ path: p, fullPage: true });
      const bytes = fs.statSync(p).size;
      return { path: p, bytes };
    },

    // Assert an expression is truthy in the page. Returns pass + the value.
    async assert({ expression }) {
      const v = await page.evaluate(expression);
      return { pass: !!v, value: v };
    },

    // Wait for a selector to appear. Returns {ok:false} on timeout.
    async wait_for({ selector, timeout }) {
      try {
        await page.locator(selector).waitFor({ timeout: timeout || 10000 });
        return { ok: true };
      } catch (e) {
        return { ok: false };
      }
    },

    // Return buffered console/pageerror messages and clear the buffer.
    async get_console() {
      const messages = consoleBuffer.slice();
      consoleBuffer.length = 0;
      return { messages };
    },

    // Save the recorded video to a target path. The video file is only
    // finalized when the page closes, so this method:
    //   1. Gets the current video file path (while the page is still open)
    //   2. Closes the page (which finalizes the .webm file on disk)
    //   3. Copies the finalized video to the requested path
    //   4. Opens a fresh page (with video recording) for continued interaction
    // The caller should navigate again after save_video since the page is new.
    async save_video({ path: targetPath }) {
      // Step 1: get the current video file path before closing
      const video = page.video();
      const sourcePath = video ? await video.path() : null;
      // Step 2: close the page to finalize the video file
      try { await page.close(); } catch (e) {}
      // Step 3: copy the finalized video to the target path
      let bytes = 0;
      if (sourcePath && fs.existsSync(sourcePath)) {
        fs.copyFileSync(sourcePath, targetPath);
        bytes = fs.statSync(targetPath).size;
      }
      // Step 4: open a fresh page with video recording for continued use
      page = await context.newPage();
      page.on('console', (msg) => {
        consoleBuffer.push({ type: 'console', kind: msg.type(), text: msg.text() });
      });
      page.on('pageerror', (err) => {
        consoleBuffer.push({ type: 'pageerror', text: err.message });
      });
      return { path: targetPath, bytes, sourcePath };
    },

    // Close everything and exit the process.
    async close() {
      try { await page.close(); } catch (e) {}
      try { await context.close(); } catch (e) {}
      try { await browser.close(); } catch (e) {}
      process.exit(0);
    },
  };

  // Read line-delimited JSON requests from stdin. Commands are processed
  // STRICTLY SEQUENTIALLY: each command is fully awaited before the next is
  // dispatched. This prevents race conditions where a fast-arriving 'close'
  // command tears down the browser while a 'navigate' is still in flight.
  const rl = readline.createInterface({ input: process.stdin });
  let processing = false;
  const queue = [];

  async function processQueue() {
    if (processing) return;
    processing = true;
    while (queue.length > 0) {
      const line = queue.shift();
      let req;
      try {
        req = JSON.parse(line);
      } catch (e) {
        send({ id: null, error: { message: 'invalid JSON: ' + e.message } });
        continue;
      }
      const { id, method, params } = req;
      const handler = methods[method];
      if (!handler) {
        send({ id, error: { message: 'unknown method: ' + method } });
        continue;
      }
      try {
        const result = await handler(params || {});
        send({ id, result });
      } catch (e) {
        send({ id, error: { message: e && e.message ? e.message : String(e) } });
      }
    }
    processing = false;
  }

  rl.on('line', (line) => {
    queue.push(line);
    processQueue();
  });

  // If stdin closes without a close command, shut down cleanly.
  rl.on('close', async () => {
    // Wait for any in-flight command to finish before closing.
    while (processing) { await new Promise(r => setTimeout(r, 50)); }
    try { await browser.close(); } catch (e) {}
    process.exit(0);
  });
}

main().catch((e) => {
  process.stderr.write('FATAL: ' + (e && e.message ? e.message : String(e)) + '\n');
  process.exit(1);
});
