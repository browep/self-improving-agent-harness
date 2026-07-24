// Deterministic fake for Docker bridge framing tests; never contacts Anthropic.
export async function* query() {
  yield { type: 'assistant', message: { content: [{ type: 'tool_use', id: 'call-1', name: 'mcp__harness__run_shell', input: { command: 'printf bridge_ok' } }] } };
  yield { type: 'user', message: { content: [{ type: 'tool_result', tool_use_id: 'call-1', content: 'bridge_ok', is_error: false }] } };
  yield { type: 'result', result: 'fake-final', model: 'fake-model', subtype: 'success', session_id: 'fake-session' };
}
