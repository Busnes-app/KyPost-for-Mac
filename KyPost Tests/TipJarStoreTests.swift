//
//  TipJarStoreTests.swift
//  KyPost Tests
//
//  A tip that returns `.pending` from `purchase` (Ask to Buy, SCA) completes
//  later, outside the purchase call; only the `Transaction.updates` listener
//  can finish it.
//

import Foundation
import StoreKit
import StoreKitTest
import Testing
@testable import KyPost

private final class TipJarTestsBundleAnchor {}

@MainActor
@Suite(.serialized) struct TipJarStoreTests {
    private func makeSession() throws -> SKTestSession {
        let url = try #require(
            Bundle(for: TipJarTestsBundleAnchor.self)
                .url(forResource: "TipJarTests", withExtension: "storekit")
        )
        let session = try SKTestSession(contentsOf: url)
        session.resetToDefaultState()
        session.clearTransactions()
        session.disableDialogs = true
        return session
    }

    @Test func aDeferredTipIsFinishedOnceApproved() async throws {
        let session = try makeSession()
        session.askToBuyEnabled = true
        defer { session.clearTransactions() }

        let finished = Box<[String]>([])
        let store = TipJarStore(finish: { transaction in
            finished.mutate { $0.append(transaction.productID) }
            await transaction.finish()
        })
        await store.start()
        let product = try #require(store.products.first { $0.id == TipJarStore.ProductID.oneTimeMail })

        await store.purchase(product)
        let pending = try #require(session.allTransactions().first { $0.pendingAskToBuyConfirmation })
        #expect(finished.value.isEmpty)

        // Approved outside the purchase call, as a parent approving later is.
        try session.approveAskToBuyTransaction(identifier: pending.identifier)

        for _ in 0..<50 where finished.value.isEmpty {
            try await Task.sleep(for: .milliseconds(100))
        }
        #expect(finished.value == [TipJarStore.ProductID.oneTimeMail])
        withExtendedLifetime(store) {}
    }
}
