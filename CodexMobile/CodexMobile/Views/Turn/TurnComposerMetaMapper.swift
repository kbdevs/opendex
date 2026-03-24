// FILE: TurnComposerMetaMapper.swift
// Purpose: Centralizes model/reasoning label mapping and ordering for TurnView composer menus.
// Layer: View Helper
// Exports: TurnComposerMetaMapper, TurnComposerReasoningDisplayOption
// Depends on: CodexModelOption

import Foundation

// Keeps TurnView lightweight by isolating menu formatting/sorting rules.
enum TurnComposerMetaMapper {
    // ─── Model Mapping ────────────────────────────────────────────────

    // Returns models using backend-provided display names rather than legacy Codex-specific labels.
    static func orderedModels(from models: [CodexModelOption]) -> [CodexModelOption] {
        models.sorted { lhs, rhs in
            let lhsTitle = modelTitle(for: lhs)
            let rhsTitle = modelTitle(for: rhs)
            let comparison = lhsTitle.localizedCaseInsensitiveCompare(rhsTitle)
            if comparison == .orderedSame {
                return lhs.model.localizedCaseInsensitiveCompare(rhs.model) == .orderedAscending
            }
            return comparison == .orderedAscending
        }
    }

    // Prefer backend-provided display names so OpenCode-specific models stay accurate.
    static func modelTitle(for model: CodexModelOption) -> String {
        let normalizedDisplayName = model.displayName.trimmingCharacters(in: .whitespacesAndNewlines)
        if !normalizedDisplayName.isEmpty {
            return normalizedDisplayName
        }

        let normalizedModel = model.model.trimmingCharacters(in: .whitespacesAndNewlines)
        if normalizedModel.isEmpty {
            return "Runtime default"
        }

        return normalizedModel
    }

    // ─── Reasoning Mapping ───────────────────────────────────────────

    // Converts server effort values to user-facing labels and sorts them by level.
    static func reasoningDisplayOptions(from efforts: [String]) -> [TurnComposerReasoningDisplayOption] {
        efforts
            .map { effort in
                TurnComposerReasoningDisplayOption(
                    effort: effort,
                    title: reasoningTitle(for: effort)
                )
            }
            .sorted { lhs, rhs in
                if lhs.rank == rhs.rank {
                    return lhs.title > rhs.title
                }
                return lhs.rank > rhs.rank
            }
    }

    // Maps raw effort values to user-facing labels.
    static func reasoningTitle(for effort: String) -> String {
        let normalized = effort
            .trimmingCharacters(in: .whitespacesAndNewlines)
            .lowercased()

        switch normalized {
        case "minimal", "low":
            return "Low"
        case "medium":
            return "Medium"
        case "high":
            return "High"
        case "xhigh", "extra_high", "extra-high", "very_high", "very-high":
            return "Extra High"
        default:
            return normalized.split(separator: "_")
                .map { $0.capitalized }
                .joined(separator: " ")
        }
    }
}

struct TurnComposerReasoningDisplayOption: Identifiable {
    let effort: String
    let title: String

    var id: String { effort }

    // Provides deterministic ordering for reasoning rows.
    var rank: Int {
        switch title {
        case "Low":
            return 0
        case "Medium":
            return 1
        case "High":
            return 2
        case "Exceptional":
            return 3
        default:
            return 4
        }
    }
}
