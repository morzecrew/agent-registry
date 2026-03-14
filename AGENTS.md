# AGENTS

## Cursor Cloud specific instructions

This is a content-only registry of reusable AI agent artifacts (skills, rules, workflows). There is no application server, database, or build step.

### Required tools

- `just` (task runner) — installed to `~/bin`; ensure `$HOME/bin` is on `PATH`.
- `markdownlint-cli` (via npm) — used for linting `*.md` files.
- System: `git`, `awk`, `bash` (pre-installed).

### Linting

```sh
markdownlint '**/*.md'
```

The config lives in `.markdownlint.yml` (`default: false` — all rules disabled unless explicitly enabled).

### Running the core recipe

```sh
just pull-agent-artifacts [options]
```

See `just --list` for available arguments. The recipe performs a sparse Git checkout to fetch artifacts from a remote repo.

### Gotchas

- The `justfile` sets `set shell := ["bash", "-cu"]`, so all recipes require Bash.
- `module.just` uses `require("git")` and `require("awk")` — both must be on `PATH` or `just` will error at parse time.
- There are no automated tests in this repository.
