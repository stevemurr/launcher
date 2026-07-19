import SwiftUI

struct CreateScriptView: View {
    @ObservedObject var model: LauncherModel

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
                .accessibilityIdentifier("createScript.back")

                Text("Create Script Command")
                    .font(.system(size: 19, weight: .semibold))
                    .accessibilityIdentifier("createScript.title.header")

                Spacer()

                KeyCap("Esc")
            }
            .padding(.horizontal, 16)
            .frame(height: 59)

            Divider().opacity(0.65)

            ScrollView {
                VStack(spacing: 13) {
                    formRow("Template") {
                        Picker("", selection: $model.scriptDraft.template) {
                            ForEach(ScriptTemplate.allCases) { template in
                                Text(template.displayName).tag(template)
                            }
                        }
                        .labelsHidden()
                        .accessibilityIdentifier("createScript.template")
                    }

                    formRow("Mode") {
                        Picker("", selection: $model.scriptDraft.mode) {
                            Text("Full Output").tag(ScriptMode.fullOutput)
                            Text("Compact").tag(ScriptMode.compact)
                            Text("Silent").tag(ScriptMode.silent)
                            Text("Inline").tag(ScriptMode.inline)
                        }
                        .labelsHidden()
                        .accessibilityIdentifier("createScript.mode")
                    }

                    formRow("Title") {
                        TextField("Command Title", text: $model.scriptDraft.title)
                            .textFieldStyle(.roundedBorder)
                            .accessibilityIdentifier("createScript.title")
                    }

                    formRow("Description") {
                        TextField("Descriptive summary", text: $model.scriptDraft.description)
                            .textFieldStyle(.roundedBorder)
                            .accessibilityIdentifier("createScript.description")
                    }

                    formRow("Package Name") {
                        TextField("E.g., Developer Utils", text: $model.scriptDraft.packageName)
                            .textFieldStyle(.roundedBorder)
                            .accessibilityIdentifier("createScript.packageName")
                    }

                    formRow("") {
                        Toggle("Needs confirmation", isOn: $model.scriptDraft.needsConfirmation)
                            .accessibilityIdentifier("createScript.needsConfirmation")
                            .frame(maxWidth: .infinity, alignment: .leading)
                    }

                    formRow("Arguments") {
                        Stepper(value: argumentCount, in: 0...3) {
                            Text("\(model.scriptDraft.argumentPlaceholders.count)")
                                .font(.system(size: 13, weight: .medium))
                        }
                        .accessibilityIdentifier("createScript.argumentCount")
                        .frame(maxWidth: .infinity, alignment: .leading)
                    }

                    ForEach(model.scriptDraft.argumentPlaceholders.indices, id: \.self) { index in
                        formRow("Argument \(index + 1)") {
                            TextField("Placeholder", text: $model.scriptDraft.argumentPlaceholders[index])
                                .textFieldStyle(.roundedBorder)
                                .accessibilityIdentifier("createScript.argument.\(index)")
                        }
                    }

                    if let error = model.createScriptError {
                        Label(error, systemImage: "exclamationmark.triangle.fill")
                            .font(.system(size: 12, weight: .medium))
                            .foregroundStyle(Color.red)
                            .frame(maxWidth: .infinity, alignment: .leading)
                            .accessibilityIdentifier("createScript.error")
                    }
                }
                .padding(.horizontal, 130)
                .padding(.vertical, 24)
            }

            Divider().opacity(0.65)

            HStack(spacing: 12) {
                HStack(spacing: 8) {
                    ZStack {
                        RoundedRectangle(cornerRadius: 5, style: .continuous)
                            .fill(LinearGradient(colors: [.orange.opacity(0.75), .orange], startPoint: .top, endPoint: .bottom))
                        Image(systemName: "apple.terminal")
                            .font(.system(size: 11, weight: .bold))
                            .foregroundStyle(Color.white)
                    }
                    .frame(width: 20, height: 20)
                    Text("Create Script Command")
                        .font(.system(size: 13, weight: .semibold))
                        .foregroundStyle(Color.secondary)
                }

                Spacer()

                Button {
                    model.createScript(andOpen: true)
                } label: {
                    HStack(spacing: 6) {
                        Text("Create and Open Script")
                            .font(.system(size: 13, weight: .semibold))
                        KeyCap("⇧")
                        KeyCap("⌘")
                        KeyCap("↩")
                    }
                    .foregroundStyle(Color.secondary)
                }
                .buttonStyle(.plain)
                .keyboardShortcut(.return, modifiers: [.shift, .command])
                .disabled(trimmedTitleIsEmpty)
                .accessibilityIdentifier("createScript.createAndOpen")

                Rectangle()
                    .fill(Color.launcherSeparator)
                    .frame(width: 1, height: 14)

                Button {
                    model.createScript(andOpen: false)
                } label: {
                    HStack(spacing: 6) {
                        Text("Create Script")
                            .font(.system(size: 13, weight: .semibold))
                            .foregroundStyle(Color.primary.opacity(0.92))
                        KeyCap("⌘")
                        KeyCap("↩")
                    }
                }
                .buttonStyle(.plain)
                .keyboardShortcut(.return, modifiers: .command)
                .disabled(trimmedTitleIsEmpty)
                .accessibilityIdentifier("createScript.create")
            }
            .padding(.horizontal, 12)
            .frame(height: 39)
            .background(Color.launcherControlSurface.opacity(0.20))
        }
    }

    private var trimmedTitleIsEmpty: Bool {
        model.scriptDraft.title.trimmingCharacters(in: .whitespaces).isEmpty
    }

    private var argumentCount: Binding<Int> {
        Binding(
            get: { model.scriptDraft.argumentPlaceholders.count },
            set: { newCount in
                var placeholders = model.scriptDraft.argumentPlaceholders
                while placeholders.count < newCount { placeholders.append("") }
                while placeholders.count > newCount { placeholders.removeLast() }
                model.scriptDraft.argumentPlaceholders = placeholders
            }
        )
    }

    private func formRow(_ label: String, @ViewBuilder content: () -> some View) -> some View {
        HStack(alignment: .center, spacing: 16) {
            Text(label)
                .font(.system(size: 13))
                .foregroundStyle(Color.secondary)
                .frame(width: 110, alignment: .trailing)
            content()
                .frame(maxWidth: .infinity, alignment: .leading)
        }
    }
}
