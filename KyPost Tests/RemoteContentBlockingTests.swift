//
//  RemoteContentBlockingTests.swift
//  KyPost Tests
//
//  The reader's remote-content block, proved against real WebKit: a message
//  carrying every beacon vector is rendered through the reader's own page
//  (`EmailBodyWebView.makePage`) while something counts what reaches it.
//
//  Two counters, because of where the tests can run:
//
//  - A loopback HTTP server (NWListener on 127.0.0.1, random port). This is
//    the real thing — preconnect and dns-prefetch only exist for http(s) —
//    but the macOS test host is the sandboxed app, which may not listen
//    (EPERM; it has no network-server entitlement and must not get one for
//    a test). It runs wherever a loopback listener is allowed: the iOS
//    Simulator, which is where CI runs the suite.
//  - A URL scheme handler on the page itself. It runs everywhere, macOS
//    included, and covers every vector that can fetch a non-http URL.
//

import Darwin
import Foundation
import Network
import SwiftUI
import Testing
import WebKit
@testable import KyPost

private let pixel = "R0lGODlhAQABAIAAAAAAAP///yH5BAEAAAAALAAAAAABAAEAAAIBRAA7"

/// Whether this process may listen on loopback (false in the sandboxed
/// macOS test host).
private let loopbackListenerAllowed: Bool = {
    let fd = socket(AF_INET, SOCK_STREAM, 0)
    guard fd >= 0 else { return false }
    defer { close(fd) }
    var address = sockaddr_in()
    address.sin_len = UInt8(MemoryLayout<sockaddr_in>.size)
    address.sin_family = sa_family_t(AF_INET)
    address.sin_addr.s_addr = inet_addr("127.0.0.1")
    let bound = withUnsafePointer(to: &address) {
        $0.withMemoryRebound(to: sockaddr.self, capacity: 1) {
            bind(fd, $0, socklen_t(MemoryLayout<sockaddr_in>.size))
        }
    }
    return bound == 0 && listen(fd, 1) == 0
}()

/// A loopback HTTP server that counts connections and request lines, and
/// answers everything with a 1×1 GIF.
private final class BeaconServer: @unchecked Sendable {
    private let listener: NWListener
    private let queue = DispatchQueue(label: "kypost.tests.beacon-server")
    private let lock = NSLock()
    private var connections = 0
    private var requestLines: [String] = []
    private(set) var port: UInt16 = 0

    init() throws {
        let parameters = NWParameters.tcp
        parameters.requiredLocalEndpoint = .hostPort(host: "127.0.0.1", port: .any)
        listener = try NWListener(using: parameters)
    }

    func start() async throws {
        listener.newConnectionHandler = { [weak self] connection in self?.accept(connection) }
        let listener = listener
        port = try await withCheckedThrowingContinuation { continuation in
            listener.stateUpdateHandler = { state in
                switch state {
                case .ready:
                    listener.stateUpdateHandler = nil
                    continuation.resume(returning: listener.port?.rawValue ?? 0)
                case .failed(let error), .waiting(let error):
                    listener.stateUpdateHandler = nil
                    continuation.resume(throwing: error)
                default:
                    break
                }
            }
            listener.start(queue: queue)
        }
    }

    func stop() { listener.cancel() }

    var base: String { "http://127.0.0.1:\(port)" }

    /// A preconnect opens a socket without sending a request, so both count.
    var connectionCount: Int { lock.withLock { connections } }
    var requests: [String] { lock.withLock { requestLines } }

    private func accept(_ connection: NWConnection) {
        lock.withLock { connections += 1 }
        connection.start(queue: queue)
        connection.receive(minimumIncompleteLength: 1, maximumLength: 65_536) { [weak self] data, _, _, _ in
            if let data, let text = String(data: data, encoding: .utf8),
               let line = text.split(separator: "\r\n").first {
                self?.lock.withLock { self?.requestLines.append(String(line)) }
            }
            let gif = Data(base64Encoded: pixel)!
            var response = Data((
                "HTTP/1.1 200 OK\r\nContent-Type: image/gif\r\n"
                    + "Content-Length: \(gif.count)\r\nConnection: close\r\n\r\n"
            ).utf8)
            response.append(gif)
            connection.send(content: response, completion: .contentProcessed { _ in connection.cancel() })
        }
    }
}

/// Serves `kypost-beacon:` on the page itself and records every request.
private struct CountingSchemeHandler: URLSchemeHandler {
    static let scheme = "kypost-beacon"
    let log: Box<[String]>

    func reply(for request: URLRequest) -> AsyncThrowingStream<URLSchemeTaskResult, any Error> {
        let url = request.url ?? URL(string: "\(Self.scheme)://unknown")!
        log.mutate { $0.append(url.absoluteString) }
        let gif = Data(base64Encoded: pixel)!
        return AsyncThrowingStream { continuation in
            continuation.yield(.response(URLResponse(
                url: url, mimeType: "image/gif", expectedContentLength: gif.count, textEncodingName: nil
            )))
            continuation.yield(.data(gif))
            continuation.finish()
        }
    }
}

@MainActor
@Suite(.serialized) struct RemoteContentBlockingTests {
    /// Every vector the hostile review named, each under its own path so a
    /// failure says which one leaked.
    private func beaconMessage(_ base: String) -> String {
        """
        <html><head>
        <meta http-equiv="refresh" content="0; url=\(base)/meta-refresh">
        <link rel="preconnect" href="\(base)/preconnect">
        <link rel="dns-prefetch" href="\(base)/dns-prefetch">
        <link rel="prefetch" href="\(base)/prefetch">
        <link rel="preload" href="\(base)/preload.png" as="image">
        <link rel="stylesheet" href="\(base)/stylesheet.css">
        <style>
          @import url("\(base)/import.css");
          @font-face { font-family: Beacon; src: url("\(base)/font.woff"); }
          body { font-family: Beacon; }
          .css-bg { background-image: url("\(base)/css-url.png"); }
        </style>
        </head>
        <body background="\(base)/body-background.png">
        <div class="css-bg">css url()</div>
        <div style="background: url('\(base)/inline-style.png')">inline style</div>
        <table background="\(base)/table-background.png"><tr>
          <td background="\(base)/td-background.png">cell</td>
        </tr></table>
        <img src="\(base)/img.png">
        <img srcset="\(base)/srcset-1x.png 1x, \(base)/srcset-2x.png 2x">
        <picture><source srcset="\(base)/picture-source.png"><img alt=""></picture>
        <video poster="\(base)/video-poster.png"></video>
        <audio src="\(base)/audio.mp3" preload="auto"></audio>
        <svg width="1" height="1"><image href="\(base)/svg-image.png" width="1" height="1"/></svg>
        <input type="image" src="\(base)/input-image.png">
        <iframe src="\(base)/iframe.html"></iframe>
        <object data="\(base)/object.png"></object>
        <a id="ping" ping="\(base)/ping" href="https://example.invalid/">link with ping</a>
        <img id="inline" src="data:image/gif;base64,\(pixel)">
        </body></html>
        """
    }

    /// Opens the page the reader would, loads `html`, and waits for the
    /// document to finish.
    private func render(
        _ html: String,
        allowsRemoteContent: Bool,
        schemeLog: Box<[String]>? = nil
    ) async throws -> WebPage {
        // Link taps go to the browser; here they go nowhere.
        let page = try await EmailBodyWebView.makePage(
            allowsRemoteContent: allowsRemoteContent,
            openURL: OpenURLAction { _ in .handled }
        ) { configuration in
            if let schemeLog, let scheme = URLScheme(CountingSchemeHandler.scheme) {
                configuration.urlSchemeHandlers[scheme] = CountingSchemeHandler(log: schemeLog)
            }
        }
        for try await event in page.load(html: html) where event == .finished {
            break
        }
        return page
    }

    /// Clicks the `<a ping>` (pings fire only on a click) from the app's
    /// world, since page JavaScript is off; checks the app's own `data:`
    /// image rendered under the list, so the block is not "nothing loads";
    /// then gives anything WebKit schedules after load — preloads, fonts, the
    /// refresh timer, the ping — time to go out.
    private func settle(_ page: WebPage) async throws {
        _ = try? await page.callJavaScript("document.getElementById('ping').click()")
        let inlineWidth = try await page.callJavaScript(
            "return document.getElementById('inline').naturalWidth"
        ) as? Int
        #expect(inlineWidth == 1)
        try await Task.sleep(for: .seconds(2))
    }

    private func waitFor(_ condition: () -> Bool) async throws {
        let deadline = ContinuousClock.now + .seconds(10)
        while !condition(), ContinuousClock.now < deadline {
            try await Task.sleep(for: .milliseconds(100))
        }
    }

    // MARK: Over HTTP, where a loopback listener is allowed

    @Test(.enabled(if: loopbackListenerAllowed, "the sandboxed macOS host may not listen"))
    func noBeaconReachesALoopbackServerWhileBlocked() async throws {
        let server = try BeaconServer()
        try await server.start()
        defer { server.stop() }

        let page = try await render(beaconMessage(server.base), allowsRemoteContent: false)
        try await settle(page)

        #expect(server.connectionCount == 0, "Beacon connections: \(server.connectionCount), requests: \(server.requests)")
        #expect(server.requests.isEmpty, "Beacons reached the server: \(server.requests)")
    }

    /// The control: the server is reachable, and a page without the list
    /// ("Load Remote Content") does load images.
    @Test(.enabled(if: loopbackListenerAllowed, "the sandboxed macOS host may not listen"))
    func imagesReachALoopbackServerOnceAllowed() async throws {
        let server = try BeaconServer()
        try await server.start()
        defer { server.stop() }

        let html = "<html><body><img id=\"remote\" src=\"\(server.base)/allowed.png\"></body></html>"
        let page = try await render(html, allowsRemoteContent: true)
        try await waitFor { server.requests.contains { $0.hasPrefix("GET /allowed.png") } }

        #expect(server.requests.contains { $0.hasPrefix("GET /allowed.png") })
        let width = try await page.callJavaScript("return document.getElementById('remote').naturalWidth") as? Int
        #expect(width == 1)
    }

    // MARK: Over a URL scheme handler, everywhere

    @Test func noBeaconReachesASchemeHandlerWhileBlocked() async throws {
        let log = Box<[String]>([])
        let page = try await render(
            beaconMessage("\(CountingSchemeHandler.scheme)://beacon"),
            allowsRemoteContent: false,
            schemeLog: log
        )
        try await settle(page)
        #expect(log.value.isEmpty, "Beacons reached the handler: \(log.value)")
    }

    @Test func imagesReachASchemeHandlerOnceAllowed() async throws {
        let log = Box<[String]>([])
        let html = "<html><body><img id=\"remote\" src=\"\(CountingSchemeHandler.scheme)://beacon/allowed.png\"></body></html>"
        let page = try await render(html, allowsRemoteContent: true, schemeLog: log)
        try await waitFor { log.value.contains { $0.hasSuffix("/allowed.png") } }

        #expect(log.value.contains { $0.hasSuffix("/allowed.png") })
        let width = try await page.callJavaScript("return document.getElementById('remote').naturalWidth") as? Int
        #expect(width == 1)
    }
}
