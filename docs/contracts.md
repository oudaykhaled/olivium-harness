# Frozen interchange contract: v1alpha1

`priv/schemas/harness-v1alpha1.json` is the complete JSON Schema (2020-12).
`priv/schemas/records-v1alpha1.json` defines immutable provenance and lifecycle
record DTOs; database schemas may carry additional internal fields.

The harness uses string keys and `apiVersion: harnessforge.dev/v1alpha1`,
`kind: Harness`. All sections are required. Unknown fields are rejected.
Runtime version `unqualified` in the public fixture deliberately makes no
runtime compatibility claim. The fixture's package paths are candidates until
the adapter's compatibility checks pass.

Public interfaces:

- `HarnessForge.Contracts.decode_harness(bytes)` rejects malformed JSON,
  duplicate keys, inputs larger than 2,000,000 bytes, and nesting beyond 16.
- `validate_harness(map)` returns `{:ok, map}` or `{:error, %Contracts.Error{}}`.
  It checks shape, bounds, duplicate IDs, citation ranges, goal references and
  the presence of an evidence or future-goal basis. Citation authorization,
  content verification, conflict resolution and approval remain context checks.
- `canonical_json(term)` sorts string object keys by UTF-8 byte ordering,
  preserves array order and Unicode, and emits compact Jason scalar encodings.
  Only strings, safe integers, booleans, null, arrays and string-key maps are
  accepted. Floats, structs and atom keys are rejected. This project format is
  deliberately narrower than general JSON and is not RFC 8785.
- `digest(term)` hashes these canonical bytes using SHA-256, lowercase hex.
  `sha256(binary)` hashes the exact supplied bytes without transformation.

All IDs are opaque UUID strings; use `Ecto.UUID.generate/0` internally. Citations
address normalized UTF-8 bytes with start inclusive and end exclusive. Hash the
exact byte slice. No imported body may create decisions or release approvals.

`Contracts.Connector`, `Contracts.ModelProvider`, and
`Contracts.RuntimeAdapter` are compiled-in behaviours. Callback DTOs use string
keys. A connector page contains `items`, `next_cursor`, and `complete`. Model
requests contain explicit `request_id`, `model`, `messages`,
`max_output_tokens` and `timeout_seconds`; callers reserve budgets before
dispatch. A runtime compilation contains `files` (relative path → binary),
`capabilities` and `diagnostics`. Compilation never executes repository tools.

Boundary failures use stable `code`, a safe `message`, `retryable`,
`correlation_id` and bounded safe `details`. Never include secrets or raw
provider responses. Harness shape failures use `invalid_harness`.

The synthetic company includes conflicting rules, prompt injection, a fabricated
citation, future intent and expected dispositions. Go task seeds deliberately
contain bugs. Their protected checks must remain outside candidate-writable
storage. They are evaluator fixtures, not ordinary project test suites.

Canonical artifact identity should hash the canonical spec and a sorted manifest
of relative paths, modes and content hashes plus compiler/template/adapter
versions. Exclude local absolute paths, credentials, timestamps and archive
metadata. Published bytes are immutable; reconciliation removes orphan stages.

Approval applies to an exact revision and digest. Edits create proposed revisions;
promotion requires applicable passed evaluation, human approval, current source
access and satisfied required controls. Rollback appends a new channel assignment
and cannot undo remote effects. Revocation blocks retrieval and future exports;
purge separately removes retained local payloads under the retention policy.
