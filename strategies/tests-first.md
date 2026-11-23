---
title: Tests first
summary: A failing test first, then the code that makes it pass.
spawn: none
---

For every behaviour you add or fix:

1. **Write the test first** and run it. It must fail, and for the right reason: the missing behaviour,
   not a typo or a missing import.
2. **Implement** the smallest change that makes it pass, and run it again.
3. **Run the full relevant suite** before moving on, and fix what broke.

Say in one line per step which test you wrote and how it failed, so the user can follow the red and green.
