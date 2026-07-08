# Project Instructions

<!-- SOMA_MEMORY_TOOLS_START -->
## Memory Tools

Default mode: light. Do not spend tokens on memory tools for small, obvious, single-file tasks.

- Codebase-Memory: use only for unknown code discovery, call graph/impact checks, or broad refactors. For known files, strings, or configs, read files or use `rg` directly.
- projectmem: use for bugs, regressions, multi-step changes, repeated attempts, or architecture decisions. For small self-contained edits, skip full memory startup and use targeted history checks only when useful.
- Keep generated memory/tool state local unless the project explicitly decides to commit it.
<!-- SOMA_MEMORY_TOOLS_END -->
