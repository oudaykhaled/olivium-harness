# Graphiti dependency attribution

Graphiti core 0.31.2, https://github.com/getzep/graphiti,
commit d72407dcedac911e1be9fc15b55e8c05a3efcc36.
Copyright 2024, Zep Software, Inc. Licensed under Apache License 2.0;
full license retained in LICENSE.graphiti. Upstream source is unmodified.
The HarnessForge adapter composes its public classes and is separate code.

The root-generated dependencies.lock.json and uv.lock record actual resolved
packages and wheel hashes. Their notices must accompany the resulting image.
Neo4j Community 5.26.32 is a separate GPLv3 server; its root-owned exact
image/license receipts are under iteration13/backend-qualification. The server
is not embedded in this worker image. An image pin does not qualify runtime
persistence, search, deletion, provider semantics, or a company task.
