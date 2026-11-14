# click

## Commands
- Test: `uv run pytest`
- Test one: `uv run pytest -k <expr>`
- Lint: `uv run ruff check`
- Format: `uv run ruff format`
- Typecheck: `uv run mypy`
- Build: `uv build`
- Install: `uv sync --all-extras`

## Layout
- `src/click`: Python package source

## Conventions
- Tests live under tests/ as test_*.py files

## Do and Don't
- Add an entry to CHANGES.md with every bug fix
- Avoid ternary expressions (`x if cond else y`): coverage cannot measure both branches.
