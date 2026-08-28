# Project Instructions

<!-- SOMA_MEMORY_TOOLS_START -->
## Memory Tools

Default mode: light. Do not spend tokens on memory tools for small, obvious, single-file tasks.

- projectmem: use for bugs, regressions, multi-step changes, repeated attempts, or architecture decisions. For small self-contained edits, skip full memory startup and use targeted history checks only when useful.
- Keep generated memory/tool state local unless the project explicitly decides to commit it.
<!-- SOMA_MEMORY_TOOLS_END -->

## Code Linter Policy

The repository Code Linter must use its base settings without exceptions:

- `max_file_lines`: `300`
- `max_function_lines`: `50`
- `max_nesting_depth`: `4`
- `max_parameters`: `5`
- `max_comment_lines`: `5`
- `max_doc_comment_lines`: `50`
- `max_types_per_file`: `2`

Do not increase, override, or otherwise change these values in `.code-linter.json`.
Existing violations outside the current change are tracked separately; do not
weaken the policy to make them pass.
