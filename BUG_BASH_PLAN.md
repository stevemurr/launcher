# Launcher Bug Bash Plan

## Goal

Find release-blocking failures and high-friction workflow bugs across Launcher’s
keyboard, window, search, application, file, calculator, script, and settings
flows. The bash is successful when every charter below has been exercised, all
critical findings have been reproduced and assigned, and the launch-dismissal
regression passes on the supported test environments.

## Format

- **Length:** 90 minutes
- **People:** 3–6 testers, one facilitator, and one person acting as live triager
  (the facilitator may also triage with a small group)
- **Build:** Everyone tests the same commit and records that commit in every bug
- **Method:** Each tester owns one primary charter, then switches to a different
  charter for adversarial exploration

### Agenda

| Time | Activity |
| --- | --- |
| 0:00–0:10 | Kickoff, environment check, reporting rules, and demonstration of the launch-dismissal pass condition |
| 0:10–0:40 | First assigned charter |
| 0:40–1:05 | Switch charters; retest another person’s area and explore edge cases |
| 1:05–1:20 | Cross-check likely severity 0/1 issues and capture missing evidence |
| 1:20–1:30 | Live triage, deduplication, owners, and ship/no-ship summary |

## Preflight

Complete these before the session:

1. Freeze the test commit and share one build from it.
2. Run `make test`; all unit tests must pass.
3. Run `make compile-ui-tests`.
4. Run `make ui-test` in the configured ephemeral Tart VM and retain the
   `.xcresult` bundle from `test-results/`.
5. Prepare:
   - at least one app that is closed, one already running, and one noticeably
     slow to cold-launch;
   - script commands covering normal and silent modes, plus the legacy mode aliases;
   - scripts with required and optional arguments, confirmation, nonzero exit,
     long output, and a missing interpreter;
   - a directory containing files, folders, hidden files, a symlink, an app
     bundle, Unicode names, long names, and an unreadable folder;
   - an iCloud Drive folder and, if available, a slow or disconnected network
     volume.
6. Assign environments so the group covers:
   - the minimum supported macOS version and the current supported version;
   - clean preferences and an existing/persisted configuration;
   - light and dark appearance;
   - single- and multi-display setups, including a full-screen Space;
   - Apple silicon and Intel, if Intel remains a supported release target.

Do not rely on XCUITest alone to verify that the launcher panel disappeared:
an ordered-out panel can retain a cached accessibility tree. Observe dismissal
manually or in a screen recording; the unit regression test separately verifies
that dismissal is requested before the workspace open begins.

## Stop-ship smoke test

Run this first on every environment:

1. Open Launcher with the global hotkey.
2. Search for a closed application and press Return.
3. Verify the Launcher disappears immediately when Return is pressed, without
   waiting for the target app to finish launching.
4. Repeat with:
   - an already-running app;
   - a slow cold-launching app;
   - the **Open** action from Command-K;
   - a mouse click on a result;
   - a target app on another Space or display.
5. Reopen Launcher after each attempt and verify it is focused, the query is
   cleared, the first result is selected, and no palette or stale state remains.

Any reproducible failure in this smoke test is severity 1 and triggers immediate
triage.

## Test charters

### 1. Window, focus, and launch lifecycle

- Toggle repeatedly with the hotkey, including rapid double presses.
- Dismiss with Escape, the hotkey, click-away, app switching, and after opening
  Settings or a palette.
- Launch closed, running, slow, hidden-system, and duplicate-name applications.
- Exercise Return, result clicks, and Command-K **Open**.
- Open and close Quick Look, dismiss Launcher while Quick Look is visible, and
  verify neither panel resurrects unexpectedly.
- Move the pointer between result rows and action palettes; verify hover cannot
  change the eventual target.
- Repeat on multiple displays, Spaces, and over a full-screen application.
- Watch for focus theft, visible flashes, stale query/state, lost keystrokes,
  duplicate launches, and a panel that remains visible behind the target.

### 2. Discovery, search, ranking, and reindexing

- Try exact, prefix, substring, fuzzy, mixed-case, Unicode, punctuation, and
  whitespace-only queries.
- Search applications, System Settings destinations, Launcher settings, and
  script commands with overlapping names.
- Check duplicate app names, hidden root-level app symlinks, renamed apps, and
  apps added or removed while Launcher is running.
- Reindex while typing rapidly and while opening/closing Launcher.
- Confirm selection stays valid as asynchronous results arrive.
- Check empty results, indexing progress, ranking stability, and responsiveness
  with a large application set.

### 3. File browser and external actions

- Enter `/`, `~`, `~/`, `./`, partial paths, spaces, escaped-looking names,
  Unicode, long paths, symlinks, and nonexistent paths.
- Navigate down with Return and back with Escape and the back button; verify the
  search/filter field resets at the right times.
- Exercise empty, huge, unreadable, iCloud, network, and disconnected folders.
- Confirm hidden-file behavior and directory/file ordering.
- For every applicable entry, test **Open**, **Open With**, **Show in Finder**,
  **Quick Look**, and **Copy Path**, using both shortcuts and the actions palette.
- Trigger macOS privacy prompts for Desktop, Documents, or Downloads and check
  that the app remains understandable and recoverable if the prompt is behind
  the panel or access is denied.
- In **Open With**, move the mouse over other rows before confirming and verify
  the originally captured file opens in the selected application.

### 4. Calculator

- Cover precedence, parentheses, unary minus, exponentiation, percentages,
  modulo, implicit multiplication, constants, and supported functions.
- Try division by zero, malformed expressions, deeply nested input, very long
  pasted input, locale-style commas, Unicode operators, and calculation-like
  app names.
- Verify formatting of large, negative, fractional, and floating-point results.
- Press Return to copy; verify the exact value and immediate dismissal.
- Reopen Launcher and make sure no calculator result or selection leaks into a
  normal search.

### 5. Script commands and process lifecycle

- Discover Bash, zsh-style, Python, executable, and non-executable scripts.
- Run normal and silent modes; verify dismissal, the run chip, and the ⌘P output pane match
  the mode.
- Exercise required/optional arguments with spaces, quotes, backslashes,
  Unicode, empty values, and Tab/Shift-Tab focus traversal.
- Test confirmation with confirm, cancel, and repeated Return.
- Stream stdout and stderr, produce no output, exceed the output cap, exit
  nonzero, use a missing interpreter, spawn a background child, and cancel a
  long-running process.
- Attempt a second script while one is running.
- Create, edit, externally modify, and delete commands. Verify metadata and body
  preservation, duplicate-title behavior, executable permissions, confirmation,
  and rescan timing.
- Close and reopen Launcher during each run phase; look for stale chips, output,
  focus, or callbacks from a previous run.

### 6. Settings, persistence, and menu bar behavior

- Change the global hotkey, restart Launcher, and verify persistence.
- Try a shortcut collision, modifier-only input, uncommon keys, and changing the
  shortcut repeatedly.
- Enable and disable **Start at Login**, including a simulated or real failure,
  then restart and verify displayed state matches system state.
- Change the scripts directory to valid, empty, missing, unreadable, iCloud, and
  external locations.
- Use Settings from the header, footer, Command-comma, and menu bar; verify Back,
  Done, Escape, and reindex behavior.
- Test **Show Launcher**, **Settings…**, and **Quit Launcher** from the menu bar
  while the panel is visible and hidden.

### 7. Accessibility, appearance, and resilience

- Complete core workflows keyboard-only; ensure focus is visible and never
  trapped.
- Spot-check VoiceOver names/order for search, results, footer actions, palettes,
  script arguments, output, and settings.
- Check light/dark appearance, increased contrast, reduced motion, and large
  text where applicable.
- Look for clipping with long app/file/script names and unusual hotkey labels.
- Rapidly alternate typing, arrows, palettes, Escape, and hotkey toggles.
- Monitor for hangs, crashes, sustained CPU, runaway memory, beeps without
  explanation, and main-thread stalls during indexing, directory listing, and
  script output.

## Reporting

File one report per behavior using:

```text
Title:
Severity: S0 / S1 / S2 / S3
Build commit:
Environment: Mac model, CPU, macOS, displays/Spaces, appearance
Charter:
Reproduction rate:
Preconditions:
Steps:
Expected:
Actual:
Evidence: screenshot/video/log/crash report
Regression:
Notes or suspected duplicate:
```

### Severity

- **S0 — Critical:** data loss, destructive action on the wrong target, security
  or privacy exposure.
- **S1 — Release blocker:** crash, hang, core launch/search flow unusable, wrong
  app/file/script opened or executed, Launcher will not dismiss or reopen.
- **S2 — Major:** important workflow is broken but a reasonable workaround
  exists; persistent focus, state, or performance failure.
- **S3 — Minor:** visual, copy, discoverability, or low-impact consistency issue.

The triager should deduplicate continuously, ask a second tester to reproduce
every S0/S1, and assign an owner before the session ends. Do not lower severity
only because a bug is intermittent; record the reproduction rate.

## Exit criteria

- Every charter has an owner and has been exercised on at least one environment.
- The stop-ship smoke test passes on the minimum and current supported macOS
  versions.
- Every S0/S1 has a second-person reproduction result, evidence, and an owner.
- No open S0 exists; open S1 findings have an explicit ship/no-ship decision.
- S2/S3 findings are deduplicated and prioritized.
- Each fixed S0/S1 and deterministic S2 gets a regression-test recommendation.
- The facilitator publishes a short summary: environments covered, charter
  coverage, counts by severity, release recommendation, owners, and retest date.
