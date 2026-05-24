# Fix Flaky Cypress Component Tests — AddContentToMenu

## Context

Cypress component tests have no backend — every HTTP request must be caught by `cy.intercept()`. If a request escapes the intercept layer, Vite's proxy tries to forward it to a server that doesn't exist → `ECONNREFUSED` → Axios 500 → Cypress treats it as an uncaught exception and fails whichever test is currently running.

`handleMenuOpen()` in `AddContentToMenu.tsx` makes **4 sequential `await`ed API calls** every time the menu opens:

1. `GET /api/info/getRecentContent` — sets recent content
2. `GET /api/copyMove/checkIfContentContains?contentType=folder`
3. `GET /api/copyMove/checkIfContentContains?contentType=sequence`
4. `GET /api/copyMove/checkIfContentContains?contentType=select`

Most tests only call `cy.wait("@getRecentContent")` and then run their assertion. They never wait for the three `checkContains` calls, so those requests are still in-flight when the test ends. Cypress removes its intercepts at test teardown. The in-flight `select` request (the last of the three sequential calls — most likely still in-flight at teardown) arrives after the old intercepts are gone and before the next test's `beforeEach` intercept is registered, so it escapes to Vite's proxy.

That's exactly what the CI output shows: `checkIfContentContains?contentType=select` fails between test 5 ("shows recent content when available") and test 6 ("disables recent item when source content includes itself").

## Fix

Add the three missing `cy.wait("@checkContains")` calls to every test that opens the menu, so all network activity completes within the test that started it.

**File to edit**: `apps/app/src/popups/AddContentToMenu.cy.tsx`

For each test listed below, add `cy.wait("@checkContains")` immediately after `cy.wait("@getRecentContent")` (or after the menu click / existing waits) — before any assertion that could let the test end early.

| Test | Current waits for @checkContains | Needs to add |
|---|---|---|
| "opens menu and shows menu items" (line 96) | 1 | +2 |
| "disables Problem Set option…" (lines 129–130) | 2 | +1 |
| "disables Folder option…" (lines 162–163) | 2 | +1 |
| "shows recent content when available" (line 213) | 0 | +3 |
| **"disables recent item when source content includes itself"** (line 256) — *the failing test* | 0 | +3 |
| "shows Load into Scratch Pad option…" (line 278) | 0 | +3 |
| "disables Load into Scratch Pad when doenetmlVersion…" (line 319) | 0 | +3 |
| "does not show Load into Scratch Pad for multiple items" (line 374) | 0 | +3 |
| "navigates to scratch pad when Load into Scratch Pad is clicked" (line 396) | 0 | +3 |
| "shows suggest curation option when enabled" (line 423) | 0 | +3 |
| "shows suggest curation modal when option is clicked" (line 446) | 0 | +3 |
| "closes suggest curation modal when Close button is clicked" (line 479) | 0 | +3 |
| "truncates long recent content names" (line 526) | 0 | +3 |
| accessibility: "is accessible with menu open" (line 570) | 0 | +3 |
| accessibility: "is accessible with recent content displayed" (line 611) | 0 | +3 |
| accessibility: "is accessible with suggest curation modal open" (line 634) | 0 | +3 |

For tests that already have custom `checkContains` intercept overrides (e.g. "disables Problem Set option"), the extra waits go after the existing ones in the same place.

The waits for the failing test should go **between** `cy.wait("@getRecentContent")` and the assertion at line 258, so the test doesn't end before all API calls complete AND so the assertion fire after `setBaseContains` resolves (even though the disabled state for the recent item itself is a client-side ID comparison, not dependent on `baseContains`).

## Verification

Run the Cypress component test suite targeting this spec file:
```
npx cypress run --component --spec "apps/app/src/popups/AddContentToMenu.cy.tsx"
```
All 17 tests should pass consistently across multiple runs.
