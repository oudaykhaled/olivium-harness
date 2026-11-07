# OpenAI and Claude model APIs

HarnessForge supports model inference through OpenAI Responses (`openai_responses`), Claude Messages (`anthropic`), the existing OpenAI Chat Completions adapter (`openai`), and local Ollama (`ollama`). Cloud inference starts disabled. API responses can propose claims; an explicit human decision must approve each immutable claim revision before compilation.

The Codex CLI and Claude Code agent exports are separate integrations. A browser or CLI subscription login does not configure these model API adapters. The coding evaluation runtime continues to require its supported local Ollama relay and isolated Docker execution; selecting a cloud authoring provider never enables a cloud coding runtime.

## Configure without storing a key

Set a dedicated `HARNESSFORGE_*` API key environment variable in the process that starts HarnessForge. Enter only its **variable name** in configuration. The value is read at dispatch, must contain 1–16,384 bytes, and must not contain carriage returns, line feeds, NUL or invalid UTF-8. Restart the native application after changing its inherited environment. Do not paste credentials into the portal, configuration JSON, prompts, repository, or chat.

Configure a provider, an explicitly selected model available to your API account, positive declared input/output rates, and consent for exact source IDs and data categories. The configuration shape for the Elixir context is:

```elixir
HarnessForge.Models.configure(%{
  "provider" => "openai_responses",
  "endpoint" => "https://api.openai.com/v1",
  "model" => "YOUR_EXPLICIT_MODEL_ID",
  "credential_env" => "HARNESSFORGE_OPENAI_API_KEY",
  "input_microusd_per_million" => 1_000_000,
  "output_microusd_per_million" => 1_000_000,
  "cloud_consent" => %{
    "provider" => "openai_responses",
    "endpoint" => "https://api.openai.com/v1",
    "source_ids" => ["YOUR_CAPTURED_SOURCE_UUID"],
    "data_categories" => ["source_body"]
  }
})
```

The example rates are synthetic unit-test values, **not provider prices**. Both rates are integer micro-US dollars per million tokens; 1,000,000 means $1 per million tokens. Use conservative rates appropriate to the selected model and features. No API model is selected or paid call made automatically.

For Claude, set `provider` and consent provider to `anthropic`, both endpoints to `https://api.anthropic.com/v1`, and the environment reference to your dedicated Anthropic variable. These endpoint strings are exact allowlisted destinations; proxies, alternate ports, paths, redirects, credentials in URLs and arbitrary hosts are rejected. Settings and their cloud consent are scoped to the active workspace. Consent is bound to provider, destination, selected source IDs and data categories. It does not authorize unrelated sources or categories.

`Models.status/0` reports local configuration availability and `fixture_tested_live_unverified` for cloud adapters. An available configuration means a selected model, consent, positive rates and a resolvable credential reference; it does not establish successful authentication, model access, balance, provider compatibility or a completed API request.

## Requests and failure behavior

OpenAI Responses uses `POST /v1/responses`, `store: false`, `stream: false`, `tools: []`, `tool_choice: none`, `max_output_tokens` and the proposal JSON schema in `text.format`. Only completed assistant text is accepted. Incomplete output, refusal blocks, tool calls and unknown output item types fail. Reasoning items may accompany text but do not become evidence or instructions.

Claude uses `POST /v1/messages`, `x-api-key`, API version `2026-10-21`, `stream: false`, `max_tokens`, a top-level system instruction, and `output_config.format` JSON schema. No tools, extended thinking, prompt caching configuration or execution capability are requested. Only text content with `stop_reason: end_turn` is accepted. Refusals, token truncation, tool blocks, thinking blocks and other stop reasons fail.

Anthropic does not accept the proposal schema's `maxLength`/`maxItems` constraints in its grammar. Only these unsupported wire constraints are omitted. HarnessForge then applies its full existing proposal validator: at most 30 claims, 4,000 characters per claim, 1–10 citations, exact current source/revision IDs and exact UTF-8 byte spans. Unknown authority fields, duplicate JSON keys, fabricated quotations and attempted approval instructions fail before any claim persists. Imported and model-generated text remains untrusted data.

All providers share the bounded Req transport: response ceiling 262,144 bytes, output text ceiling 131,072 bytes, request output limit at most 4,096 tokens, explicit receive timeout at most 60 seconds, redirects disabled and automatic retries disabled. HTTP authentication/rate failures and even HTTP 200 provider error envelopes return safe error codes. Raw provider bodies, exception text, credentials and prompts are not copied into audit or budget records.

Every inference uses `Models.infer/2` with a durable run/request reservation. A reused request ID cannot dispatch again. Failed, interrupted or usage-unknown requests retain the full token and estimated cost reservation. A new request ID with the same payload remains fenced while a prior dispatch outcome is uncertain. This prevents an automatic retry from hiding a second potential charge.

Reported successful usage reconciles the ledger. OpenAI `output_tokens` already includes reasoning tokens, so details are not added again. Claude input totals include `input_tokens + cache_read_input_tokens + cache_creation_input_tokens`; missing/malformed required usage remains unknown. All cloud billing is **estimated** from operator-declared rates, never classified as local/unpriced or represented as an invoice. Cached input/write/read rates, tiers and other provider charges may differ; set declared rates conservatively and reconcile actual charges with the provider. Reported overruns remain visible and block later requests when a hard run limit is exhausted.

Source purge withdraws all model configuration and consent for that workspace. Backup/restore removes model settings, consent, budgets and requests before opening the restored workspace. Environment variable values are never present in those backups. Configure the restored workspace explicitly again.

## Verification and limits

Run:

```sh
mix test test/harness_forge/cloud_model_connectors_test.exs test/harness_forge/models_test.exs
```

The new 16-test module exercises real `Models.propose/infer`, proposal persistence, metered database reservations, immutable dispatch IDs, quota admission, wire request routes/auth/schema, Responses reasoning accounting, Claude cache accounting, malformed/partial/refusal/tool output, HTTP errors, timeouts, oversized responses, credential redaction, source purge and committed backup/restore. Requests use synthetic Req.Test HTTP responses. Existing Ollama and Chat Completions tests run alongside it. These tests establish application behavior, not authenticated live model availability. No paid cloud calls were made for this implementation.

## Decision record

**Context:** The project already has a consent-aware authoring model boundary and durable usage ledger. The user requested both OpenAI/Codex and Claude APIs in addition to coding-agent integration.

**Decision:** Extend that boundary with separate first-party Responses and Messages adapters; retain the existing Chat Completions provider for compatibility. Use Req 0.7.5, exact destinations, schema-constrained text, no tools and no automatic retry. Preserve source-scoped consent, immutable proposal authority and existing budget reservation semantics.

**Consequences:** The API model is operator-selected and compatibility remains explicit. Structured outputs reduce parsing failures but do not grant authority or guarantee citations. Conservative reservations can block a run after an uncertain dispatch; that is intentional protection against duplicate potential charges. Cloud APIs support authoring, while isolated coding runtime support remains explicit and separate.

**Alternatives:** A single OpenAI-compatible HTTP adapter would reduce code but hide Anthropic's different request, refusal, usage and schema contracts. A general agent SDK would provide tool orchestration but add execution authority and duplicate this application's existing consent/ledger boundary. Separate bounded adapters keep the differences testable with no new dependency.

Official references checked for this implementation on 2026-10-31: [OpenAI structured outputs](https://developers.openai.com/api/docs/guides/structured-outputs), [OpenAI Responses migration and storage](https://developers.openai.com/api/docs/guides/migrate-to-responses), [Claude structured outputs](https://platform.claude.com/docs/en/build-with-claude/structured-outputs), [Claude Messages](https://platform.claude.com/docs/en/api/messages/create), and [Claude API versions](https://platform.claude.com/docs/en/api/versioning).
