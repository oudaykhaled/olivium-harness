# HarnessForge glossary

These terms describe the existing lifecycle and the frozen company-builder
contract. Planned records are not a statement of implementation status.

| Term | Meaning |
| --- | --- |
| Workspace | Local privacy, ownership and persistence boundary; one active workspace per process. |
| Company | The organization represented by one workspace; its profile is descriptive metadata, not a new tenant or account. |
| Project | An operator-defined group of repository identities with explicitly applicable sources and goals. It is distinct from a provider's project or board. |
| Repository | A catalogue entry identified by an opaque repository identity, with purpose, ownership, capabilities and declared dependencies. Registration does not import code. |
| Capability | A searchable description of what a repository/service provides; not a verified compatibility or policy assertion. |
| Consumer | A repository whose declared dependency list references another repository; derived from dependency edges. |
| Connection | An explicitly scoped source importer. An authenticated account alone is not an imported or synchronized connection. |
| Source | A captured logical item belonging to a connection. |
| Source revision | Immutable captured content with an exact content hash and observation metadata. |
| Citation | Exact validated byte span of a source revision, with snippet identity. |
| Applicability | The operator's explicit statement that a source or goal is relevant to company/project/repository scope; it does not grant remote access or inference consent. |
| Claim revision | Immutable proposed normative statement and its supporting basis; an exact human decision is required before compilation as approved policy. |
| Decision | Append-only human approval or rejection tied to an exact claim revision hash. |
| Goal | Owned future intent with acceptance conditions; selecting it does not approve a derived policy. |
| Preset component | A finite, versioned, compiled-in agent/skill workflow template with no arbitrary command or policy input. |
| Plan | Immutable selected scope, claims, goals, finite templates and proposed roadmap milestones. An exact human plan decision is required before build; a newer plan does not revoke an already approved predecessor. |
| Plan decision | Explicit approval or rejection of an exact plan revision hash; separate from every claim decision and from release approval. |
| Artifact binding | Local immutable link from an exact approved plan revision to an artifact digest, revalidated for export and release eligibility. |
| Composition | The selected inputs and their exact lineage captured in a plan snapshot; this wave retains full company-plan provenance locally and exports existing v1alpha1. |
| Roadmap milestone | Proposed capability work with goal rationale, prerequisites, acceptance and evaluation method; it is not an automatic schedule or release approval. |
| Artifact | Immutable generated native preview bytes, manifest, provenance and content identity. |
| Evaluation | Persisted observed check/task result with applicability identities; static checks and runtime diagnostics do not establish task qualification. |
| Release approval | Human decision bound to an artifact and its applicable qualified evaluation, scope and environment. |
| Channel assignment | Append-only local activation history pointing to an approved artifact. |
| Rollback | A new channel assignment to an eligible previously approved artifact; it does not undo external code or data changes. |
| Withdrawal | Removal of current source access or scope applicability; may invalidate dependent plan/artifact eligibility without rewriting immutable bytes. |
| Purge | Explicit logical removal of retained local payloads; distinct from withdrawal and from physical erasure of backups, disks or provider copies. |
