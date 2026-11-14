---
name: "olivium-area-retry"
description: "Before changing src/acme/retry.py, src/acme/widgets.py: files that change together and their tests."
---

# Area retry

These files change together (2 evidence commits):
- `src/acme/retry.py`
- `src/acme/widgets.py`
Tests linked to them:
- `tests/test_retry.py`; run: `uv run pytest tests/test_retry.py`
Terms: retry, backoff, retries. Symbols: `RetryPolicy` in `src/acme/retry.py`:12-58, `Widget.resize` in `src/acme/widgets.py`:44-70
Note: Retry timing tests use the fake_clock fixture from tests/conftest.py; never sleep in tests.
When you change one of them, check the others and run the linked tests.
