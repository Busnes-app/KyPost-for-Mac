//
//  LaunchSweepTests.swift
//  KyPost Tests
//
//  A crash or force-quit skips the preview-close cleanup, so the launch sweep
//  is what removes decrypted attachment plaintext a previous process left.
//

import Foundation
import Testing
@testable import KyPost

@Suite(.serialized) struct LaunchSweepTests {
    /// Stages files where the real paths put them, as a crashed process would
    /// have left them, and checks the launch sweep removes every one.
    @MainActor
    @Test func launchSweepRemovesPreviewsAPreviousProcessLeft() throws {
        let decrypted = try DecryptedAttachmentFiles().stage(DecryptedAttachment(
            name: "statement.pdf", mimeType: "application/pdf", data: Data("plaintext".utf8), contentId: nil
        ))
        let downloaded = InboxViewModel.attachmentTempRoot.appending(path: "cache-key/0/invoice.pdf")
        try FileManager.default.createDirectory(
            at: downloaded.deletingLastPathComponent(), withIntermediateDirectories: true
        )
        try Data("plaintext".utf8).write(to: downloaded)

        KyPostApp.sweepStaleAttachmentFiles()

        #expect(!FileManager.default.fileExists(atPath: decrypted.path))
        #expect(!FileManager.default.fileExists(atPath: downloaded.path))
        #expect(!FileManager.default.fileExists(atPath: InboxViewModel.attachmentTempRoot.path))
    }

    /// The first launch, or one after a clean exit, has nothing to sweep.
    @MainActor
    @Test func launchSweepWithNothingStagedIsANoOp() {
        KyPostApp.sweepStaleAttachmentFiles()
        KyPostApp.sweepStaleAttachmentFiles()
        #expect(!FileManager.default.fileExists(atPath: InboxViewModel.attachmentTempRoot.path))
    }
}
