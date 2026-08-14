# Launcher

A keyboard-first macOS application launcher written in Swift and SwiftUI. It discovers installed applications, searches useful System Settings destinations, opens results with Return, and exposes application actions with Command-K.

Typing a math expression (for example `5+5`, `(2+3)*4`, `sqrt(9)`, or `50% * 300`) shows a calculator card with the answer; press Return to copy it to the clipboard. Supported syntax: `+ - * / ^ %` (trailing `%` is a percentage, `%` between values is modulo), parentheses, implicit multiplication (`2(3+4)`, `2pi`), the constants `pi`, `tau`, and `e`, and functions such as `sqrt`, `abs`, `ln`, `log`, `sin`, `cos`, and `tan`.

Typing a path (`/`, `~`, `~/Desk`, `./notes`) switches to a file browser: directories and files are listed in sections with their octal permissions, and the last path component filters the listing. Return descends into a directory (the field clears and filters that folder; the back button or Escape walks back up) or opens a file. When browsing your home folder, a pinned iCloud Drive entry appears at the top. Command-K on an entry offers Open, Open With… (Command-Return), Show in Finder (Command-F), Quick Look (Command-Y), and Copy File Path (Shift-Command-C). The first time Launcher lists `~/Desktop`, `~/Documents`, or `~/Downloads`, macOS may show a one-time privacy prompt (it can appear behind the launcher panel).

Typing `>` as the first character switches to a full-width shell console; the trigger disappears so the field contains only your command. Press Return to run a command and stream its output underneath. Each console is a persistent shell session, so `cd`, exported variables, and later commands retain that session's state. Foreground tools can read line-oriented input from the same field, which changes to **Send Input** while they run. Tab opens command and path completions, Up and Down recall command history, Control-C interrupts the foreground command without closing its shell, and Escape returns to normal search without stopping the session. Persistent sessions appear in a pinned **Running Shells** section and can be resumed, while new shells can run alongside them. Full-screen terminal interfaces such as `vim` and `top` are not rendered as terminal screens; the console intentionally presents a readable transcript.

The default global shortcut is **Option-Space**. Open Launcher Settings with the gear button or Command-comma, click the shortcut recorder, and press any modified key combination to change it. The shortcut is persisted in `UserDefaults`.

Launcher follows the current macOS light or dark appearance automatically.

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
- Return: open the selected result, or enter the selected directory
- `>`: enter Shell mode; Return runs the command
- Tab in Shell mode: show or cycle command and path completions
- Up / Down in Shell mode: browse in-memory command history
- Control-C in Shell mode: interrupt the foreground command
- Command-K: show actions
- Command-comma: open Launcher Settings
- Escape: close actions, go up a directory while browsing files, return from settings, or dismiss Launcher
