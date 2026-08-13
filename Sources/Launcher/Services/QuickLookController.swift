import AppKit
import QuickLookUI

final class QuickLookController: NSObject, QLPreviewPanelDataSource, QLPreviewPanelDelegate {
    private(set) var previewURL: URL?

    func toggle(_ url: URL) {
        guard let panel = QLPreviewPanel.shared() else { return }
        if panel.isVisible, previewURL == url {
            dismiss(panel)
            return
        }
        previewURL = url
        panel.makeKeyAndOrderFront(nil)
        panel.reloadData()
    }

    func dismiss() {
        guard QLPreviewPanel.sharedPreviewPanelExists(),
              let panel = QLPreviewPanel.shared() else {
            previewURL = nil
            return
        }
        dismiss(panel)
    }

    func numberOfPreviewItems(in panel: QLPreviewPanel!) -> Int {
        previewURL == nil ? 0 : 1
    }

    func previewPanel(_ panel: QLPreviewPanel!, previewItemAt index: Int) -> QLPreviewItem! {
        previewURL as NSURL?
    }

    private func dismiss(_ panel: QLPreviewPanel) {
        panel.orderOut(nil)
        previewURL = nil
    }
}
