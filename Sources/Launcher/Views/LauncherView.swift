import AppKit
import SwiftUI

struct LauncherRootView: View {
    @ObservedObject var model: LauncherModel

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
                }
            }

            if model.screen == .search, model.isActionsPresented {
                ActionsPalette(model: model)
                    .padding(.trailing, 8)
                    .padding(.bottom, 45)
                    .transition(.opacity.combined(with: .scale(scale: 0.98, anchor: .bottomTrailing)))
            }
        }
        .frame(width: 774, height: 512)
        .clipShape(RoundedRectangle(cornerRadius: 16, style: .continuous))
        .overlay {
            RoundedRectangle(cornerRadius: 16, style: .continuous)
                .stroke(Color.launcherSeparator.opacity(0.82), lineWidth: 1)
        }
        .animation(.easeOut(duration: 0.12), value: model.isActionsPresented)
    }
}

private struct LauncherSearchView: View {
    @ObservedObject var model: LauncherModel

    var body: some View {
        VStack(spacing: 0) {
            searchHeader
                .frame(height: 59)

            Divider().opacity(0.65)

            resultsList
                .frame(maxHeight: .infinity)

            Divider().opacity(0.65)

            footer
                .frame(height: 39)
        }
    }

    private var searchHeader: some View {
        HStack(spacing: 12) {
            LauncherSearchField(
                text: $model.query,
                focusToken: model.focusToken,
                onCommand: handle
            )
            .frame(height: 32)

            HStack(spacing: 5) {
                Text("Hotkey")
                    .font(.system(size: 13, weight: .medium))
                    .foregroundStyle(Color.secondary.opacity(0.72))
                KeyCap(model.settings.hotKey.displayString)
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
        let rowOffset = model.calculation == nil ? 0 : 1
        let rowCount = model.calculation == nil ? 6 : 4
        let showsResultsSection = model.calculation == nil || model.results.count > 1

        return VStack(spacing: 0) {
            if let calculation = model.calculation {
                sectionHeader("Calculator", showsProgress: false)

                CalculatorCard(
                    calculation: calculation,
                    isSelected: model.selectedIndex == 0,
                    onSelect: { model.select(index: 0) },
                    onOpen: {
                        model.select(index: 0)
                        model.activateSelected()
                    }
                )
            }

            if showsResultsSection {
                sectionHeader("Results", showsProgress: model.isLoading)

                ForEach(0..<rowCount, id: \.self) { index in
                    let resultIndex = index + rowOffset
                    if model.results.indices.contains(resultIndex) {
                        ResultRow(
                            item: model.results[resultIndex],
                            isSelected: resultIndex == model.selectedIndex,
                            onSelect: { model.select(index: resultIndex) },
                            onOpen: {
                                model.select(index: resultIndex)
                                model.activateSelected()
                            }
                        )
                    } else if index == 0, rowOffset == 0, !model.isLoading {
                        HStack(spacing: 8) {
                            Image(systemName: "magnifyingglass")
                            Text("No matching applications or settings")
                        }
                        .font(.system(size: 14))
                        .foregroundStyle(Color.secondary)
                        .frame(maxWidth: .infinity, maxHeight: .infinity)
                    } else {
                        Color.clear
                    }
                }
                .frame(height: 48)
            }

            HStack(spacing: 8) {
                Image(systemName: model.isLoading ? "arrow.triangle.2.circlepath" : "sparkle.magnifyingglass")
                    .font(.system(size: 13, weight: .semibold))
                    .foregroundStyle(Color.secondary.opacity(0.72))
                Text(model.isLoading ? "Indexing installed applications…" : "Search applications and System Settings, or type a calculation like 5+5")
                    .font(.system(size: 13, weight: .medium))
                    .foregroundStyle(Color.secondary)
                Spacer()
            }
            .padding(.horizontal, 16)
            .frame(height: 44)

            Spacer(minLength: 0)
        }
    }

    private func sectionHeader(_ title: String, showsProgress: Bool) -> some View {
        HStack {
            Text(title)
                .font(.system(size: 13, weight: .semibold))
                .foregroundStyle(Color.secondary)
            Spacer()
            if showsProgress {
                ProgressView()
                    .controlSize(.small)
                    .accessibilityLabel("Indexing applications")
            }
        }
        .padding(.horizontal, 16)
        .frame(height: 36)
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

            Spacer()

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
        .background(Color.launcherControlSurface.opacity(0.20))
    }

    private func handle(_ command: LauncherKeyCommand) {
        switch command {
        case .moveDown: model.moveSelection(by: 1)
        case .moveUp: model.moveSelection(by: -1)
        case .submit: model.activateSelected()
        case .escape: model.handleEscape()
        case .toggleActions: model.toggleActions()
        case .settings: model.showSettings()
        }
    }

    private func primaryActionTitle(for item: LauncherItem) -> String {
        switch item.kind {
        case .application: "Open Application"
        case .systemSetting: "Open System Settings"
        case .launcherSetting: "Open Launcher Settings"
        case .calculator: "Copy Answer"
        }
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
        .accessibilityIdentifier("result.\(item.title)")
        .accessibilityLabel("\(item.title), \(item.kind.rawValue)")
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
        return LinearGradient(colors: [.gray, .black.opacity(0.82)], startPoint: .top, endPoint: .bottom)
    }
}

private struct ActionsPalette: View {
    @ObservedObject var model: LauncherModel

    var body: some View {
        VStack(spacing: 0) {
            HStack {
                Text(model.selectedItem?.title ?? "Actions")
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
                        KeyCap(action.shortcut)
                    }
                    .foregroundStyle(Color.primary)
                    .padding(.horizontal, 10)
                    .frame(height: 40)
                    .background {
                        RoundedRectangle(cornerRadius: 9, style: .continuous)
                            .fill(index == 0 ? Color.primary.opacity(0.085) : Color.clear)
                    }
                    .contentShape(Rectangle())
                }
                .buttonStyle(.plain)
                .padding(.horizontal, 7)
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
        switch model.selectedItem?.kind {
        case .application: return "Open Application"
        case .systemSetting: return "Open System Settings"
        case .launcherSetting: return "Open Launcher Settings"
        case .calculator: return "Copy Answer"
        case nil: return action.title
        }
    }
}

private struct LauncherSettingsView: View {
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

                KeyCap("Esc")
            }
            .padding(.horizontal, 16)
            .frame(height: 59)

            Divider().opacity(0.65)

            VStack(alignment: .leading, spacing: 14) {
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
                    .padding(14)
                    .frame(height: 74)

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
                    .padding(14)
                    .frame(height: 74)
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
                }
                .background(Color.launcherControlSurface.opacity(0.62), in: RoundedRectangle(cornerRadius: 13, style: .continuous))
                .overlay {
                    RoundedRectangle(cornerRadius: 13, style: .continuous)
                        .stroke(Color.launcherSeparator.opacity(0.72), lineWidth: 1)
                }

                Spacer()
            }
            .padding(.horizontal, 22)
            .padding(.top, 20)

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
            .frame(height: 39)
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
        .frame(height: 38)
    }
}

private struct KeyCap: View {
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

private extension Color {
    static let launcherSurface = Color(nsColor: NSColor(name: "LauncherSurface") { appearance in
        if appearance.bestMatch(from: [.darkAqua, .aqua]) == .darkAqua {
            return NSColor(srgbRed: 0.105, green: 0.105, blue: 0.115, alpha: 1)
        }
        return NSColor(srgbRed: 0.94, green: 0.94, blue: 0.95, alpha: 1)
    })
    static let launcherControlSurface = Color(nsColor: .controlBackgroundColor)
    static let launcherSeparator = Color(nsColor: .separatorColor)
}
