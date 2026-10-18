---
spine: 1
title: Verify
description: Show that the change works
kind: verify
status: not_started
depends_on: [implement]
gates: [checklist, ci]
---

# Verify

Run the tests and the linter, and try the change the way a user would. Write down what you ran and what you saw.

## Done when

- [ ] The test suite and the linter pass
- [ ] The change was tried by hand, and the result is noted
- [ ] CI is green on the branch
