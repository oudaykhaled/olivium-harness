# Declared conflicts: an understandable admission journey

**Proposal.** Let an operator declare two exact approved claim revisions in conflict, choose which governs, and see the specific blocker before plan approval, build or export. This is human input, not automatic detection or proof of complete company policy. Company fitness remains unproven.

**Code basis.** `Company.resolve/1` pins claims; `decide_plan/2` and `build_inputs/1` repeat eligibility (`lib/harness_forge/company.ex:234-332`). `Harnesses.build_plan/2` and `eligible/1` repeat admission (`lib/harness_forge/harnesses.ex:13-153`). `company/plan.ex:553-646` renders claims and decision; `company_panel.ex:351-439,611-626,699-720` owns selection, focus and preflight. Errors give generic stale-context advice (`company_panel.ex:850-874`). No conflict UI exists.

**Journey.** Beside selected claims in plan review, show each declaration's two claim texts, exact revisions, reason and status: **Needs decision**, **Resolved: use [claim]**, or **Outdated: claims changed**. Resolution requires explicitly selecting the winning exact revision; it grants neither claim nor plan approval. Unresolved/outdated pairs block approval/build with a named reason and focused “Review conflict” action. Once resolved, guide the operator to a successor plan selecting only the winner; never silently remove claims or rewrite approved plans. Reuse notice/error roles and `company-focus`. Verify labels, keyboard order, narrow width, zoom and RTL direction.

**Ownership.** Domain owner adds workspace-scoped immutable declarations/resolutions bound to exact claim/plan revisions, enforced at approval, build and export. UI owner owns `company/plan.ex`, `company_panel.ex` and web tests, consuming a bounded status/reason projection. Root owns schema/migration and board. Preserve privacy reset, purge/restore quarantine, stale event rejection, historical bytes and exact approvals.

**Acceptance.** An unresolved selected pair yields the same named blocker at review, build and export. Current resolution plus approved successor selecting the winner succeeds. Changed, withdrawn, foreign or superseded revisions fail safely; unrelated plans remain eligible. Verify domain paths and LiveView focus/announcement.

**Alternatives.** A free-text plan warning cannot block later export. Automatic detection lacks a trustworthy semantic contract. Exact declarations reuse approval and successor mechanics with one understandable decision.
