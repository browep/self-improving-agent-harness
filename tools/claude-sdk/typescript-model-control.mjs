import { query } from '@anthropic-ai/claude-agent-sdk';

const model = process.env.CLAUDE_TEST_MODEL;
if (!model) throw new Error('CLAUDE_TEST_MODEL is required');

try {
  for await (const message of query({
    prompt: 'Return exactly: TYPESCRIPT_SDK_OK',
    options: { model, maxTurns: 1, settingSources: [], persistSession: false },
  })) {
    console.log(JSON.stringify({
      requested_model: model,
      type: message.type,
      subtype: message.subtype ?? null,
      is_error: message.is_error ?? null,
      result_length: typeof message.result === 'string' ? message.result.length : null,
      errors: Array.isArray(message.errors) ? message.errors.map(() => '[redacted]') : null,
    }));
  }
} catch (error) {
  console.log(JSON.stringify({ requested_model: model, thrown: true,
    name: error?.name ?? 'Error', message: String(error?.message ?? error).slice(0, 500) }));
}
