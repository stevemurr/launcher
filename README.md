# Launcher

A keyboard-first macOS application launcher written in Swift and SwiftUI. It discovers installed applications, searches useful System Settings destinations, opens results with Return, and exposes application actions with Command-K.

The default global shortcut is **Option-Space**. Open Launcher Settings with the gear button or Command-comma, click the shortcut recorder, and press any modified key combination to change it. The shortcut is persisted in `UserDefaults`.

## Build and run

Requirements: macOS 14 or newer, Xcode 27, Swift 6, and [XcodeGen](https://github.com/yonaskolb/XcodeGen).

```bash
make run
```

You can also generate and open the Xcode project:

```bash
make project
open Launcher.xcodeproj
```

## Tests

Unit tests are safe to run locally:

```bash
make test
```

The XCUITest target is intentionally isolated in the `LauncherUITests` scheme. Compile-check it locally without running it:

```bash
make compile-ui-tests
```

Run XCUITests only in the ephemeral Tart VM:

```bash
make ui-test
```

The VM runner copies the resulting `.xcresult` bundle into `test-results/`.

## Keyboard controls

- Up / Down: move selection
- Return: open the selected result
- Command-K: show actions
- Command-comma: open Launcher Settings
- Escape: close actions, return from settings, or dismiss Launcher
