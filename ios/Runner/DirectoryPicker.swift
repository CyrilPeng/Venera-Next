import UIKit
import Flutter

final class DirectoryPicker: NSObject, UIDocumentPickerDelegate {
    private var completion: ((URL?) -> Void)?

    func selectDirectory(from presenter: UIViewController,
                         completion: @escaping (URL?) -> Void) {
        self.completion = completion
        let picker = UIDocumentPickerViewController(forOpeningContentTypes: [.folder], asCopy: false)
        picker.delegate = self
        picker.allowsMultipleSelection = false
        picker.modalPresentationStyle = .formSheet
        presenter.present(picker, animated: true)
    }

    private func finish(_ url: URL?) {
        let callback = completion
        completion = nil
        callback?(url)
    }

    func documentPicker(_ controller: UIDocumentPickerViewController, didPickDocumentsAt urls: [URL]) {
        finish(urls.first)
    }

    func documentPickerWasCancelled(_ controller: UIDocumentPickerViewController) {
        finish(nil)
    }
}
