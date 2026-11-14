---
name: "olivium-area-widgets-api"
description: "Before changing src/acme_widgets/api.py, src/acme_widgets/models.py: files that change together and their tests."
---

# Area widgets-api

These files change together (2 evidence commits):
- `src/acme_widgets/api.py`
- `src/acme_widgets/models.py`
Tests that history pairs with them:
- `tests/test_api.py` (6 joint changes); run: `uv run pytest tests/test_api.py`
- `tests/test_models.py` (3 joint changes); run: `uv run pytest tests/test_models.py`
Terms: widget size, resize, dimensions. Symbols: `create_widget` in `src/acme_widgets/api.py`:5-30
When you change one of them, check the others and run the paired tests.
