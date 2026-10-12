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

    func start() async {
        await refresh()
    }

    func refresh() async {
        isLoading = true
        errorMessage = nil
        defer { isLoading = false }

        do {
            products = try await Product.products(for: ProductID.all)
                .sorted { ProductID.all.firstIndex(of: $0.id)! < ProductID.all.firstIndex(of: $1.id)! }
        } catch {
            errorMessage = "Support options are temporarily unavailable. Please try again later."
        }
    }

    func purchase(_ product: Product) async {
        errorMessage = nil
        do {
            switch try await product.purchase() {
            case .success(let result): await handle(result)
            case .userCancelled, .pending: break
            @unknown default: break
            }
        } catch {
            errorMessage = "The purchase could not be completed. Please try again."
        }
    }

    private func handle(_ result: VerificationResult<Transaction>) async {
        guard case .verified(let transaction) = result else { return }
        await transaction.finish()
    }
}
