//
//  TipJarStoreTests.swift
//  KyPost Tests
//
//  A tip that returns `.pending` from `purchase` (Ask to Buy, SCA) completes
//  later, outside the purchase call; only the `Transaction.updates` listener
//  can finish it. The streams are injected so this runs without StoreKitTest
//  or a simulator store.
//

import Foundation
import Testing
@testable import KyPost

@MainActor
@Suite(.serialized) struct TipJarStoreTests {
    private struct Harness {
        let store: TipJarStore
        let updates: AsyncStream<TipJarTransactionUpdate>.Continuation
        let unfinished: AsyncStream<TipJarTransactionUpdate>.Continuation
    }

    private struct StoreUnavailable: Error {}

    private func makeHarness(productsFail: Bool = false) -> Harness {
        let (updates, updatesContinuation) = AsyncStream<TipJarTransactionUpdate>.makeStream()
        let (unfinished, unfinishedContinuation) = AsyncStream<TipJarTransactionUpdate>.makeStream()
        let store = TipJarStore(source: TipJarTransactionSource(
            loadProducts: { _ in
                if productsFail { throw StoreUnavailable() }
                return []
            },
            updates: { updates },
            unfinished: { unfinished }
        ))
        return Harness(store: store, updates: updatesContinuation, unfinished: unfinishedContinuation)
    }

    private func update(_ id: String, verified: Bool, into finished: Box<[String]>) -> TipJarTransactionUpdate {
        TipJarTransactionUpdate(productID: id, isVerified: verified, finish: {
            finished.mutate { $0.append(id) }
        })
    }

    /// Bounded wait: polls up to ~5 s for `condition`.
    private func waitUntil(_ condition: () -> Bool) async throws {
        for _ in 0..<50 where !condition() {
            try await Task.sleep(for: .milliseconds(100))
        }
    }

    @Test func aDeferredTipIsFinishedOnceApproved() async throws {
        let harness = makeHarness()
        let finished = Box<[String]>([])
        harness.unfinished.finish()
        await harness.store.start()
        #expect(finished.value.isEmpty)

        // Approved outside the purchase call, as a parent approving later is.
        harness.updates.yield(update(TipJarStore.ProductID.oneTimeMail, verified: true, into: finished))

        try await waitUntil { !finished.value.isEmpty }
        // Give a duplicate finish the chance to show up before asserting once.
        try await Task.sleep(for: .milliseconds(200))
        #expect(finished.value == [TipJarStore.ProductID.oneTimeMail])
        harness.updates.finish()
    }

    @Test func anUnverifiedUpdateIsNotFinished() async throws {
        let harness = makeHarness()
        let finished = Box<[String]>([])
        harness.unfinished.finish()
        await harness.store.start()

        harness.updates.yield(update("unverified", verified: false, into: finished))
        // A verified update after it proves the listener processed both, in order.
        harness.updates.yield(update("verified", verified: true, into: finished))

        try await waitUntil { !finished.value.isEmpty }
        #expect(finished.value == ["verified"])
        harness.updates.finish()
    }

    @Test func startDrainsUnfinishedTransactions() async throws {
        let harness = makeHarness()
        let finished = Box<[String]>([])
        harness.unfinished.yield(update("left-over", verified: true, into: finished))
        harness.unfinished.yield(update("tampered", verified: false, into: finished))
        harness.unfinished.finish()

        await harness.store.start()

        #expect(finished.value == ["left-over"])
        harness.updates.finish()
    }

    // The tip section shows one status line. It used to print a failed load
    // twice: once as the empty-list fallback, once as the error.
    @Test func aFailedLoadShowsItsErrorOnce() async {
        let harness = makeHarness(productsFail: true)
        harness.unfinished.finish()
        await harness.store.start()

        let error = harness.store.errorMessage
        #expect(error != nil)
        #expect(harness.store.statusMessage == error)
        harness.updates.finish()
    }

    @Test func anEmptyCatalogueSaysTipsAreUnavailable() async {
        let harness = makeHarness()
        harness.unfinished.finish()
        await harness.store.start()

        #expect(harness.store.errorMessage == nil)
        #expect(harness.store.statusMessage == String(localized: "Tips are not available right now."))
        harness.updates.finish()
    }
}
