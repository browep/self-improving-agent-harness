// Deterministic fake for Docker bridge framing tests; never contacts Anthropic.
function tool(id, command) {
  return { type: 'assistant', message: { content: [{ type: 'tool_use', id, name: 'mcp__harness__run_shell', input: { command } }] } };
}
function result(id, content, is_error = false) {
  return { type: 'user', message: { content: [{ type: 'tool_result', tool_use_id: id, content, is_error }] } };
}
export async function* query({ prompt }) {
  if (prompt === 'no-tool') {
    yield { type: 'result', result: 'fake-final', model: 'fake-model', subtype: 'success', session_id: 'fake-session' };
    return;
  }
  if (prompt === 'malformed') {
    yield { type: 'assistant', message: { content: 'not-an-array' } };
    return;
  }
  if (prompt === 'sequential') {
    yield tool('call-1', 'printf first'); yield result('call-1', 'first');
    yield tool('call-2', 'printf second'); yield result('call-2', 'second');
  } else if (prompt === 'failed') {
    yield tool('call-1', 'exit 9'); yield result('call-1', 'exit 9', true);
  } else {
    yield tool('call-1', 'printf bridge_ok'); yield result('call-1', 'bridge_ok');
  }
  yield { type: 'result', result: 'fake-final', model: 'fake-model', subtype: 'success', session_id: 'fake-session' };
}
