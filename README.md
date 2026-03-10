# Agent Artifacts

A registry of reusable AI agent artifacts: skills, rules, and workflows — for development workflows. The catalog grows over time as new artifacts are added.

## Just Module

The repo provides a `module.just` that can be integrated into an existing justfile. Pull it once and import it:

```just
import? ".just/imports/areg.just"

# ...

fetch-dependencies:
    mkdir -p ".just/imports"
    curl -sL https://raw.githubusercontent.com/morzecrew/agent-artifacts/main/module.just -o ".just/imports/areg.just"
```

The module exposes recipe `pull-agent-artifacts` to fetch skills, rules, or workflows from this registry (or any compatible repo) into your project.

