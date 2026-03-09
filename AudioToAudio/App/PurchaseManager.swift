import Foundation
import StoreKit

struct PurchasePlanOption: Identifiable, Hashable {
    let id: String
    let title: String
    let subtitle: String
    let priceText: String
    let isAvailable: Bool
}

private struct ProductLookupResult {
    let byID: [String: Product]
    let missingProductIDs: [String]
    let storeKitErrorSummary: String?
}

enum PurchaseManagerError: LocalizedError {
    case productUnavailable(
        productID: String,
        missingProductIDs: [String],
        storeKitErrorSummary: String?
    )
    case purchaseFailed(productID: String, storeKitErrorSummary: String)
    case transactionUnverified(productID: String, verificationErrorSummary: String?)
    case pending

    var errorDescription: String? {
        switch self {
        case let .productUnavailable(productID, missingProductIDs, storeKitErrorSummary):
            var details: [String] = [
                L10n.tr("This purchase option is currently unavailable."),
                "Product ID: \(productID)"
            ]
            if !missingProductIDs.isEmpty {
                details.append("Missing from App Store response: \(missingProductIDs.joined(separator: ", "))")
            }
            if let storeKitErrorSummary, !storeKitErrorSummary.isEmpty {
                details.append("StoreKit request failed: \(storeKitErrorSummary)")
            }
            details.append("Check App Store Connect status (Ready for Sale), storefront availability, and Paid Applications agreement.")
            return details.joined(separator: "\n")
        case let .purchaseFailed(productID, storeKitErrorSummary):
            return """
            Purchase failed.
            Product ID: \(productID)
            StoreKit purchase error: \(storeKitErrorSummary)
            """
        case let .transactionUnverified(productID, verificationErrorSummary):
            var details: [String] = [
                "Purchase succeeded but the transaction could not be verified.",
                "Product ID: \(productID)"
            ]
            if let verificationErrorSummary, !verificationErrorSummary.isEmpty {
                details.append("Verification error: \(verificationErrorSummary)")
            }
            return details.joined(separator: "\n")
        case .pending:
            return L10n.tr("Purchase is pending approval.")
        }
    }
}

final class PurchaseManager {
    enum PlanKind {
        case weekly
        case monthly
        case lifetime
        case unknown
    }

    static let weeklyProductID = "org.icorpaudio.audiotoaudio.v2.weekly"
    static let monthlyProductID = "org.icorpaudio.audiotoaudio.v2.monthly"
    static let lifetimeProductID = "org.icorpaudio.audiotoaudio.lifetime"

    // Backward-compatibility with legacy identifiers used in the reference app.
    static let legacyWeeklyProductID = "org.icorpvideo.compress.weekly"
    static let legacyMonthlyProductID = "org.icorpvideo.compress.monthly"
    static let legacyLifetimeProductID = "org.icorpvideo.compress.lifetime"

    static let productOrder = [
        weeklyProductID,
        monthlyProductID,
        lifetimeProductID
    ]

    static let legacyProductOrder = [
        legacyWeeklyProductID,
        legacyMonthlyProductID,
        legacyLifetimeProductID
    ]

    static let allKnownProductIDs = productOrder + legacyProductOrder

    private static let fallbackPriceByProductID: [String: String] = [
        weeklyProductID: "$0.99",
        monthlyProductID: "$2.99",
        lifetimeProductID: "$29.99",
        legacyWeeklyProductID: "$0.99",
        legacyMonthlyProductID: "$2.99",
        legacyLifetimeProductID: "$29.99"
    ]

    private static let simulatorEntitlementKey = "debug_simulator_premium_entitlement"

    private let defaults = UserDefaults.standard

    func loadPlanOptions() async -> [PurchasePlanOption] {
        let lookupResult = await loadProductsByID(for: Self.allKnownProductIDs)
        let byID = lookupResult.byID
        let resolvedOrder = resolvedProductOrder(byID: byID)

        if canUseSimulatorFallback, byID.isEmpty {
            return Self.productOrder.map { id in
                PurchasePlanOption(
                    id: id,
                    title: title(for: id),
                    subtitle: subtitle(for: id),
                    priceText: fallbackPrice(for: id),
                    isAvailable: true
                )
            }
        }

        return resolvedOrder.map { id in
            if let product = byID[id] {
                return PurchasePlanOption(
                    id: id,
                    title: title(for: id),
                    subtitle: subtitle(for: id),
                    priceText: product.displayPrice,
                    isAvailable: true
                )
            }

            return PurchasePlanOption(
                id: id,
                title: title(for: id),
                subtitle: subtitle(for: id),
                priceText: fallbackPrice(for: id),
                isAvailable: false
            )
        }
    }

    func hasActiveEntitlement() async -> Bool {
        if canUseSimulatorFallback,
           defaults.bool(forKey: Self.simulatorEntitlementKey)
        {
            return true
        }

        for await verification in Transaction.currentEntitlements {
            guard case .verified(let transaction) = verification else {
                continue
            }
            guard Self.allKnownProductIDs.contains(transaction.productID) else {
                continue
            }
            guard transaction.revocationDate == nil else {
                continue
            }
            if let expirationDate = transaction.expirationDate,
               expirationDate < Date()
            {
                continue
            }
            return true
        }

        return false
    }

    func purchase(productID: String) async throws -> Bool {
        let lookupResult = await loadProductsByID(for: [productID])
        guard let product = lookupResult.byID[productID] else {
            if canUseSimulatorFallback {
                defaults.set(true, forKey: Self.simulatorEntitlementKey)
                return true
            }

            throw PurchaseManagerError.productUnavailable(
                productID: productID,
                missingProductIDs: lookupResult.missingProductIDs,
                storeKitErrorSummary: lookupResult.storeKitErrorSummary
            )
        }

        do {
            let result = try await product.purchase()
            switch result {
            case .success(let verification):
                switch verification {
                case .verified(let transaction):
                    await transaction.finish()
                    return true
                case .unverified(_, let verificationError):
                    throw PurchaseManagerError.transactionUnverified(
                        productID: productID,
                        verificationErrorSummary: verificationError.localizedDescription
                    )
                }
            case .pending:
                throw PurchaseManagerError.pending
            case .userCancelled:
                return false
            @unknown default:
                return false
            }
        } catch let error as PurchaseManagerError {
            throw error
        } catch {
            throw PurchaseManagerError.purchaseFailed(
                productID: productID,
                storeKitErrorSummary: describeStoreKitError(error)
            )
        }
    }

    func restorePurchases() async throws -> Bool {
        if canUseSimulatorFallback {
            return defaults.bool(forKey: Self.simulatorEntitlementKey)
        }

        try await AppStore.sync()
        return await hasActiveEntitlement()
    }

    private func loadProductsByID(for requestedIDs: [String]) async -> ProductLookupResult {
        do {
            let products = try await Product.products(for: requestedIDs)
            let byID = Dictionary(uniqueKeysWithValues: products.map { ($0.id, $0) })
            let missingProductIDs = requestedIDs.filter { byID[$0] == nil }
            return ProductLookupResult(
                byID: byID,
                missingProductIDs: missingProductIDs,
                storeKitErrorSummary: nil
            )
        } catch {
            return ProductLookupResult(
                byID: [:],
                missingProductIDs: requestedIDs,
                storeKitErrorSummary: describeStoreKitError(error)
            )
        }
    }

    private func title(for productID: String) -> String {
        switch Self.planKind(for: productID) {
        case .weekly:
            return L10n.tr("Weekly")
        case .monthly:
            return L10n.tr("Monthly")
        case .lifetime:
            return L10n.tr("Forever")
        case .unknown:
            return L10n.tr("Premium")
        }
    }

    private func subtitle(for productID: String) -> String {
        switch Self.planKind(for: productID) {
        case .weekly:
            return L10n.tr("Unlimited usage, billed weekly")
        case .monthly:
            return L10n.tr("Unlimited usage, billed monthly")
        case .lifetime:
            return L10n.tr("Unlimited usage forever")
        case .unknown:
            return L10n.tr("Unlimited usage")
        }
    }

    private func fallbackPrice(for productID: String) -> String {
        Self.fallbackPriceByProductID[productID] ?? "$0.00"
    }

    private func describeStoreKitError(_ error: Error) -> String {
        let nsError = error as NSError
        let description = nsError.localizedDescription.trimmingCharacters(in: .whitespacesAndNewlines)
        if description.isEmpty {
            return "\(nsError.domain) (\(nsError.code))"
        }
        return "\(nsError.domain) (\(nsError.code)): \(description)"
    }

    private func resolvedProductOrder(byID: [String: Product]) -> [String] {
        if Self.productOrder.contains(where: { byID[$0] != nil }) {
            return Self.productOrder
        }

        if Self.legacyProductOrder.contains(where: { byID[$0] != nil }) {
            return Self.legacyProductOrder
        }

        return Self.productOrder
    }

    static func planKind(for productID: String) -> PlanKind {
        if productID == weeklyProductID || productID == legacyWeeklyProductID || productID.hasSuffix(".weekly") {
            return .weekly
        }
        if productID == monthlyProductID || productID == legacyMonthlyProductID || productID.hasSuffix(".monthly") {
            return .monthly
        }
        if productID == lifetimeProductID || productID == legacyLifetimeProductID || productID.hasSuffix(".lifetime") {
            return .lifetime
        }
        return .unknown
    }

    private var canUseSimulatorFallback: Bool {
#if targetEnvironment(simulator)
        true
#else
        false
#endif
    }
}
