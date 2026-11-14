# Handoff test correction 01

Root's focused check `02-focused` ran 81 tests and reported two failures in the new WEB fixture before product submission. Both were Phoenix LiveViewTest form construction errors: the newly added milestone row offered only the hidden empty goal value, while the test sent a saved goal UUID. The original output is `tmp/enhancement-program/16/checks/02-focused.log` lines 1–27; this is a test setup ordering failure, not evidence of a product name-recovery defect.

In both affected cases, the test now changes the plan using its existing project, repository, exact claim, goal, preset, runtime and execution inputs before adding the milestone row. It then changes the complete plan with the milestone and continues the original assertions. No product code or assertion was changed. Root owns the rerun and final verdict; this author ran no test or runtime command.
