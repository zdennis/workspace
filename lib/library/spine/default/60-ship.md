---
spine: 1
title: Ship
description: Get the change merged
kind: ship
status: not_started
depends_on: [review]
gates: [pushed, pr, ci, merged]
---

# Ship

Push {{BRANCH}}, open the pull request, keep CI green and see the change merged.

## Done when

- [ ] The branch is pushed
- [ ] A pull request is open
- [ ] CI passes on the pull request
- [ ] The pull request is merged
