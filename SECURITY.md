# Security policy

This local pre-release candidate supports one trusted operator, a private
workspace and a loopback endpoint. No hosted multiuser profile, enterprise
support window or response-time guarantee is offered.

## Reporting

No public repository/private security contact exists for this candidate. Do not
post exploits, access codes, credentials, private evidence or backups in public
issues. The owner must establish a private route before public distribution.

Once a GitHub repository has private vulnerability reporting enabled, use its
**Security → Advisories → Report a vulnerability** route. This does not claim
that an inbox exists today. See
[GitHub's reporting guide](https://docs.github.com/en/code-security/security-advisories/working-with-repository-security-advisories/privately-reporting-a-security-vulnerability).

A useful private report includes commit/version, platform, synthetic reproduction,
impact and containment steps. Redact secrets; avoid raw evidence/workspace files.

## Boundaries

Imported documents/model output cannot approve claims or grant themselves
privileges. A preview package does not certify safe behavior. Containers trust
Docker/kernel; offline smokes do not establish coding quality. Missing isolation,
consent, availability or verified cleanup must block qualification.

Workspaces/backups contain private material; backups are unencrypted. Another
process with the same OS user permissions can access data. Content purge is
logical, not physical erasure. See [architecture](docs/architecture.md) and
[privacy](docs/privacy.md).
