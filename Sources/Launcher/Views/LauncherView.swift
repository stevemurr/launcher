import AppKit
import SwiftUI

struct LauncherRootView: View {
    @ObservedObject var model: LauncherModel
    @Environment(\.accessibilityReduceMotion) private var reduceMotion

    private var panelWidth: CGFloat {
        model.isPanelExpanded ? LauncherStyle.expandedPanelWidth : LauncherStyle.panelWidth
    }

    private var drawerAnimation: Animation? {
        reduceMotion ? nil : .easeInOut(duration: LauncherStyle.drawerAnimationDuration)
    }

    private var paletteAnimation: Animation? {
        reduceMotion ? nil : .easeOut(duration: 0.12)
    }

    private func paletteTransition(anchor: UnitPoint) -> AnyTransition {
        reduceMotion ? .identity : .opacity.combined(with: .scale(scale: 0.98, anchor: anchor))
    }

    var body: some View {
        ZStack(alignment: .bottomTrailing) {
            VisualEffectView(material: .popover, blendingMode: .behindWindow)
            Color.launcherSurface.opacity(0.84)

            Group {
                switch model.screen {
                case .search:
                    LauncherSearchView(model: model)
                case .settings:
                    LauncherSettingsView(model: model, settings: model.settings)
                case .createScript:
                    CreateScriptView(model: model)
                }
            }

            if model.screen == .search, model.isActionsPresented, model.pendingRun == nil, model.pendingDeletion == nil,
               !model.isOpenWithPresented {
                ActionsPalette(model: model)
                    .padding(.trailing, 8)
                    .padding(.bottom, 45)
                    .transition(paletteTransition(anchor: .bottomTrailing))
            }

            if model.screen == .search, model.isOpenWithPresented {
                OpenWithPalette(model: model)
                    .padding(.trailing, 8)
                    .padding(.bottom, 45)
                    .transition(paletteTransition(anchor: .bottomTrailing))
            }

            if model.screen == .search, model.pendingRun != nil {
                ConfirmRunPalette(model: model)
                    .padding(.trailing, 8)
                    .padding(.bottom, 45)
                    .transition(paletteTransition(anchor: .bottomTrailing))
            }

            if model.screen == .search, model.pendingDeletion != nil {
                ConfirmDeletePalette(model: model)
                    .padding(.trailing, 8)
                    .padding(.bottom, 45)
                    .transition(paletteTransition(anchor: .bottomTrailing))
            }

            if model.screen == .search, model.isRunPalettePresented {
                RunPalette(model: model)
                    .padding(.leading, 8)
                    .padding(.bottom, 45)
                    .frame(maxWidth: .infinity, maxHeight: .infinity, alignment: .bottomLeading)
                    .transition(paletteTransition(anchor: .bottomLeading))
            }
        }
        .frame(width: panelWidth, height: LauncherStyle.panelHeight)
        .clipShape(RoundedRectangle(cornerRadius: LauncherStyle.panelCornerRadius, style: .continuous))
        .overlay {
            RoundedRectangle(cornerRadius: LauncherStyle.panelCornerRadius, style: .continuous)
                .stroke(Color.launcherSeparator.opacity(0.82), lineWidth: 1)
        }
        .animation(paletteAnimation, value: model.isActionsPresented)
        .animation(paletteAnimation, value: model.isOpenWithPresented)
        .animation(paletteAnimation, value: model.isRunPalettePresented)
        .animation(paletteAnimation, value: model.pendingRun)
        .animation(paletteAnimation, value: model.pendingDeletion)
        .animation(drawerAnimation, value: model.panelPresentation)
    }
}

private struct LauncherSearchView: View {
    @ObservedObject var model: LauncherModel
    @Environment(\.accessibilityReduceMotion) private var reduceMotion

    /// The results region shrinks so the pane costs less window than its width.
    private var resultsRegionWidth: CGFloat {
        model.isOutputPanePresented ? LauncherStyle.drawerResultsWidth : LauncherStyle.panelWidth
    }

    private var outputPaneTransition: AnyTransition {
        reduceMotion ? .opacity : .move(edge: .trailing).combined(with: .opacity)
    }

    var body: some View {
        VStack(spacing: 0) {
            // Header and footer span the whole window so the overlay palettes
            // stay attached to the controls that trigger them.
            searchHeader
                .frame(height: LauncherStyle.headerHeight)

            Divider().opacity(0.65)

            Group {
                if model.isShellMode {
                    ShellConsoleView(model: model)
                        .frame(width: LauncherStyle.expandedPanelWidth)
                        .frame(maxHeight: .infinity)
                } else {
                    HStack(spacing: 0) {
                        Group {
                            if model.isFileBrowsing {
                                FileBrowserList(model: model)
                            } else {
                                resultsList
                            }
                        }
                        .frame(width: resultsRegionWidth)
                        .frame(maxHeight: .infinity)

                        if model.isOutputPanePresented {
                            ScriptOutputPane(model: model)
                                .frame(width: LauncherStyle.outputPaneWidth)
                                .frame(maxHeight: .infinity)
                                .overlay(alignment: .leading) {
                                    Rectangle()
                                        .fill(Color.launcherSeparator.opacity(0.65))
                                        .frame(width: 1)
                                }
                                .transition(outputPaneTransition)
                        }
                    }
                }
            }
            .frame(maxHeight: .infinity)

            Divider().opacity(0.65)

            Group {
                if model.isShellMode {
                    shellFooter
                } else {
                    footer
                }
            }
                .frame(height: LauncherStyle.footerHeight)
        }
        .overlay(alignment: .topLeading) {
            if model.isShellMode, !model.shellCompletions.isEmpty {
                ShellCompletionPalette(
                    candidates: model.shellCompletions,
                    selectedIndex: model.shellCompletionSelectionIndex,
                    onAccept: { model.acceptShellCompletion(at: $0) }
                )
                .padding(.leading, 14)
                .padding(.top, LauncherStyle.headerHeight + 5)
                .transition(.opacity.combined(with: .move(edge: .top)))
                .zIndex(10)
            }
        }
        .animation(reduceMotion ? nil : .easeOut(duration: 0.1), value: model.shellCompletions)
    }

    private var searchHeader: some View {
        HStack(spacing: 12) {
            if model.browseSession != nil {
                Button {
                    model.ascendOrExitBrowse()
                } label: {
                    Image(systemName: "arrow.left")
                        .font(.system(size: 14, weight: .bold))
                        .foregroundStyle(Color.secondary)
                        .frame(width: 28, height: 28)
                        .background(Color.primary.opacity(0.07), in: RoundedRectangle(cornerRadius: 7))
                }
                .buttonStyle(.plain)
                .help("Back (Esc)")
                .accessibilityIdentifier("header.back")
            }

            LauncherSearchField(
                text: $model.query,
                focusToken: model.focusToken,
                isFocusTarget: model.focusTarget == .search,
                isSecureEntry: model.isShellInputSecure,
                placeholder: model.searchFieldPlaceholder,
                accessibilityLabel: model.searchFieldAccessibilityLabel,
                requestedCaretUTF16: model.shellCompletionCaretUTF16,
                caretRequestToken: model.shellCompletionCaretRequestToken,
                onFocus: { model.noteFocus(.search) },
                onSelectionChange: {
                    model.noteShellSelectionChanged(
                        locationUTF16: $0.location,
                        lengthUTF16: $0.length
                    )
                },
                onCommand: handle
            )
            .frame(height: 32)

            if model.isShellMode {
                HStack(spacing: 6) {
                    Image(systemName: "apple.terminal")
                        .font(.system(size: 13, weight: .semibold))
                    Text("Shell")
                        .font(.system(size: 13, weight: .semibold))
                }
                .foregroundStyle(Color.secondary)
                .padding(.horizontal, 9)
                .padding(.vertical, 5)
                .background(Color.primary.opacity(0.07), in: Capsule())
                .accessibilityIdentifier("header.shellMode")
            } else if let script = model.selectedScript, !script.arguments.isEmpty {
                HStack(spacing: 6) {
                    ForEach(Array(script.arguments.enumerated()), id: \.offset) { index, argument in
                        ArgumentTokenBox(model: model, argument: argument, index: index, onCommand: handle)
                    }
                    if model.focusTarget == .search {
                        HStack(spacing: 5) {
                            Text("Tab")
                                .font(.system(size: 13, weight: .medium))
                                .foregroundStyle(Color.secondary.opacity(0.72))
                            KeyCap("⇥")
                        }
                        .accessibilityIdentifier("header.tabHint")
                    }
                }
            } else {
                HStack(spacing: 5) {
                    Text("Hotkey")
                        .font(.system(size: 13, weight: .medium))
                        .foregroundStyle(Color.secondary.opacity(0.72))
                    KeyCap(model.settings.hotKey.displayString)
                }
            }

            Button {
                model.showSettings()
            } label: {
                Image(systemName: "gearshape")
                    .font(.system(size: 14, weight: .semibold))
                    .foregroundStyle(Color.secondary)
                    .frame(width: 28, height: 28)
                    .background(Color.primary.opacity(0.07), in: RoundedRectangle(cornerRadius: 7))
            }
            .buttonStyle(.plain)
            .help("Launcher Settings (⌘,)")
            .accessibilityIdentifier("header.settings")
        }
        .padding(.leading, 16)
        .padding(.trailing, 14)
    }

    private var resultsList: some View {
        let runningShellCount = min(model.runningShellResultCount, model.results.count)
        let calculatorIndex = model.calculation == nil ? nil : runningShellCount
        let resultsStartIndex = runningShellCount + (calculatorIndex == nil ? 0 : 1)
        let showsResultsSection = calculatorIndex == nil || resultsStartIndex < model.results.count
        let isLoadingResults = model.isLoading || model.isFileListingLoading

        return VStack(spacing: 0) {
            ScrollViewReader { proxy in
                ScrollView {
                    LazyVStack(spacing: 0) {
                        if runningShellCount > 0 {
                            sectionHeader("Running Shells", showsProgress: false)

                            ForEach(0..<runningShellCount, id: \.self) { resultIndex in
                                resultRow(at: resultIndex)
                            }
                        }

                        if let calculation = model.calculation, let calculatorIndex,
                           model.results.indices.contains(calculatorIndex) {
                            sectionHeader("Calculator", showsProgress: false)

                            CalculatorCard(
                                calculation: calculation,
                                isSelected: model.selectedIndex == calculatorIndex,
                                onSelect: { model.select(index: calculatorIndex) },
                                onOpen: {
                                    model.select(index: calculatorIndex)
                                    model.activateSelected()
                                }
                            )
                            .id(model.results[calculatorIndex].id)
                        }

                        if showsResultsSection {
                            sectionHeader("Results", showsProgress: isLoadingResults)
                        }

                        if resultsStartIndex < model.results.count {
                            ForEach(resultsStartIndex..<model.results.count, id: \.self) { resultIndex in
                                resultRow(at: resultIndex)
                            }
                        } else if showsResultsSection, !isLoadingResults {
                            HStack(spacing: 8) {
                                Image(systemName: "magnifyingglass")
                                Text("No matching applications or settings")
                            }
                            .font(.system(size: 14))
                            .foregroundStyle(Color.secondary)
                            .frame(maxWidth: .infinity)
                            .frame(height: 48)
                        }
                    }
                }
                .onChange(of: model.selectedIndex) { _, newIndex in
                    if model.results.indices.contains(newIndex) {
                        proxy.scrollTo(model.results[newIndex].id)
                    }
                }
            }

            HStack(spacing: 8) {
                Image(systemName: isLoadingResults ? "arrow.triangle.2.circlepath" : "sparkle.magnifyingglass")
                    .font(.system(size: 13, weight: .semibold))
                    .foregroundStyle(Color.secondary.opacity(0.72))
                Text(
                    model.isFileListingLoading
                        ? "Loading folder…"
                        : model.isLoading
                            ? "Indexing installed applications…"
                            : "Search apps, settings, and script commands, or type a calculation like 5+5"
                )
                    .font(.system(size: 13, weight: .medium))
                    .foregroundStyle(Color.secondary)
                    // The results region narrows to 526 pt with the pane open.
                    .lineLimit(1)
                Spacer()
            }
            .padding(.horizontal, 16)
            .frame(height: 44)
        }
    }

    private func resultRow(at index: Int) -> some View {
        ResultRow(
            item: model.results[index],
            isSelected: index == model.selectedIndex,
            onSelect: { model.select(index: index) },
            onOpen: {
                model.select(index: index)
                model.activateSelected()
            }
        )
        .frame(height: 48)
        .id(model.results[index].id)
    }

    private func sectionHeader(_ title: String, showsProgress: Bool) -> some View {
        ListSectionHeader(title: title, showsProgress: showsProgress)
    }

    private var footer: some View {
        HStack(spacing: 10) {
            Button {
                model.showSettings()
            } label: {
                Image(systemName: "command.square.fill")
                    .font(.system(size: 16, weight: .semibold))
                    .symbolRenderingMode(.hierarchical)
                    .foregroundStyle(Color.secondary.opacity(0.74))
                    .frame(width: 26, height: 26)
            }
            .buttonStyle(.plain)
            .help("Launcher Settings")
            .accessibilityIdentifier("footer.settings")

            // The chip now lives as long as its run, so it sits beside the
            // settings button rather than replacing it.
            if model.isRunChipVisible {
                RunChip(model: model)
            }

            Spacer()

            // Always rendered (disabled when there is nothing to show) so the
            // footer never reflows when a run starts.
            Button {
                model.toggleOutputPane()
            } label: {
                HStack(spacing: 5) {
                    Text("Output")
                        .font(.system(size: 13, weight: .semibold))
                        .foregroundStyle(model.isOutputPanePresented ? Color.accentColor : Color.secondary)
                    KeyCap("⌘")
                    KeyCap("P")
                }
                .foregroundStyle(Color.secondary)
            }
            .buttonStyle(.plain)
            .help("\(model.isOutputPanePresented ? "Hide" : "Show") Script Output (⌘P)")
            .accessibilityIdentifier("footer.output")

            Rectangle()
                .fill(Color.launcherSeparator)
                .frame(width: 1, height: 14)

            if let item = model.selectedItem {
                Text(primaryActionTitle(for: item))
                    .font(.system(size: 13, weight: .semibold))
                    .foregroundStyle(Color.primary.opacity(0.92))
                KeyCap("↩")
            }

            Rectangle()
                .fill(Color.launcherSeparator)
                .frame(width: 1, height: 14)

            Button {
                model.toggleActions()
            } label: {
                HStack(spacing: 7) {
                    Text("Actions")
                        .font(.system(size: 13, weight: .semibold))
                    KeyCap("⌘")
                    KeyCap("K")
                }
                .foregroundStyle(Color.secondary)
            }
            .buttonStyle(.plain)
            .disabled(model.selectedItem == nil)
            .accessibilityIdentifier("footer.actions")
        }
        .padding(.horizontal, 12)
        .frame(maxWidth: .infinity, maxHeight: .infinity)
        .background(Color.launcherControlSurface.opacity(0.20))
    }

    private var shellFooter: some View {
        HStack(spacing: 10) {
            Button {
                model.showSettings()
            } label: {
                Image(systemName: "command.square.fill")
                    .font(.system(size: 16, weight: .semibold))
                    .symbolRenderingMode(.hierarchical)
                    .foregroundStyle(Color.secondary.opacity(0.74))
                    .frame(width: 26, height: 26)
            }
            .buttonStyle(.plain)
            .help("Launcher Settings")
            .accessibilityIdentifier("footer.settings")

            if model.canStopShellSession {
                Button {
                    model.cancelCurrentRun()
                } label: {
                    HStack(spacing: 6) {
                        Image(systemName: "stop.fill")
                            .font(.system(size: 11, weight: .bold))
                        Text("Stop")
                            .font(.system(size: 13, weight: .semibold))
                        KeyCap("⌃C")
                    }
                    .foregroundStyle(Color.red)
                }
                .buttonStyle(.plain)
                .help("Interrupt Running Command (Control-C)")
                .accessibilityIdentifier("shell.stop")
            }

            if model.canCloseShellSession {
                Button {
                    model.closeSelectedShellSession()
                } label: {
                    HStack(spacing: 6) {
                        Image(systemName: "xmark.circle")
                            .font(.system(size: 12, weight: .semibold))
                        Text("Close Shell")
                            .font(.system(size: 13, weight: .semibold))
                    }
                    .foregroundStyle(Color.secondary)
                }
                .buttonStyle(.plain)
                .help("Close this persistent shell session")
                .accessibilityIdentifier("shell.close")
                .accessibilityLabel("Close \(model.shellSessionDisplayName)")
            }

            Spacer()

            if let inputError = model.shellInputError {
                Text(inputError)
                    .font(.system(size: 12, weight: .semibold))
                    .foregroundStyle(Color.red)
                    .lineLimit(1)
                    .help(inputError)
                    .accessibilityIdentifier("shell.input.error")
                    .accessibilityLabel("Shell input error: \(inputError)")
            } else {
                Text(shellFooterStatus)
                    .font(.system(size: 12, weight: .semibold))
                    .foregroundStyle(Color.secondary)
                    .accessibilityIdentifier("shell.footer.status")
                    .accessibilityHidden(true)
            }

            Rectangle()
                .fill(Color.launcherSeparator)
                .frame(width: 1, height: 14)

            Button {
                model.handleSubmit()
            } label: {
                HStack(spacing: 7) {
                    Text(ShellInputPresentation.primaryActionTitle(for: model.shellInputMode))
                        .font(.system(size: 13, weight: .semibold))
                    KeyCap("↩")
                }
                .foregroundStyle(Color.primary.opacity(0.92))
            }
            .buttonStyle(.plain)
            .accessibilityIdentifier("shell.run")
            .accessibilityLabel(ShellInputPresentation.primaryActionTitle(for: model.shellInputMode))
        }
        .padding(.horizontal, 12)
        .frame(maxWidth: .infinity, maxHeight: .infinity)
        .background(Color.launcherControlSurface.opacity(0.20))
    }

    private var shellFooterStatus: String {
        if let sessionPhase = model.shellRun?.sessionPhase {
            switch sessionPhase {
            case .starting: return "Starting…"
            case .ready: return "Ready"
            case .foreground: return "Running…"
            case .closing: return "Closing…"
            }
        }
        return switch model.displayedRunPhase {
        case .running: "Running…"
        case .finished(.success): "Exit 0"
        case let .finished(.failure(exitCode)): "Exit \(exitCode)"
        case .finished(.cancelled): "Cancelled"
        case .finished(.failedToStart): "Failed to start"
        case nil: "Ready"
        }
    }

    private func handle(_ command: LauncherKeyCommand) {
        if let completionAction = ShellCompletionKeyboardAction.resolve(
            command,
            isShellMode: model.isShellMode,
            hasCandidates: !model.shellCompletions.isEmpty
        ) {
            switch completionAction {
            case let .request(backward, cursorUTF16):
                model.requestShellCompletion(backward: backward, cursorUTF16: cursorUTF16)
            case let .move(offset): model.moveShellCompletion(by: offset)
            case .accept: model.acceptShellCompletion()
            }
            return
        }

        switch command {
        case .moveDown: model.moveSelection(by: 1)
        case .moveUp: model.moveSelection(by: -1)
        case .submit: model.handleSubmit()
        case .escape: model.handleEscape()
        case .toggleActions: model.toggleActions()
        case .settings: model.showSettings()
        case .focusNext: model.handleFocusNext()
        case .focusPrevious: model.handleFocusPrevious()
        case let .completeShell(backward, _):
            if backward { model.handleFocusPrevious() } else { model.handleFocusNext() }
        case .toggleRunPalette: model.toggleRunPalette()
        case .toggleOutputPane: model.toggleOutputPane()
        case .editScript: model.beginEditingSelectedScript()
        case .deleteScript: model.requestDeletingSelectedScript()
        case .openWith:
            if model.isOpenWithPresented {
                model.confirmOpenWith()
            } else if model.availableActions.contains(.openWith) {
                model.perform(.openWith)
            } else {
                model.handleSubmit()
            }
        case .quickLook:
            if model.availableActions.contains(.quickLook) { model.perform(.quickLook) }
        case .showInFinder:
            if model.availableActions.contains(.showInFinder) { model.perform(.showInFinder) }
        case .copyPath:
            if model.availableActions.contains(.copyPath) { model.perform(.copyPath) }
        case .copyScriptContents:
            if model.availableActions.contains(.copyScriptContents) { model.perform(.copyScriptContents) }
        case .interruptRun:
            model.cancelCurrentRun()
        }
    }

    private func primaryActionTitle(for item: LauncherItem) -> String {
        switch item.kind {
        case .application: "Open Application"
        case .systemSetting: "Open System Settings"
        case .launcherSetting: item.destination == .createScript ? "Open Command" : "Open Launcher Settings"
        case .calculator: "Copy Answer"
        case .scriptCommand: "Run Script"
        case .runningShell: "Resume Shell"
        case .file: "Open File"
        case .directory: item.id == "file.icloud" ? "Open iCloud" : "Open Directory"
        }
    }
}

enum ShellInputPresentation {
    static func primaryActionTitle(for inputMode: ShellInputMode) -> String {
        switch inputMode {
        case .idle: "Run Command"
        case .foreground: "Send Input"
        }
    }
}

enum ShellCompletionKeyboardAction: Equatable {
    case request(backward: Bool, cursorUTF16: Int?)
    case move(offset: Int)
    case accept

    static func resolve(
        _ command: LauncherKeyCommand,
        isShellMode: Bool,
        hasCandidates: Bool
    ) -> ShellCompletionKeyboardAction? {
        guard isShellMode else { return nil }
        switch command {
        case let .completeShell(backward, cursorUTF16):
            return hasCandidates
                ? .move(offset: backward ? -1 : 1)
                : .request(backward: backward, cursorUTF16: cursorUTF16)
        case .focusNext:
            return hasCandidates ? .move(offset: 1) : .request(backward: false, cursorUTF16: nil)
        case .focusPrevious:
            return hasCandidates ? .move(offset: -1) : .request(backward: true, cursorUTF16: nil)
        case .moveDown where hasCandidates:
            return .move(offset: 1)
        case .moveUp where hasCandidates:
            return .move(offset: -1)
        case .submit where hasCandidates:
            return .accept
        default:
            return nil
        }
    }
}

struct ShellCompletionPalette: View {
    let candidates: [String]
    let selectedIndex: Int
    let onAccept: (Int) -> Void

    var body: some View {
        ScrollViewReader { proxy in
            ScrollView {
                LazyVStack(spacing: 2) {
                    ForEach(Array(candidates.enumerated()), id: \.offset) { index, candidate in
                        Button {
                            onAccept(index)
                        } label: {
                            HStack(spacing: 9) {
                                Image(systemName: "chevron.right")
                                    .font(.system(size: 9, weight: .bold))
                                    .foregroundStyle(index == selectedIndex ? Color.accentColor : Color.secondary)
                                    .frame(width: 12)
                                Text(candidate)
                                    .font(.system(size: 12, weight: .medium, design: .monospaced))
                                    .foregroundStyle(Color.primary.opacity(0.92))
                                    .lineLimit(1)
                                Spacer(minLength: 8)
                                if index == selectedIndex {
                                    KeyCap("↩")
                                }
                            }
                            .padding(.horizontal, 10)
                            .frame(height: 30)
                            .contentShape(Rectangle())
                            .background(
                                index == selectedIndex ? Color.accentColor.opacity(0.13) : Color.clear,
                                in: RoundedRectangle(cornerRadius: 7, style: .continuous)
                            )
                        }
                        .buttonStyle(.plain)
                        .id(index)
                        .accessibilityIdentifier("shell.completion.\(index)")
                        .accessibilityLabel(candidate)
                        .accessibilityValue(index == selectedIndex ? "Selected" : "")
                    }
                }
                .padding(5)
            }
            .frame(width: 560, height: min(CGFloat(candidates.count * 32 + 10), 202))
            .onChange(of: selectedIndex) { _, newIndex in
                guard candidates.indices.contains(newIndex) else { return }
                proxy.scrollTo(newIndex, anchor: .center)
            }
        }
        .background {
            VisualEffectView(material: .popover, blendingMode: .withinWindow)
                .overlay(Color.launcherSurface.opacity(0.72))
        }
        .clipShape(RoundedRectangle(cornerRadius: 10, style: .continuous))
        .overlay {
            RoundedRectangle(cornerRadius: 10, style: .continuous)
                .stroke(Color.launcherSeparator.opacity(0.92), lineWidth: 1)
        }
        .shadow(color: .black.opacity(0.24), radius: 14, y: 6)
        .accessibilityElement(children: .contain)
        .accessibilityIdentifier("shell.completions")
        .accessibilityLabel("Shell completions")
    }
}

private struct CalculatorCard: View {
    let calculation: Calculation
    let isSelected: Bool
    let onSelect: () -> Void
    let onOpen: () -> Void

    var body: some View {
        Button(action: onOpen) {
            HStack(spacing: 0) {
                column(value: calculation.expression, badge: calculation.operationLabel)
                verticalDivider
                Image(systemName: "arrow.right")
                    .font(.system(size: 16, weight: .semibold))
                    .foregroundStyle(Color.secondary)
                    .frame(width: 44)
                verticalDivider
                column(value: calculation.formattedResult, badge: calculation.resultLabel)
            }
            .frame(maxWidth: .infinity)
            .frame(height: 96)
            .background {
                RoundedRectangle(cornerRadius: 12, style: .continuous)
                    .fill(Color.primary.opacity(isSelected ? 0.10 : 0.05))
            }
            .contentShape(Rectangle())
        }
        .buttonStyle(.plain)
        .padding(.horizontal, 8)
        .onHover { hovering in
            if hovering { onSelect() }
        }
        .accessibilityIdentifier("calculator.card")
        .accessibilityLabel("\(calculation.expression) equals \(calculation.formattedResult)")
    }

    private var verticalDivider: some View {
        Rectangle()
            .fill(Color.launcherSeparator.opacity(0.7))
            .frame(width: 1)
            .padding(.vertical, 12)
    }

    private func column(value: String, badge: String?) -> some View {
        VStack(spacing: 9) {
            Text(value)
                .font(.system(size: 25, weight: .bold))
                .foregroundStyle(Color.primary)
                .lineLimit(1)
                .minimumScaleFactor(0.45)
            if let badge {
                Text(badge)
                    .font(.system(size: 11, weight: .medium))
                    .foregroundStyle(Color.secondary)
                    .lineLimit(1)
                    .padding(.horizontal, 7)
                    .padding(.vertical, 3)
                    .background(Color.primary.opacity(0.08), in: RoundedRectangle(cornerRadius: 5, style: .continuous))
            }
        }
        .padding(.horizontal, 14)
        .frame(maxWidth: .infinity)
    }
}

private struct ResultRow: View {
    let item: LauncherItem
    let isSelected: Bool
    let onSelect: () -> Void
    let onOpen: () -> Void

    var body: some View {
        Button(action: onOpen) {
            HStack(spacing: 11) {
                ItemIcon(item: item)

                HStack(spacing: 10) {
                    Text(item.title)
                        .font(.system(size: 16, weight: .medium))
                        .foregroundStyle(Color.primary)
                        .lineLimit(1)

                    if let subtitle = item.subtitle {
                        Text(subtitle)
                            .font(.system(size: 15))
                            .foregroundStyle(Color.secondary)
                            .lineLimit(1)
                    }
                }

                Spacer(minLength: 16)

                Text(item.kind.rawValue)
                    .font(.system(size: 15))
                    .foregroundStyle(Color.secondary)
                    .lineLimit(1)
            }
            .padding(.horizontal, 9)
            .frame(maxWidth: .infinity, maxHeight: .infinity)
            .background {
                RoundedRectangle(cornerRadius: 12, style: .continuous)
                    .fill(isSelected ? Color.primary.opacity(0.10) : Color.clear)
            }
            .contentShape(Rectangle())
        }
        .buttonStyle(.plain)
        .padding(.horizontal, 8)
        .onHover { hovering in
            if hovering { onSelect() }
        }
        .accessibilityIdentifier(LauncherResultPresentation.accessibilityIdentifier(for: item))
        .accessibilityLabel(LauncherResultPresentation.accessibilityLabel(for: item))
    }
}

enum LauncherResultPresentation {
    static func accessibilityIdentifier(for item: LauncherItem) -> String {
        "result.\(item.title)"
    }

    static func accessibilityLabel(for item: LauncherItem) -> String {
        guard item.kind == .runningShell else {
            return "\(item.title), \(item.kind.rawValue)"
        }
        return [item.title, item.subtitle, item.kind.rawValue]
            .compactMap { $0 }
            .joined(separator: ", ")
    }
}

private struct ItemIcon: View {
    let item: LauncherItem

    var body: some View {
        Group {
            if item.kind == .application, let url = item.fileURL {
                Image(nsImage: NSWorkspace.shared.icon(forFile: url.path))
                    .resizable()
                    .interpolation(.high)
            } else {
                ZStack {
                    RoundedRectangle(cornerRadius: 6, style: .continuous)
                        .fill(iconBackground)
                    Image(systemName: item.kind.symbolName)
                        .font(.system(size: 13, weight: .bold))
                        .foregroundStyle(Color.white)
                }
            }
        }
        .frame(width: 24, height: 24)
    }

    private var iconBackground: LinearGradient {
        if item.kind == .systemSetting {
            return LinearGradient(colors: [.blue.opacity(0.72), .blue], startPoint: .top, endPoint: .bottom)
        }
        if item.kind == .scriptCommand {
            return LinearGradient(colors: [.orange.opacity(0.75), .orange], startPoint: .top, endPoint: .bottom)
        }
        return LinearGradient(colors: [.gray, .black.opacity(0.82)], startPoint: .top, endPoint: .bottom)
    }
}

private struct ActionsPalette: View {
    @ObservedObject var model: LauncherModel

    var body: some View {
        VStack(spacing: 0) {
            HStack {
                Text(model.actionsTarget?.title ?? "Actions")
                    .font(.system(size: 13, weight: .semibold))
                    .foregroundStyle(Color.secondary)
                    .lineLimit(1)
                Spacer()
            }
            .padding(.horizontal, 12)
            .frame(height: 40)

            ForEach(Array(model.availableActions.enumerated()), id: \.element.id) { index, action in
                Button {
                    model.perform(action)
                } label: {
                    HStack(spacing: 10) {
                        Image(systemName: action.symbolName)
                            .font(.system(size: 15, weight: .semibold))
                            .frame(width: 20)
                        Text(displayTitle(for: action))
                            .font(.system(size: 16, weight: .medium))
                        Spacer()
                        if !action.shortcut.isEmpty {
                            KeyCap(action.shortcut)
                        }
                    }
                    .foregroundStyle(Color.primary)
                    .padding(.horizontal, 10)
                    .frame(height: 40)
                    .background {
                        RoundedRectangle(cornerRadius: 9, style: .continuous)
                            .fill(index == model.actionsSelectionIndex ? Color.primary.opacity(0.085) : Color.clear)
                    }
                    .contentShape(Rectangle())
                }
                .buttonStyle(.plain)
                .padding(.horizontal, 7)
                .onHover { hovering in
                    if hovering { model.actionsSelectionIndex = index }
                }
                .accessibilityIdentifier("action.\(action.rawValue)")
            }

            Spacer(minLength: 6)
        }
        .frame(width: 360, height: CGFloat(52 + model.availableActions.count * 40))
        .background {
            VisualEffectView(material: .popover, blendingMode: .withinWindow)
                .overlay(Color.launcherSurface.opacity(0.56))
        }
        .clipShape(RoundedRectangle(cornerRadius: 14, style: .continuous))
        .overlay {
            RoundedRectangle(cornerRadius: 14, style: .continuous)
                .stroke(Color.launcherSeparator.opacity(0.9), lineWidth: 1)
        }
        .shadow(color: .black.opacity(0.24), radius: 20, y: 8)
    }

    private func displayTitle(for action: LauncherAction) -> String {
        guard action == .open else { return action.title }
        switch model.actionsTarget?.kind {
        case .application: return "Open Application"
        case .systemSetting: return "Open System Settings"
        case .launcherSetting:
            return model.actionsTarget?.destination == .createScript ? "Open Command" : "Open Launcher Settings"
        case .calculator: return "Copy Answer"
        case .scriptCommand: return "Run Script"
        case .runningShell: return "Resume Shell"
        case .file: return "Open File"
        case .directory: return model.actionsTarget?.id == "file.icloud" ? "Open iCloud" : "Open Directory"
        case nil: return action.title
        }
    }
}

struct LauncherSettingsView: View {
    @ObservedObject var model: LauncherModel
    @ObservedObject var settings: LauncherSettings

    var body: some View {
        VStack(spacing: 0) {
            HStack(spacing: 11) {
                Button {
                    model.showSearch()
                } label: {
                    Image(systemName: "chevron.left")
                        .font(.system(size: 14, weight: .bold))
                        .frame(width: 28, height: 28)
                        .background(Color.primary.opacity(0.07), in: RoundedRectangle(cornerRadius: 7))
                }
                .buttonStyle(.plain)
                .accessibilityIdentifier("settings.back")

                Text("Launcher Settings")
                    .font(.system(size: 19, weight: .semibold))
                    .accessibilityIdentifier("settings.title")

                Spacer()

                Button {
                    model.reindex()
                } label: {
                    HStack(spacing: 5) {
                        if model.isLoading {
                            ProgressView()
                                .controlSize(.small)
                        } else {
                            Image(systemName: "arrow.clockwise")
                        }
                        Text(model.isLoading ? "Indexing…" : "Reindex")
                    }
                }
                .buttonStyle(.bordered)
                .controlSize(.small)
                .disabled(model.isLoading)
                .help("Reindex applications and script commands")
                .accessibilityIdentifier("settings.reindex")

                KeyCap("Esc")
            }
            .padding(.horizontal, 16)
            .frame(height: LauncherStyle.headerHeight)

            Divider().opacity(0.65)

            // The body scrolls so that content the fixed-height panel can't
            // hold — an error label under the hotkey row, larger system text —
            // takes space from itself rather than clipping the header and
            // footer off both ends of the panel.
            ScrollView(.vertical) {
                VStack(alignment: .leading, spacing: 10) {
                    Text("GENERAL")
                        .font(.system(size: 12, weight: .semibold))
                        .tracking(0.5)
                        .foregroundStyle(Color.secondary)

                    VStack(spacing: 0) {
                        HStack(spacing: 16) {
                            ZStack {
                                RoundedRectangle(cornerRadius: 10, style: .continuous)
                                    .fill(Color.primary.opacity(0.075))
                                Image(systemName: "command")
                                    .font(.system(size: 18, weight: .semibold))
                                    .foregroundStyle(Color.secondary)
                            }
                            .frame(width: 40, height: 40)

                            VStack(alignment: .leading, spacing: 3) {
                                Text("Launcher hotkey")
                                    .font(.system(size: 15, weight: .semibold))
                                Text("Show or hide Launcher from anywhere")
                                    .font(.system(size: 13))
                                    .foregroundStyle(Color.secondary)
                            }

                            Spacer()

                            HotKeyRecorder(hotKey: settings.hotKey, onChange: model.updateHotKey)
                                .frame(width: 148, height: 34)
                        }
                        .padding(.horizontal, 14)
                        .frame(height: LauncherStyle.settingsRowHeight)

                        Divider().padding(.leading, 70)

                        HStack(spacing: 16) {
                            ZStack {
                                RoundedRectangle(cornerRadius: 10, style: .continuous)
                                    .fill(Color.primary.opacity(0.075))
                                Image(systemName: "power")
                                    .font(.system(size: 18, weight: .semibold))
                                    .foregroundStyle(Color.secondary)
                            }
                            .frame(width: 40, height: 40)

                            VStack(alignment: .leading, spacing: 3) {
                                Text("Start at login")
                                    .font(.system(size: 15, weight: .semibold))
                                Text("Open Launcher automatically after you log in")
                                    .font(.system(size: 13))
                                    .foregroundStyle(Color.secondary)
                            }

                            Spacer()

                            Toggle("Start at login", isOn: Binding(
                                get: { model.launchAtLogin },
                                set: { model.setLaunchAtLogin($0) }
                            ))
                            .labelsHidden()
                            .toggleStyle(.switch)
                            .controlSize(.small)
                            .accessibilityIdentifier("settings.startAtLogin")
                        }
                        .padding(.horizontal, 14)
                        .frame(height: LauncherStyle.settingsRowHeight)

                        Divider().padding(.leading, 70)

                        HStack(spacing: 16) {
                            ZStack {
                                RoundedRectangle(cornerRadius: 10, style: .continuous)
                                    .fill(Color.primary.opacity(0.075))
                                Image(systemName: "folder")
                                    .font(.system(size: 18, weight: .semibold))
                                    .foregroundStyle(Color.secondary)
                            }
                            .frame(width: 40, height: 40)

                            VStack(alignment: .leading, spacing: 3) {
                                Text("Scripts folder")
                                    .font(.system(size: 15, weight: .semibold))
                                Text((settings.scriptsDirectory.path as NSString).abbreviatingWithTildeInPath)
                                    .font(.system(size: 13))
                                    .foregroundStyle(Color.secondary)
                                    .lineLimit(1)
                                    .truncationMode(.middle)
                            }

                            Spacer()

                            Button("Reveal") {
                                let directory = model.effectiveScriptsDirectory
                                try? FileManager.default.createDirectory(at: directory, withIntermediateDirectories: true)
                                NSWorkspace.shared.activateFileViewerSelecting([directory])
                            }
                            .controlSize(.small)
                            .accessibilityIdentifier("settings.scriptsDir.reveal")

                            Button("Change…") {
                                let panel = NSOpenPanel()
                                panel.canChooseDirectories = true
                                panel.canChooseFiles = false
                                panel.allowsMultipleSelection = false
                                panel.directoryURL = settings.scriptsDirectory
                                if panel.runModal() == .OK, let url = panel.url {
                                    model.updateScriptsDirectory(url)
                                }
                            }
                            .controlSize(.small)
                            .accessibilityIdentifier("settings.scriptsDir.change")
                        }
                        .padding(.horizontal, 14)
                        .frame(height: LauncherStyle.settingsRowHeight)
                    }
                    .background(Color.launcherControlSurface.opacity(0.62), in: RoundedRectangle(cornerRadius: 13, style: .continuous))
                    .overlay {
                        RoundedRectangle(cornerRadius: 13, style: .continuous)
                            .stroke(Color.launcherSeparator.opacity(0.72), lineWidth: 1)
                    }

                    if let error = settings.hotKeyError {
                        Label(error, systemImage: "exclamationmark.triangle.fill")
                            .font(.system(size: 12, weight: .medium))
                            .foregroundStyle(Color.red)
                            .accessibilityIdentifier("settings.hotkey.error")
                    } else if let error = model.launchAtLoginError {
                        Label(error, systemImage: "exclamationmark.triangle.fill")
                            .font(.system(size: 12, weight: .medium))
                            .foregroundStyle(Color.red)
                            .accessibilityIdentifier("settings.startAtLogin.error")
                    } else {
                        Text("Click the shortcut, then press a new key combination.")
                            .font(.system(size: 12))
                            .foregroundStyle(Color.secondary)
                    }

                    Text("KEYBOARD")
                        .font(.system(size: 12, weight: .semibold))
                        .tracking(0.5)
                        .foregroundStyle(Color.secondary)
                        .padding(.top, 8)

                    VStack(spacing: 0) {
                        ShortcutReferenceRow(title: "Move through results", keys: ["↑", "↓"])
                        Divider().padding(.leading, 14)
                        ShortcutReferenceRow(title: "Open selected result", keys: ["↩"])
                        Divider().padding(.leading, 14)
                        ShortcutReferenceRow(title: "Show actions", keys: ["⌘", "K"])
                        Divider().padding(.leading, 14)
                        ShortcutReferenceRow(title: "Show script output", keys: ["⌘", "P"])
                    }
                    .background(Color.launcherControlSurface.opacity(0.62), in: RoundedRectangle(cornerRadius: 13, style: .continuous))
                    .overlay {
                        RoundedRectangle(cornerRadius: 13, style: .continuous)
                            .stroke(Color.launcherSeparator.opacity(0.72), lineWidth: 1)
                    }
                }
                .frame(maxWidth: .infinity, alignment: .leading)
                .padding(.horizontal, 22)
                .padding(.vertical, LauncherStyle.settingsContentPadding)
            }
            .scrollBounceBehavior(.basedOnSize)
            .frame(maxHeight: .infinity)

            Divider().opacity(0.65)

            HStack {
                Text("Launcher")
                    .font(.system(size: 12, weight: .semibold))
                    .foregroundStyle(Color.secondary)
                Text("Version 1.0")
                    .font(.system(size: 12))
                    .foregroundStyle(Color.secondary.opacity(0.75))
                Spacer()
                Button("Done") { model.showSearch() }
                    .keyboardShortcut(.escape, modifiers: [])
                    .accessibilityIdentifier("settings.done")
            }
            .padding(.horizontal, 16)
            .frame(height: LauncherStyle.footerHeight)
            .background(Color.launcherControlSurface.opacity(0.20))
        }
    }
}

private struct ShortcutReferenceRow: View {
    let title: String
    let keys: [String]

    var body: some View {
        HStack {
            Text(title)
                .font(.system(size: 13, weight: .medium))
            Spacer()
            HStack(spacing: 4) {
                ForEach(keys, id: \.self) { KeyCap($0) }
            }
        }
        .padding(.horizontal, 14)
        .frame(height: LauncherStyle.settingsShortcutRowHeight)
    }
}

struct KeyCap: View {
    let value: String

    init(_ value: String) {
        self.value = value
    }

    var body: some View {
        Text(value)
            .font(.system(size: 12, weight: .semibold, design: .rounded))
            .foregroundStyle(Color.secondary)
            .padding(.horizontal, 6)
            .frame(minWidth: 23, minHeight: 22)
            .background(Color.primary.opacity(0.075), in: RoundedRectangle(cornerRadius: 6, style: .continuous))
            .overlay {
                RoundedRectangle(cornerRadius: 6, style: .continuous)
                    .stroke(Color.launcherSeparator.opacity(0.72), lineWidth: 0.5)
            }
    }
}

extension Color {
    static let launcherSurface = Color(nsColor: NSColor(name: "LauncherSurface") { appearance in
        if appearance.bestMatch(from: [.darkAqua, .aqua]) == .darkAqua {
            return NSColor(srgbRed: 0.105, green: 0.105, blue: 0.115, alpha: 1)
        }
        return NSColor(srgbRed: 0.94, green: 0.94, blue: 0.95, alpha: 1)
    })
    static let launcherControlSurface = Color(nsColor: .controlBackgroundColor)
    static let launcherSeparator = Color(nsColor: .separatorColor)
}
