import AppKit
import QuickLookUI

final class QuickLookController: NSObject, QLPreviewPanelDataSource, QLPreviewPanelDelegate {
    private(set) var previewURL: URL?

    func toggle(_ url: URL) {
        guard let panel = QLPreviewPanel.shared() else { return }
        if panel.isVisible, previewURL == url {
            panel.orderOut(nil)
            return
        }
        previewURL = url
        panel.makeKeyAndOrderFront(nil)
        panel.reloadData()
    }

    func numberOfPreviewItems(in panel: QLPreviewPanel!) -> Int {
        previewURL == nil ? 0 : 1
    }

    func previewPanel(_ panel: QLPreviewPanel!, previewItemAt index: Int) -> QLPreviewItem! {
        previewURL as NSURL?
    }
}
