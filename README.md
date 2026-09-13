# Launcher

A keyboard-first macOS application launcher written in Swift and SwiftUI. It discovers installed applications, searches useful System Settings destinations, opens results with Return, and exposes application actions with Command-K.

Typing a math expression (for example `5+5`, `(2+3)*4`, `sqrt(9)`, or `50% * 300`) shows a calculator card with the answer; press Return to copy it to the clipboard. Supported syntax: `+ - * / ^ %` (trailing `%` is a percentage, `%` between values is modulo), parentheses, implicit multiplication (`2(3+4)`, `2pi`), the constants `pi`, `tau`, and `e`, and functions such as `sqrt`, `abs`, `ln`, `log`, `sin`, `cos`, and `tan`.

Typing a path (`/`, `~`, `~/Desk`, `./notes`) switches to a file browser: directories and files are listed in sections with their octal permissions, and the last path component filters the listing. Return descends into a directory (the field clears and filters that folder; the back button or Escape walks back up) or opens a file. When browsing your home folder, a pinned iCloud Drive entry appears at the top. Command-K on an entry offers Open, Open With… (Command-Return), Show in Finder (Command-F), Quick Look (Command-Y), and Copy File Path (Shift-Command-C). The first time Launcher lists `~/Desktop`, `~/Documents`, or `~/Downloads`, macOS may show a one-time privacy prompt (it can appear behind the launcher panel).

Typing `>` as the first character creates a full-width native terminal powered by [libghostty-spm](https://github.com/stevemurr/libghostty-spm). The launcher search editor disappears and the terminal becomes the keyboard responder, so shell editing, colors, cursor movement, mouse input, scrollback, password prompts, and alternate-screen applications work with normal terminal semantics. Interactive tools such as `vim`, `top`, Claude Code, and Codex CLI can run directly without a line-oriented launcher input bridge. Press Command-K or use the **Launcher** button in the terminal footer to return to search without stopping the shell. Existing terminals appear under **Running Shells**; selecting one remounts that exact terminal with its process, working directory, scrollback, and screen state intact. Type `>` again when you want a new independent shell. Escape, Tab, arrows, Return, and Control-key sequences remain available to the shell or foreground application.

The default global shortcut is **Option-Space**. Open Launcher Settings with the gear button or Command-comma, click the shortcut recorder, and press any modified key combination to change it. The shortcut is persisted in `UserDefaults`.

Press **Command-P** in a terminal to pin it in a separate, draggable window. Pinned windows stay open when Launcher is invoked, dismissed, or loses focus. You can pin multiple terminals and resize each independently. Their Running Shells entries focus the existing window. Command-K opens Launcher while keeping the pinned terminal open; Command-P reattaches it. Closing a pinned window keeps its session in Running Shells, while the session's Close action ends it.

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
- `>`: create a new native terminal
- Command-1 / Command-2 / Command-3 in terminal mode: standard / larger / largest size (100%, 125%, and 150% width and height, scaled to fit the screen). Resizing animates, and the chosen size is remembered across terminal openings and app restarts. The footer also cycles the sizes.
- Command-P in terminal mode: detach into a draggable pinned window, or reattach a pinned terminal
- Return on a Running Shell: resume that exact terminal
- Escape / Tab / arrows / Return / Control keys in terminal mode: sent directly to the terminal
- Command-K in terminal mode: return to Launcher search without stopping the shell
- Command-K in search mode: show actions
- Command-comma: open Launcher Settings
- Escape: close actions, go up a directory while browsing files, return from settings, or dismiss Launcher
