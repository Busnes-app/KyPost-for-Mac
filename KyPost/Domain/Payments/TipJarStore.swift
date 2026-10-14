//
//  TipJarStore.swift
//  KyPost
//
//  StoreKit 2 support for one-off tips. Product prices and availability come
//  from App Store Connect.
//

import Foundation
import Observation
import StoreKit

@MainActor
@Observable
final class TipJarStore {
    enum ProductID {
        static let oneTimeMail = "CupOJoe4Mail"
        static let all = [oneTimeMail]
    }

    private(set) var products: [Product] = []
    private(set) var isLoading = false
    private(set) var errorMessage: String?

    /// The one line the tip section shows under its buttons: the last error,
    /// or, once loading has finished with nothing to offer, why the list is
    /// empty. Never both — the views used to print an error twice.
    var statusMessage: String? {
        if let errorMessage { return errorMessage }
        if products.isEmpty && !isLoading {
            return String(localized: "Tips are not available right now.")
        }
        return nil
    }

    private var updatesTask: Task<Void, Never>?
    private let source: TipJarTransactionSource

    init(source: TipJarTransactionSource = .storeKit) {
        self.source = source
    }

    /// Listens for transactions that complete outside `purchase` — an
    /// Ask to Buy or SCA tip approved later returns `.pending` there — and
    /// finishes any left unfinished by an earlier run, so StoreKit stops
    /// redelivering them.
    func start() async {
        if updatesTask == nil {
            let updates = source.updates()
            updatesTask = Task { [weak self] in
                for await update in updates {
                    await self?.handle(update)
                }
            }
            for await update in source.unfinished() {
                await handle(update)
            }
        }
        await refresh()
    }

    func refresh() async {
        isLoading = true
        errorMessage = nil
        defer { isLoading = false }

        do {
            products = try await source.loadProducts(ProductID.all)
                .sorted { ProductID.all.firstIndex(of: $0.id)! < ProductID.all.firstIndex(of: $1.id)! }
        } catch {
            errorMessage = String(localized: "Tips are temporarily unavailable. Please try again later.")
        }
    }

    func purchase(_ product: Product) async {
        errorMessage = nil
        do {
            switch try await product.purchase() {
            case .success(let result): await handle(TipJarTransactionUpdate(result))
            case .userCancelled, .pending: break
            @unknown default: break
            }
        } catch {
            errorMessage = String(localized: "The tip could not be completed. Please try again.")
        }
    }

    /// Only a verified transaction is finished. An unverified one is left for
    /// StoreKit to redeliver rather than acknowledged as a delivered tip.
    private func handle(_ update: TipJarTransactionUpdate) async {
        guard update.isVerified else { return }
        await update.finish()
    }
}

/// What `TipJarStore` needs from one StoreKit transaction delivery.
nonisolated struct TipJarTransactionUpdate: Sendable {
    let productID: String
    let isVerified: Bool
    let finish: @Sendable () async -> Void
}

nonisolated extension TipJarTransactionUpdate {
    init(_ result: VerificationResult<Transaction>) {
        switch result {
        case .verified(let transaction):
            self.init(productID: transaction.productID, isVerified: true,
                      finish: { await transaction.finish() })
        case .unverified(let transaction, _):
            self.init(productID: transaction.productID, isVerified: false,
                      finish: { await transaction.finish() })
        }
    }
}

/// The StoreKit surface `TipJarStore` consumes. Production reads
/// `Product.products`, `Transaction.updates` and `Transaction.unfinished`; a
/// test feeds its own.
nonisolated struct TipJarTransactionSource: Sendable {
    let loadProducts: @Sendable ([String]) async throws -> [Product]
    let updates: @Sendable () -> AsyncStream<TipJarTransactionUpdate>
    let unfinished: @Sendable () -> AsyncStream<TipJarTransactionUpdate>

    static let storeKit = TipJarTransactionSource(
        loadProducts: { try await Product.products(for: $0) },
        updates: { mapped(Transaction.updates) },
        unfinished: { mapped(Transaction.unfinished) }
    )

    private static func mapped<S: AsyncSequence & Sendable>(_ sequence: S) -> AsyncStream<TipJarTransactionUpdate>
    where S.Element == VerificationResult<Transaction> {
        AsyncStream { continuation in
            let task = Task {
                do {
                    for try await result in sequence {
                        continuation.yield(TipJarTransactionUpdate(result))
                    }
                } catch {}
                continuation.finish()
            }
            continuation.onTermination = { _ in task.cancel() }
        }
    }
}
