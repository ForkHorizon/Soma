import Foundation

extension SomaViewModel {
    func hydratePacketHistoryIfNeeded() {
        guard !hasHydratedPacketHistory else { return }
        hasHydratedPacketHistory = true
        packetHistory = decodePacketHistory()
    }

    @discardableResult
    func recordPacketRun(prompt: String, bundle: GatherBundle) -> String {
        hydratePacketHistoryIfNeeded()

        let root = bundle.project_root ?? selectedProjectRoot
        let item = PacketHistoryItem(
            id: UUID().uuidString,
            createdAt: ISO8601DateFormatter().string(from: Date()),
            projectRoot: root,
            projectName: root.isEmpty ? "No project" : (root as NSString).lastPathComponent,
            prompt: prompt,
            status: bundle.statusLabel,
            packetMode: bundle.packet_mode,
            estimatedTokens: bundle.estimated_tokens,
            evidencePaths: bundle.evidence_items?.compactMap(\.path) ?? bundle.audit?.selected_evidence?.compactMap(\.path) ?? [],
            evidenceSummaries: evidenceSummaries(for: bundle),
            warnings: packetWarnings(for: bundle),
            auditRunID: bundle.audit?.run_id,
            usefulness: nil,
            whyNotUseful: nil,
            missedFiles: [],
            agentUsedSoma: false,
            toolCallCount: 0,
            finalOutcome: "unknown"
        )

        packetHistory.insert(item, at: 0)
        if packetHistory.count > 80 {
            packetHistory = Array(packetHistory.prefix(80))
        }
        persistPacketHistory()
        return item.id
    }

    func markPacketUsefulness(_ id: String, useful: Bool) {
        markPacketFeedback(
            id,
            useful: useful,
            whyNotUseful: nil,
            missedFilesText: nil,
            finalOutcome: useful ? "useful" : "failed",
            agentUsedSoma: nil
        )
    }

    func markPacketFeedback(
        _ id: String,
        useful: Bool?,
        whyNotUseful: String?,
        missedFilesText: String?,
        finalOutcome: String?,
        agentUsedSoma: Bool?
    ) {
        hydratePacketHistoryIfNeeded()
        guard let index = packetHistory.firstIndex(where: { $0.id == id }) else { return }
        if let useful {
            packetHistory[index].usefulness = useful ? "useful" : "not_useful"
        }
        if let whyNotUseful {
            let trimmed = whyNotUseful.trimmingCharacters(in: .whitespacesAndNewlines)
            packetHistory[index].whyNotUseful = trimmed.isEmpty ? nil : trimmed
        }
        if let missedFilesText {
            packetHistory[index].missedFiles = parseMissedFiles(missedFilesText)
        }
        if let finalOutcome, ["useful", "partial", "failed", "unknown"].contains(finalOutcome) {
            packetHistory[index].finalOutcome = finalOutcome
        } else if let useful {
            packetHistory[index].finalOutcome = useful ? "useful" : "failed"
        }
        if let agentUsedSoma {
            packetHistory[index].agentUsedSoma = agentUsedSoma || packetHistory[index].toolCallCount > 0
        }
        persistPacketHistory()
    }

    func refreshPacketLiveToolCounts() {
        hydratePacketHistoryIfNeeded()
        var changed = false
        for index in packetHistory.indices {
            let count = liveToolCallCount(for: packetHistory[index])
            if packetHistory[index].toolCallCount != count || packetHistory[index].agentUsedSoma != (packetHistory[index].agentUsedSoma || count > 0) {
                packetHistory[index].toolCallCount = count
                if count > 0 {
                    packetHistory[index].agentUsedSoma = true
                }
                changed = true
            }
        }
        if changed {
            persistPacketHistory()
        }
    }

    func liveToolCallCount(for packet: PacketHistoryItem) -> Int {
        guard let runID = packet.auditRunID, !runID.isEmpty else {
            return packet.toolCallCount
        }
        let count = logEntries.filter { entry in
            entry.run_id == runID &&
            entry.event == "tool_call" &&
            (entry.tool?.hasPrefix("soma_") ?? false)
        }.count
        return max(packet.toolCallCount, count)
    }

    func packetsForSelectedProject() -> [PacketHistoryItem] {
        guard !selectedProjectRoot.isEmpty else { return packetHistory }
        return packetHistory.filter { $0.projectRoot == selectedProjectRoot }
    }

    func latestPacketFeedbackLabel() -> String {
        guard let latest = packetHistory.first else { return "No packet yet" }
        switch latest.usefulness {
        case "useful": return "Last packet useful"
        case "not_useful": return "Last packet not useful"
        default: return "Last packet unreviewed"
        }
    }

    func latestPacketFeedbackTone() -> SomaStatusTone {
        guard let latest = packetHistory.first else { return .neutral }
        switch latest.usefulness {
        case "useful": return .good
        case "not_useful": return .warning
        default: return .neutral
        }
    }

    private func decodePacketHistory() -> [PacketHistoryItem] {
        let raw = UserDefaults.standard.string(forKey: packetHistoryKey) ?? "[]"
        guard let data = raw.data(using: .utf8),
              let decoded = try? JSONDecoder().decode([PacketHistoryItem].self, from: data) else {
            return []
        }
        return decoded
    }

    private func persistPacketHistory() {
        guard let data = try? JSONEncoder().encode(packetHistory),
              let json = String(data: data, encoding: .utf8) else { return }
        UserDefaults.standard.set(json, forKey: packetHistoryKey)
    }

    private func parseMissedFiles(_ raw: String) -> [String] {
        let separators = CharacterSet(charactersIn: "\n,;")
        let values = raw.components(separatedBy: separators)
            .map { $0.trimmingCharacters(in: .whitespacesAndNewlines) }
            .filter { !$0.isEmpty }
        return Array(NSOrderedSet(array: values)) as? [String] ?? values
    }

    private func packetWarnings(for bundle: GatherBundle) -> [String] {
        var warnings: [String] = []
        if let quality = bundle.audit?.evidence_quality, quality.status == "degraded" {
            warnings.append("Evidence quality is degraded.")
        }
        warnings.append(contentsOf: bundle.audit?.evidence_quality?.warnings ?? [])
        warnings.append(contentsOf: bundle.audit?.missing_evidence?.quality_warnings ?? [])
        warnings.append(contentsOf: bundle.collection_plan_warnings ?? [])
        warnings.append(contentsOf: bundle.collection_plan?.warnings ?? [])
        warnings.append(contentsOf: bundle.estimated_context_reduction?.warnings ?? [])
        if let graphValue = bundle.omitted_context?["graph_warnings"] {
            warnings.append(graphValue.displayValue)
        }
        return Array(NSOrderedSet(array: warnings.filter { !$0.isEmpty })) as? [String] ?? warnings
    }

    private func evidenceSummaries(for bundle: GatherBundle) -> [String] {
        let items = bundle.evidence_items ?? []
        return items.compactMap { item in
            guard let path = item.path else { return nil }
            let name = (path as NSString).lastPathComponent
            let reason = item.reason?.trimmingCharacters(in: .whitespacesAndNewlines)
            if let reason, !reason.isEmpty {
                return "\(name): \(reason)"
            }
            return "\(name): selected as task evidence"
        }
    }
}

private extension GatherBundle {
    var statusLabel: String {
        if let error, !error.isEmpty { return "failed" }
        if let status = audit?.evidence_quality?.status, !status.isEmpty { return status }
        if let status = audit?.missing_evidence?.status, !status.isEmpty { return status }
        if let status = mode, status == "gather" { return "ok" }
        return "ok"
    }
}
