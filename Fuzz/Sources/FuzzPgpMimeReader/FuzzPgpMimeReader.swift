//
//  FuzzPgpMimeReader.swift
//  KyPost fuzzing
//
//  libFuzzer entry point for PgpMimeReader, the parser that reads decrypted
//  PGP/MIME. Its input is whatever a sender encrypted, so every byte is
//  attacker-chosen. The two other files in this directory are symlinks to the
//  app's own sources: this fuzzes the shipping parser, not a copy.
//
//  Besides crashes and sanitizer reports, it traps when the reader breaks a
//  promise its callers rely on: the attachment caps, and "nil or a body".
//

import Foundation

@_cdecl("LLVMFuzzerTestOneInput")
nonisolated public func fuzzPgpMimeReader(_ start: UnsafeRawPointer, _ count: Int) -> CInt {
    let data = Data(bytes: start, count: count)

    if let body = PgpMimeReader.read(data) {
        precondition(body.attachments.count <= PgpMimeReader.attachmentPartCap,
                     "more attachments than attachmentPartCap")
        precondition(body.attachments.reduce(0) { $0 + $1.data.count } <= PgpMimeReader.attachmentByteCap,
                     "more attachment bytes than attachmentByteCap")
        precondition(body.html != nil || body.plain != nil,
                     "a body with neither html nor plain")
    }

    // Also reached directly: the reader applies it to the protected subject
    // and to attachment names.
    _ = PgpMimeReader.decodeEncodedWords(String(decoding: data, as: UTF8.self))
    return 0
}
