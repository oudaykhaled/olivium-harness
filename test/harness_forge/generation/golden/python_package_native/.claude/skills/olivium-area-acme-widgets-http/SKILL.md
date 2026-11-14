---
name: "olivium-area-acme-widgets-http"
description: "Before changing src/acme_widgets/http/h11.py, src/acme_widgets/http/tools.py: files that change together, their tests and past fixes."
---

# Area acme-widgets-http

These files changed together in 8 commits (history up to b2895b52ee):
- `src/acme_widgets/http/h11.py`
- `src/acme_widgets/http/tools.py`
Tests that history pairs with them:
- `tests/test_http.py` (6 joint changes); run: `uv run pytest tests/test_http.py`
- `tests/test_tools.py` (3 joint changes); run: `uv run pytest tests/test_tools.py`
Past fixes touching them: a757448394, e8743d0fac, a68cf83c27
Reverted or fixed again before: `src/acme_widgets/http/h11.py` (reverts: 1, follow-up fixes within 7 days: 2)
When you change one of them, check the others and run the paired tests.
