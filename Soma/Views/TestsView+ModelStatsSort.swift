import SwiftUI
import AppKit
import Foundation

enum TestModelStatsSortColumn {
    case model
    case attempts
    case quality
    case ok
    case problems
    case clean
    case runtime
    case last

    var defaultAscending: Bool {
        switch self {
        case .model, .problems, .runtime:
            return true
        case .attempts, .quality, .ok, .clean, .last:
            return false
        }
    }
}

struct TestModelStatsSort: Equatable {
    let column: TestModelStatsSortColumn
    let ascending: Bool
}

extension TestsView {
    var sortedTranslationModelStats: [TestModelRoleStats] {
        sortedModelStatsRows(modelStats?.translationModels ?? [], sort: translationModelStatsSort)
    }


    var sortedImproverModelStats: [TestModelRoleStats] {
        sortedModelStatsRows(modelStats?.improverModels ?? [], sort: improverModelStatsSort)
    }


    func toggleModelStatsSort(_ column: TestModelStatsSortColumn, sort: Binding<TestModelStatsSort?>) {
        if let current = sort.wrappedValue, current.column == column {
            sort.wrappedValue = TestModelStatsSort(column: column, ascending: !current.ascending)
        } else {
            sort.wrappedValue = TestModelStatsSort(column: column, ascending: column.defaultAscending)
        }
    }


    func sortedModelStatsRows(_ rows: [TestModelRoleStats], sort: TestModelStatsSort?) -> [TestModelRoleStats] {
        guard let sort else { return rows }
        return rows.sorted { lhs, rhs in
            compareModelStatsRows(lhs, rhs, sort: sort)
        }
    }


    func compareModelStatsRows(_ lhs: TestModelRoleStats, _ rhs: TestModelRoleStats, sort: TestModelStatsSort) -> Bool {
        switch sort.column {
        case .model:
            return compareModelStatsStrings(lhs.model, rhs.model, ascending: sort.ascending, providerTie: (lhs.provider, rhs.provider))
        case .attempts:
            return compareModelStatsInts(lhs.attempts, rhs.attempts, lhs, rhs, ascending: sort.ascending)
        case .quality:
            return compareModelStatsDoubles(lhs.qualityScore, rhs.qualityScore, lhs, rhs, ascending: sort.ascending)
        case .ok:
            return compareModelStatsDoubles(modelStatsOKRate(lhs), modelStatsOKRate(rhs), lhs, rhs, ascending: sort.ascending)
        case .problems:
            return compareModelStatsInts(modelStatsProblemCount(lhs), modelStatsProblemCount(rhs), lhs, rhs, ascending: sort.ascending)
        case .clean:
            return compareModelStatsDoubles(modelStatsCleanRate(lhs), modelStatsCleanRate(rhs), lhs, rhs, ascending: sort.ascending)
        case .runtime:
            return compareModelStatsDoubles(lhs.avgSeconds, rhs.avgSeconds, lhs, rhs, ascending: sort.ascending)
        case .last:
            return compareModelStatsOptionalStrings(lhs.lastTestedAt, rhs.lastTestedAt, lhs, rhs, ascending: sort.ascending)
        }
    }


    func compareModelStatsInts(
        _ lhsValue: Int,
        _ rhsValue: Int,
        _ lhs: TestModelRoleStats,
        _ rhs: TestModelRoleStats,
        ascending: Bool
    ) -> Bool {
        if lhsValue != rhsValue {
            return ascending ? lhsValue < rhsValue : lhsValue > rhsValue
        }
        return modelStatsNameTieBreak(lhs, rhs)
    }


    func compareModelStatsDoubles(
        _ lhsValue: Double?,
        _ rhsValue: Double?,
        _ lhs: TestModelRoleStats,
        _ rhs: TestModelRoleStats,
        ascending: Bool
    ) -> Bool {
        let lhsSortValue = lhsValue ?? (ascending ? Double.greatestFiniteMagnitude : -Double.greatestFiniteMagnitude)
        let rhsSortValue = rhsValue ?? (ascending ? Double.greatestFiniteMagnitude : -Double.greatestFiniteMagnitude)
        if lhsSortValue != rhsSortValue {
            return ascending ? lhsSortValue < rhsSortValue : lhsSortValue > rhsSortValue
        }
        return modelStatsNameTieBreak(lhs, rhs)
    }


    func compareModelStatsOptionalStrings(
        _ lhsValue: String?,
        _ rhsValue: String?,
        _ lhs: TestModelRoleStats,
        _ rhs: TestModelRoleStats,
        ascending: Bool
    ) -> Bool {
        let emptyHighValue = String(repeating: "~", count: 64)
        let lhsSortValue = lhsValue ?? (ascending ? emptyHighValue : "")
        let rhsSortValue = rhsValue ?? (ascending ? emptyHighValue : "")
        let comparison = lhsSortValue.localizedStandardCompare(rhsSortValue)
        if comparison != .orderedSame {
            return ascending ? comparison == .orderedAscending : comparison == .orderedDescending
        }
        return modelStatsNameTieBreak(lhs, rhs)
    }


    func compareModelStatsStrings(
        _ lhsValue: String,
        _ rhsValue: String,
        ascending: Bool,
        providerTie: (String, String)
    ) -> Bool {
        let comparison = lhsValue.localizedStandardCompare(rhsValue)
        if comparison != .orderedSame {
            return ascending ? comparison == .orderedAscending : comparison == .orderedDescending
        }
        return providerTie.0.localizedStandardCompare(providerTie.1) == .orderedAscending
    }


    func modelStatsNameTieBreak(_ lhs: TestModelRoleStats, _ rhs: TestModelRoleStats) -> Bool {
        let modelComparison = lhs.model.localizedStandardCompare(rhs.model)
        if modelComparison != .orderedSame {
            return modelComparison == .orderedAscending
        }
        return lhs.provider.localizedStandardCompare(rhs.provider) == .orderedAscending
    }


    func modelStatsOKRate(_ row: TestModelRoleStats) -> Double? {
        row.attempts > 0 ? Double(row.confidenceCount) / Double(row.attempts) : nil
    }


    func modelStatsProblemCount(_ row: TestModelRoleStats) -> Int {
        row.problemCount ?? row.worstCases.filter { item in
            item.confidenceFailed == true || item.status != "ok"
        }.count
    }


    func modelStatsCleanRate(_ row: TestModelRoleStats) -> Double? {
        guard row.attempts > 0 else { return nil }
        let cleanCount = max(0, row.attempts - modelStatsProblemCount(row))
        return Double(cleanCount) / Double(row.attempts)
    }


    func modelStatsCleanLabel(_ row: TestModelRoleStats) -> String {
        guard let rate = modelStatsCleanRate(row) else { return "n/a" }
        return formatPercent(rate)
    }


    func modelStatsWorstEffectiveScore(_ row: TestModelRoleStats) -> Double? {
        row.worstEffectiveScore ?? row.worstCases.compactMap { $0.effectiveScore ?? $0.confidence }.min()
    }
}
