import AppKit
import SwiftUI

struct ListSectionHeader: View {
    let title: String
    var showsProgress = false
    var progressAccessibilityLabel = "Indexing applications"

    var body: some View {
        HStack {
            Text(title)
                .font(.system(size: 13, weight: .semibold))
                .foregroundStyle(Color.secondary)
            Spacer()
            if showsProgress {
                ProgressView()
                    .controlSize(.small)
                    .accessibilityLabel(progressAccessibilityLabel)
            }
        }
        .padding(.horizontal, 16)
        .frame(height: 36)
    }
}

struct FileBrowserList: View {
    @ObservedObject var model: LauncherModel

    var body: some View {
        ScrollViewReader { proxy in
            ScrollView {
                LazyVStack(spacing: 0) {
                    if let listing = model.fileListing {
                        content(for: listing)
                    } else if model.isFileListingLoading {
                        ListSectionHeader(
                            title: "Loading folder…",
                            showsProgress: true,
                            progressAccessibilityLabel: "Loading folder"
                        )
                    }
                }
                .padding(.bottom, 8)
            }
            .onChange(of: model.selectedIndex) { _, newIndex in
                guard model.isFileBrowsing, model.results.indices.contains(newIndex) else { return }
                proxy.scrollTo(model.results[newIndex].id)
            }
        }
    }

    @ViewBuilder
    private func content(for listing: FileListing) -> some View {
        let iCloudCount = listing.iCloudEntry == nil ? 0 : 1
        let directoryCount = listing.directories.count

        switch listing.error {
        case .notFound:
            statusRow("No such folder", symbolName: "questionmark.folder")
        case .notReadable:
            statusRow("Folder can't be read", symbolName: "lock")
        case nil:
            if model.results.isEmpty {
                statusRow("No matching entries", symbolName: "magnifyingglass")
            }
            if iCloudCount > 0 {
                ListSectionHeader(title: "iCloud Drive")
                row(at: 0)
            }
            if directoryCount > 0 {
                ListSectionHeader(title: "Directories")
                ForEach(iCloudCount..<(iCloudCount + directoryCount), id: \.self) { index in
                    row(at: index)
                }
            }
            if !listing.files.isEmpty {
                ListSectionHeader(title: "Files")
                ForEach((iCloudCount + directoryCount)..<model.results.count, id: \.self) { index in
                    row(at: index)
                }
            }
            if listing.isTruncated {
                Text("Showing first \(FileBrowserEngine.maxEntries) entries")
                    .font(.system(size: 12, weight: .medium))
                    .foregroundStyle(Color.secondary)
                    .frame(maxWidth: .infinity)
                    .frame(height: 32)
            }
        }
    }

    @ViewBuilder
    private func row(at index: Int) -> some View {
        if model.results.indices.contains(index) {
            let item = model.results[index]
            FileBrowserRow(
                item: item,
                isSelected: index == model.selectedIndex,
                onSelect: { model.select(index: index) },
                onOpen: {
                    model.select(index: index)
                    model.activateSelected()
                }
            )
            .id(item.id)
        }
    }

    private func statusRow(_ message: String, symbolName: String) -> some View {
        HStack(spacing: 8) {
            Image(systemName: symbolName)
            Text(message)
        }
        .font(.system(size: 14))
        .foregroundStyle(Color.secondary)
        .frame(maxWidth: .infinity)
        .frame(height: 64)
    }
}

private struct FileBrowserRow: View {
    let item: LauncherItem
    let isSelected: Bool
    let onSelect: () -> Void
    let onOpen: () -> Void

    var body: some View {
        Button(action: onOpen) {
            HStack(spacing: 11) {
                icon

                Text(item.title)
                    .font(.system(size: 15, weight: .medium))
                    .foregroundStyle(Color.primary)
                    .lineLimit(1)

                if let detail = item.detail {
                    Text(detail)
                        .font(.system(size: 13, design: .monospaced))
                        .foregroundStyle(Color.secondary)
                }

                Spacer(minLength: 16)
            }
            .padding(.horizontal, 9)
            .frame(maxWidth: .infinity)
            .frame(height: 40)
            .background {
                RoundedRectangle(cornerRadius: 10, style: .continuous)
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

    private var icon: some View {
        Group {
            if item.id == "file.icloud" {
                Image(systemName: "icloud.fill")
                    .font(.system(size: 15, weight: .semibold))
                    .foregroundStyle(Color.cyan)
            } else if let url = item.fileURL {
                Image(nsImage: NSWorkspace.shared.icon(forFile: url.path))
                    .resizable()
                    .interpolation(.high)
            } else {
                Image(systemName: item.kind.symbolName)
                    .font(.system(size: 13, weight: .semibold))
                    .foregroundStyle(Color.secondary)
            }
        }
        .frame(width: 24, height: 24)
    }
}

struct OpenWithPalette: View {
    @ObservedObject var model: LauncherModel

    var body: some View {
        VStack(spacing: 0) {
            HStack {
                Text(model.openWithTitle)
                    .font(.system(size: 13, weight: .semibold))
                    .foregroundStyle(Color.secondary)
                    .lineLimit(1)
                    .accessibilityIdentifier("openWith.title")
                Spacer()
            }
            .padding(.horizontal, 12)
            .frame(height: 40)

            if model.openWithApps.isEmpty {
                HStack(spacing: 8) {
                    Image(systemName: "questionmark.app")
                    Text("No applications found")
                }
                .font(.system(size: 14))
                .foregroundStyle(Color.secondary)
                .frame(height: 40)
            }

            ForEach(Array(model.openWithApps.enumerated()), id: \.element.id) { index, app in
                Button {
                    model.selectOpenWith(index: index)
                    model.confirmOpenWith()
                } label: {
                    HStack(spacing: 10) {
                        Image(nsImage: NSWorkspace.shared.icon(forFile: app.url.path))
                            .resizable()
                            .interpolation(.high)
                            .frame(width: 20, height: 20)
                        Text(app.name)
                            .font(.system(size: 16, weight: .medium))
                        Spacer()
                        if index == model.openWithSelectionIndex {
                            KeyCap("↩")
                        }
                    }
                    .foregroundStyle(Color.primary)
                    .padding(.horizontal, 10)
                    .frame(height: 40)
                    .background {
                        RoundedRectangle(cornerRadius: 9, style: .continuous)
                            .fill(index == model.openWithSelectionIndex ? Color.primary.opacity(0.085) : Color.clear)
                    }
                    .contentShape(Rectangle())
                }
                .buttonStyle(.plain)
                .padding(.horizontal, 7)
                .onHover { hovering in
                    if hovering { model.selectOpenWith(index: index) }
                }
                .accessibilityIdentifier("openWith.\(app.name)")
            }

            Spacer(minLength: 6)
        }
        .frame(width: 360, height: CGFloat(52 + max(model.openWithApps.count, 1) * 40))
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
}
