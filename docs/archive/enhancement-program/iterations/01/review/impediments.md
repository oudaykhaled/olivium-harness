# Iteration 01 local prerequisite review

Owner: `i01_impediments`. Checked 1 November 2026. This was a read-only environment review, not a new product or compatibility test. Machine evidence is in `tmp/enhancement-program/01/environment.json` on the local SSD. No application was stopped, restarted or modified; no dependency was installed and no remote API was called.

## Result

No environment blocker prevents a bounded, read-only local MCP implementation and independent native test. The installed Node client supports protocol `2025-11-25`; the chosen protocol must be frozen before claiming compatibility. Python MCP is absent in the checked interpreter and is unnecessary for that test.

| Observed prerequisite | Evidence | Consequence / concrete action |
|---|---|---|
| Elixir and Mix 1.19.5; OTP 28 / ERTS 16.2 | Successful version commands; `.tool-versions` pins OTP 28.3.1 and Elixir 1.19.5-otp-28 | Existing toolchain is available. The version output itself does not identify the OTP patch. |
| Node v26.3.1, npm 11.16.0 | Successful version commands | Satisfies the installed SDK's Node `>=18` requirement. |
| Official `@modelcontextprotocol/sdk` 1.29.0 already installed transitively under global `server-memory`, `server-filesystem` and `server-sequential-thinking` | Package manifests plus `dist/esm/client/index.js` and `client/streamableHttp.js` exist | An independent external client can use the existing ESM files without a new installation. Record the absolute SDK path and version with its actual smoke result; availability alone proves no exchange. |
| SDK 1.29.0 advertises latest protocol `2025-11-25` and older revisions | Installed `dist/esm/types.js` constants | The existing client cannot establish compatibility with the proposed `2026-07-28` revision. Select the supported 2025 revision or separately provision and verify a newer client. The older GitHub server's SDK 1.0.1 has no checked Streamable HTTP client files and should not be selected. |
| Python 3.14.5 and uv 0.11.14 available; `mcp`, `fastmcp` and `httpx` absent in this interpreter | `importlib.util.find_spec`, no package imports | Use the existing Node SDK. Absence is scoped to this interpreter, not every Python installation. |
| Port 8865: PID 32400, `127.0.0.1`, native release, `tmp/demo-workspace` | `lsof` listener, cwd and open database paths | Preserve this real demonstration workspace. Do not use it for fixture imports, decisions, native smoke or CLI ownership tests. |
| Port 8866: PID 30296, `127.0.0.1`, same native release installation, `tmp/company-browser-workspace` | Same read-only process inspection | Preserve the completed company-browser evidence workspace. Use a third workspace for iteration 01. |
| Port 8867 had no listener | `lsof` exit 1 with empty output | Candidate transport-test port only; recheck immediately before starting the test owner. |
| Evidence filesystem is APFS `/dev/disk3s5`, physical store `disk0s2`, `Solid State: Yes` | `diskutil info /System/Volumes/Data` | Evidence is stored on the SSD. Approximately 12.1 GiB was free at the final capture; retain bounded text/JSON/screenshots and avoid repeated large release copies. |
| `packaging/build.sh` overwrites `_build/prod/rel/harness_forge`, which both current owners use | Build script plus process cwd evidence | For iteration-native testing, assemble the release at a distinct `mix release --path` location. Do not invoke the default packaging build against the running installation. |

## Isolated verification route

The root coordinator owns the one Mix test window. `config/runtime.exs` defaults test workspaces to `tmp/workspaces/test-<pid>` and disables the HTTP server in test mode. Keep its `HARNESSFORGE_WORKSPACE` unset or explicitly point it at an iteration-only directory; never inherit either running owner's directory. Share no mutable test workspace between independent test processes. Existing baseline 370 tests / 355 passed / 15 Docker skips is reported by the program; it was not rerun by this agent.

After the chosen implementation is integrated, root can compile and assemble a native candidate without overwriting the two running installations:

```sh
HARNESSFORGE_WORKSPACE="$PWD/tmp/enhancement-program/01/build-workspace" \
  MIX_ENV=prod mix compile --warnings-as-errors
HARNESSFORGE_WORKSPACE="$PWD/tmp/enhancement-program/01/build-workspace" \
  MIX_ENV=prod mix release \
  --path "$PWD/tmp/enhancement-program/01/native-candidate" --overwrite
```

These are proposed commands, not executed evidence. Root must also build the current assets before assembling if the iteration changes them. The current release overlay metadata must be refreshed for any package claim; a native runtime smoke alone does not establish a final distributable archive.

Use the candidate launcher with a fresh iteration-only workspace. Run any fixture provisioning CLI while its portal is stopped, because `Workspaces.acquire/1` correctly permits one owner. Then start that same fixture workspace on the reserved loopback port:

```sh
HARNESSFORGE_WORKSPACE="$PWD/tmp/enhancement-program/01/mcp-workspace" \
  RELEASE_DISTRIBUTION=none PORT=8867 \
  tmp/enhancement-program/01/native-candidate/bin/harnessforge serve
```

`RELEASE_DISTRIBUTION=none` avoids release-node naming collisions. The transport client connects to this existing owner over HTTP; it must not start a second BEAM process against that workspace. Use the synthetic workspace's own local machine credential through an in-memory header, never URL arguments or recorded transcripts. Credential values must remain absent from logs, process arguments and screenshots. The assigned guardrail reviewer determines the final authentication contract.

Independent transport QA should then execute the actual SDK initialization, discovery/list and a read call, plus the selected protocol's negative cases. Record SDK 1.29.0, protocol, command, exit status and a sanitized transcript. Browser QA can use the same synthetic owner while native MCP reads occur. Confirm read operations leave decisions/artifacts/evaluations/releases unchanged. Only the fixture owner started for iteration 01 may be stopped after verification. Its exact PID and workspace must be recorded first; neither existing owner is a cleanup target.

## External availability, not implementation blockers

Environment presence checks found `GITHUB_PERSONAL_ACCESS_TOKEN` and `GH_TOKEN` set. Checked Slack, Jira, Confluence/Atlassian, OpenAI and Anthropic variable names were absent. This says nothing about authenticated scopes or unlisted credential names; no values, browser stores, keychains or workspace secret files were extracted. These credentials are unnecessary for synthetic read-only MCP verification. Existing Projects/Slack/Atlassian and real-model qualification limitations remain unchanged and must not be converted into successful live tests.

No permission question or dependency installation is needed to remove the observed Python-client gap. No current application restart is needed to run iteration 01 independently. This agent made no product changes and ran no Mix suite, native startup, SDK exchange or remote authentication test.
