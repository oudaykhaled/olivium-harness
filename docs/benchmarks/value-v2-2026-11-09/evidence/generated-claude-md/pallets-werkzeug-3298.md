# werkzeug

## Commands
- Test: `uv run pytest`
- Test one: `uv run pytest -k <expr>`
- Lint: `uv run ruff check`
- Format: `uv run ruff format`
- Typecheck: `uv run mypy`
- Build: `uv build`
- Install: `uv sync`

## Layout
- `src/werkzeug`: Python package source

## Conventions
- Tests live under tests/ as test_*.py files

## Change together
- Change `src/werkzeug/datastructures/cache_control.py` and `tests/test_datastructures.py` together

## Do and Don't
- Add an entry in CHANGES.rst summarizing the change and linking to the issue.
