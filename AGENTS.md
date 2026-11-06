# Agent instructions

## Test selection

- Run only tests added or changed by the current work, plus existing tests that clearly cover behavior or code paths affected by it.
- Do not run the full test suite unless the person explicitly asks for it.
- If a configured test command runs the full suite, select the relevant spec paths instead.
- Report the exact test commands and results. Do not broaden test selection just to get a general pass signal.
