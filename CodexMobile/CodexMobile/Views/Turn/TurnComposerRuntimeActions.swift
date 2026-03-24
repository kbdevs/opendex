// FILE: TurnComposerRuntimeActions.swift
// Purpose: Centralizes the composer runtime selection callbacks shared across nested views.
// Layer: View Helper
// Exports: TurnComposerRuntimeActions
// Depends on: CodexService

import Foundation

struct TurnComposerRuntimeActions {
    let selectModel: (String) -> Void
    let selectAutomaticReasoning: () -> Void
    let selectReasoning: (String) -> Void

    static func resolve(codex: CodexService) -> TurnComposerRuntimeActions {
        TurnComposerRuntimeActions(
            selectModel: codex.setSelectedModelId,
            selectAutomaticReasoning: { codex.setSelectedReasoningEffort(nil) },
            selectReasoning: { effort in codex.setSelectedReasoningEffort(effort) }
        )
    }
}
