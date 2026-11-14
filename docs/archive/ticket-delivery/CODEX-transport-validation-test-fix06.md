# Transport validation test strengthening 06

This changes one test-evidence gap, not the unexplained Root143 CLI failure. Root144’s new diagnostic observed all 45 expected calls in 1,518 ms, maximum 307 ms, and verified fixture cleanup. Its result explicitly records root143_fixed:false. That observation does not repair or erase Root143’s two canonical failures.

The previous malformed-field test placed 22 distinct real CLI observations inside one ExUnit case. A generic CLI failure returned the same coding_transport_unavailable as the intended schema denial, and 22 independent 3 s command waits could exceed the unchanged 60 s case timeout.

The same fourteen missing/nil mutations and eight malformed/oversized inputs now generate 22 separately named ExUnit cases. Each gets the existing fresh fixture and first requires CodingTransport.observe/0 to succeed on the valid metadata, with the exact original fixture endpoint and desktop route. It then applies its one original mutation and requires the unchanged SDK error assertion. Its command journal must contain both SDK invocations. An unavailable fixture therefore fails the healthy control instead of passing an entire sequence of negative assertions. A later, per-call transport failure can still share the generic denial reason; these tests do not claim otherwise.

No timeout, production command, transport, fixture implementation or context-positive test changed. Each malformed case performs two SDK calls rather than aggregating all variants under one case deadline; no extra post-restoration loop or repeated runtime qualification was added. Only the former combined test block changed; reverse reconstruction matches the entire Root143 test-source hash. This adds 21 registered cases relative to the former single case.

Root owns execution: run the focused module, then one canonical check using original seed 45559 with these stronger tests, preserving Root143’s red evidence and limits regardless of later results. No tests, commands, native runtime, models, browser, services or board updates were run by this author. Passing these finite fake-CLI checks would establish the tested transport-validation behavior only.
