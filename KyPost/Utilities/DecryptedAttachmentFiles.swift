//
//  DecryptedAttachmentFiles.swift
//  KyPost
//
//  The one place a decrypted attachment touches disk without the user
//  choosing a destination: Quick Look needs a file URL. Each preview gets its
//  own directory under the attachments staging root, so the security wipe and
//  the Hostile Location Protection purge (`InboxViewModel.attachmentTempRoot`)
//  already cover it, and the reader deletes its own files when the preview
//  closes and when the screen goes away.
//

import Foundation

nonisolated struct DecryptedAttachmentFiles {
    /// Every staged directory lives under here.
    let root: URL

    /// Must stay inside `InboxViewModel.attachmentTempRoot`, which the wipe
    /// and the Hostile Location Protection purge delete; a test holds that.
    static let defaultRoot = FileManager.default.temporaryDirectory
        .appending(path: "attachments/decrypted", directoryHint: .isDirectory)

    init(root: URL = DecryptedAttachmentFiles.defaultRoot) {
        self.root = root
    }

    /// Writes one attachment for preview and returns its file URL. The
    /// directory is fresh per call, so two parts with the same sender-chosen
    /// name cannot collide and deleting one preview cannot touch another.
    func stage(_ attachment: DecryptedAttachment) throws -> URL {
        let directory = root.appending(path: UUID().uuidString, directoryHint: .isDirectory)
        try FileManager.default.createDirectory(at: directory, withIntermediateDirectories: true)
        var parent = root.deletingLastPathComponent()
        var values = URLResourceValues()
        values.isExcludedFromBackup = true
        try? parent.setResourceValues(values)
        let file = directory.appending(path: safeAttachmentFileName(attachment.name))
#if os(iOS)
        // Complete protection: unreadable while the device is locked, the
        // strongest class available for a file this short-lived. (macOS
        // refuses the option outright for a sandboxed temporary file.)
        try attachment.data.write(to: file, options: [.withoutOverwriting, .completeFileProtection])
#else
        try attachment.data.write(to: file, options: [.withoutOverwriting])
#endif
        return file
    }

    /// Deletes one staged preview — the file's own directory, never a parent.
    func remove(_ file: URL) {
        let directory = file.deletingLastPathComponent()
        guard directory.deletingLastPathComponent().standardizedFileURL == root.standardizedFileURL
        else { return }
        try? FileManager.default.removeItem(at: directory)
    }
}

/// A sender-chosen filename made safe to use as one path component.
///
/// Path separators become `_`; controls and format characters (bidi
/// overrides, zero-width) are dropped so `invoice\u{202E}fdp.exe` cannot
/// present as a PDF; leading dots are stripped so a name cannot hide itself
/// or be `..`. Capped well under the 255-byte component limit.
nonisolated func safeAttachmentFileName(_ name: String) -> String {
    var scalars = String.UnicodeScalarView()
    for scalar in name.unicodeScalars {
        switch scalar.properties.generalCategory {
        case .control, .format, .lineSeparator, .paragraphSeparator:
            continue
        default:
            scalars.append(scalar == "/" || scalar == ":" || scalar == "\\" ? "_" : scalar)
        }
    }
    var cleaned = String(scalars).trimmingCharacters(in: .whitespaces)
    while cleaned.hasPrefix(".") { cleaned.removeFirst() }
    while cleaned.utf8.count > 200 { cleaned.removeLast() }
    return cleaned.isEmpty ? "attachment" : cleaned
}
