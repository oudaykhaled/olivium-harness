# Olivium Harness website

The branded product introduction and illustrative workflow live in this folder. These static HTML/CSS/JavaScript files do not run the Elixir application or invoke model providers.

## Preview

From the repository root:

```sh
python3 -m http.server 8917 --bind 127.0.0.1 --directory website
```

Open http://127.0.0.1:8917.

## GitHub Pages

Planned URL: https://oudaykhaled.github.io/olivium-harness/

Activation is currently blocked: GitHub returned HTTP422, “Your current plan does not support GitHub Pages for this repository.” The repository remains private. Enabling Pages requires a compatible account plan or an explicit repository-visibility change. After Pages is enabled with GitHub Actions as its build source, rerun the workflow on main.

`.github/workflows/pages.yml` validates and publishes only `website/`. Pushes changing this folder, the validator or the workflow on `main` deploy automatically. Pull requests validate without deploying. The workflow can also be started manually from Actions on `main`.

The `github-pages` environment and GitHub's short-lived deployment token are used; no personal deployment token is stored. Pages must be enabled with GitHub Actions as the build source. The repository can remain private when the account's plan supports Pages for private repositories.

The website uses the approved purple H logo and italic O animation. The original Sites deployment is separate and is not changed by this pipeline.
