//
//  RemoteContentBlocker.swift
//  KyPost
//
//  The WebKit content rule list the message reader installs until the user
//  presses "Load Remote Content" (EmailBodyWebView).
//

import WebKit

/// Blocks every load a message document could make on its own.
///
/// `loadsSubresources = false` is not enough by itself: WebKit's idea of a
/// subresource does not obviously cover `<link rel=preconnect|dns-prefetch|
/// prefetch|preload>`, `<a ping>`, CSS `url()`/`@import`/`@font-face`,
/// `srcset`, `<video poster>` or a `background=` attribute, and any one of
/// those is a read receipt. So this list blocks everything and lets through
/// only what the app itself puts in the document: `data:` (inline `cid:`
/// images, `InlineImages`) and `about:` (the message document, loaded from
/// memory). A `<meta http-equiv=refresh>` is a main-frame navigation, which
/// `EmailBodyWebView.navigationPolicy` refuses as well.
enum RemoteContentBlocker {
    static let identifier = "kypost.reader.block-remote-content.v1"

    /// Block all, then exempt `data:` and `about:`. `ignore-previous-rules`
    /// only lifts the rules above it, so the order is the point.
    static let encodedRules = """
        [
          {"trigger": {"url-filter": ".*"}, "action": {"type": "block"}},
          {"trigger": {"url-filter": "^data:"}, "action": {"type": "ignore-previous-rules"}},
          {"trigger": {"url-filter": "^about:"}, "action": {"type": "ignore-previous-rules"}}
        ]
        """

    @MainActor private static var compiled: Task<WKContentRuleList, any Error>?

    /// The compiled list, compiled once per process. A failure is not cached:
    /// the next message tries again, and renders nothing until it succeeds.
    @MainActor
    static func ruleList() async throws -> WKContentRuleList {
        if let compiled { return try await compiled.value }
        let task = Task { @MainActor in
            guard let store = WKContentRuleListStore.default(),
                  let list = try await store.compileContentRuleList(
                      forIdentifier: identifier,
                      encodedContentRuleList: encodedRules
                  )
            else { throw BlockerUnavailable() }
            return list
        }
        compiled = task
        do {
            return try await task.value
        } catch {
            if compiled == task { compiled = nil }
            throw error
        }
    }

    struct BlockerUnavailable: Error {}
}
