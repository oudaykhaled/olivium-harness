# Runtime availability facts for iteration 03

Read-only probe: **2026-11-01 12:16–12:18 UTC**. Local evidence: `tmp/enhancement-program/02/runtime-probe/probe.json`. Commands had six-second subprocess limits; loopback HTTP metadata requests had three-second limits. No service startup, download, model inference, build, container operation or Mix execution occurred. Credentials/private configuration bodies were not printed or inspected; Docker endpoint locality was recorded without its path.

| Question | Observed fact | Limit |
| --- | --- | --- |
| Docker CLI | `/usr/local/bin/docker`; `docker --version` exited 0: **29.7.2**, build `a7dcaa6`. | CLI presence alone does not prove daemon availability. |
| Docker daemon | Active effective endpoint verified as a local Unix socket. `docker version --format …` exited 0: server **29.7.2**, **linux/arm64**. | Metadata reachability does not establish confinement or successful coding execution. |
| Pinned runtime image | Read-only `docker --host <verified-local-socket> image inspect <code-pinned-image> --format '{{.Id}}'` exited 0 for OpenCode pin in `execution/docker.ex`. | Container executable/version, execution and isolation were not exercised. |
| Pinned proxy/grader images | The same bounded image metadata check exited 0 for both nginx and Go pins in `execution/coding.ex`. | Network isolation, proxy routing and grading behavior remain untested by this probe. |
| Ollama CLI | `command -v ollama` / executable lookup found nothing on this process's PATH. | Does not prove Ollama is uninstalled or absent outside PATH. CLI version is unknown. |
| Default Ollama service | Read-only GETs to `http://127.0.0.1:11434/api/version` and `/api/tags` both failed with connection refused, errno 61. | No service/version/model inventory was obtained at this endpoint. |
| Models | Availability is **unverified**. | No private settings, custom endpoints or model files were inspected. Do not translate an unreachable default endpoint into “no installed models.” |

All three configured image pins are retained verbatim with exit codes and IDs in the local JSON. Their metadata presence required no pull.

## Why the 15 Docker tests skip

The source guard is `@tag skip: System.get_env("HARNESSFORGE_DOCKER_TESTS") != "1"`: five occurrences in `test/harness_forge/execution_test.exs`, two in `evaluations_test.exs`, eight in `coding_evaluation_test.exs`. This probe's process did **not** have the opt-in equal to `"1"`. `test/test_helper.exs` has no availability-based Docker exclusion.

These are opt-in skips, **not evidence that Docker is missing**. Existing baseline suite results must retain that distinction. This probe did not rerun or enable the tests. The coding test at `coding_evaluation_test.exs:196` explicitly uses a synthetic upstream and establishes protocol/container integration, not real-model quality, even when run successfully.

For the iteration 03 handoff, classify local Docker daemon and pinned-image metadata as available; classify opt-in container behavior, confinement and coding qualification as unverified here; classify the default Ollama endpoint as unreachable at probe time, with installation/custom-endpoint/model inventory unknown. No iteration 02 scope expansion or runtime qualification is claimed.
