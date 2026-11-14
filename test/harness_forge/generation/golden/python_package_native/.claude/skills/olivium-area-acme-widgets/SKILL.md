---
name: "olivium-area-acme-widgets"
description: "Before changing src/acme_widgets/api.py, src/acme_widgets/models.py, src/acme_widgets/schema.py: files that change together, their tests and past fixes."
---

# Area acme-widgets

These files changed together in 5 commits (history up to b2895b52ee):
- `src/acme_widgets/api.py`
- `src/acme_widgets/models.py`
- `src/acme_widgets/schema.py`
Tests that history pairs with them:
- `tests/test_api.py` (6 joint changes); run: `uv run pytest tests/test_api.py`
- `tests/test_models.py` (3 joint changes); run: `uv run pytest tests/test_models.py`
Past fixes touching them: c4f3671b4d
When you change one of them, check the others and run the paired tests.
