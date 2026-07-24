#!/usr/bin/env node
// Versioned one-shot Claude Agent SDK bridge. Stdout is exactly one JSON result.
const sdkModule = process.env.CLAUDE_SHIM_SDK_MODULE ?? '@anthropic-ai/claude-agent-sdk';
const { query } = await import(sdkModule);

const SCHEMA = 'claude-shim/v1';

async function readRequest() {
  const chunks = [];
  for await (const chunk of process.stdin) chunks.push(chunk);
  const input = JSON.parse(Buffer.concat(chunks).toString('utf8'));
  if (input.schema !== SCHEMA || input.type !== 'request') {
    throw new Error('expected claude-shim/v1 request');
  }
  if (typeof input.model !== 'string' || !input.model) throw new Error('model is required');
  if (typeof input.prompt !== 'string' || !input.prompt) throw new Error('prompt is required');
  return input;
}

function contentBlocks(message) {
  return Array.isArray(message?.message?.content) ? message.message.content : [];
}

function nativeToolEvents(message, results) {
  const events = [];
  for (const block of contentBlocks(message)) {
    if (block?.type !== 'tool_use') continue;
    const result = results.get(block.id);
    events.push({
      tool_call_id: block.id ?? null,
      tool_name: block.name ?? 'unknown',
      arguments: JSON.stringify(block.input ?? {}),
      result: result?.content ?? '',
      status: result?.is_error ? 'failed' : 'completed',
    });
  }
  return events;
}

async function main() {
  const input = await readRequest();
  const toolResults = new Map();
  const toolUseMessages = [];
  let final = null;
  const options = {
    model: input.model,
    maxTurns: input.max_turns ?? 8,
    settingSources: [],
    persistSession: false,
    permissionMode: 'bypassPermissions',
  };
  if (typeof input.mcp_config === 'string' && input.mcp_config) {
    const parsed = JSON.parse(input.mcp_config);
    options.mcpServers = parsed.mcpServers;
  }
  if (typeof input.anthropic_base_url === 'string' && input.anthropic_base_url) {
    // Explicit capture/routing only; caller controls this field, not ambient env.
    // Set it before QUERY so the SDK/Claude child receives the same base URL.
    process.env.ANTHROPIC_BASE_URL = input.anthropic_base_url;
  }
  for await (const message of query({ prompt: input.prompt, options })) {
    if (message?.type === 'user') {
      for (const block of contentBlocks(message)) {
        if (block?.type === 'tool_result' && block.tool_use_id) {
          toolResults.set(block.tool_use_id, { content: typeof block.content === 'string' ? block.content : JSON.stringify(block.content ?? ''), is_error: Boolean(block.is_error) });
        }
      }
    }
    if (message?.type === 'assistant') toolUseMessages.push(message);
    if (message?.type === 'result') final = message;
  }
  const toolEvents = toolUseMessages.flatMap((message) => nativeToolEvents(message, toolResults));
  if (!final || typeof final.result !== 'string') throw new Error('Agent SDK stream lacked terminal result');
  process.stdout.write(JSON.stringify({
    schema: SCHEMA,
    type: 'result',
    text: final.result,
    model: typeof final.model === 'string' ? final.model : input.model,
    finish_reason: final.subtype ?? 'stop',
    request_id: typeof final.session_id === 'string' ? final.session_id : null,
    native_tool_events: toolEvents,
  }) + '\n');
}

main().catch((error) => {
  process.stderr.write(`${error?.stack ?? String(error)}\n`);
  process.exitCode = 1;
});
