// FILE: TurnViewAlertModifier.swift
// Purpose: Centralizes TurnView approval + git alerts so TurnView stays focused on orchestration.
// Layer: View Modifier
// Exports: turnViewAlerts
// Depends on: SwiftUI, CodexApprovalRequest, GitActionModels

import SwiftUI

private struct TurnViewAlertModifier: ViewModifier {
    @Binding var alertApprovalRequest: CodexApprovalRequest?
    @Binding var isShowingNothingToCommitAlert: Bool
    @Binding var gitSyncAlert: TurnGitSyncAlert?

    let onDeclineApproval: () -> Void
    let onApproveApproval: () -> Void
    let onConfirmGitSyncAction: (TurnGitSyncAlertAction) -> Void
    let onDismissGitSyncAlert: () -> Void

    func body(content: Content) -> some View {
        content
            .alert(
                "Approval request",
                isPresented: approvalAlertIsPresented,
                presenting: alertApprovalRequest
            ) { _ in
                Button("Decline", role: .destructive) {
                    alertApprovalRequest = nil
                    onDeclineApproval()
                }
                Button("Approve") {
                    alertApprovalRequest = nil
                    onApproveApproval()
                }
            } message: { request in
                Text(approvalAlertMessage(for: request))
            }
            .alert("Nothing to Commit", isPresented: $isShowingNothingToCommitAlert) {
                Button("OK", role: .cancel) {}
            } message: {
                Text("There are no changes to commit.")
            }
            .alert(
                gitSyncAlert?.title ?? "Git",
                isPresented: gitSyncAlertIsPresented,
                presenting: gitSyncAlert
            ) { alert in
                // Renders alert buttons from the shared model so new Git prompts do not add more switch cases here.
                ForEach(alert.buttons) { alertButton in
                    Button(alertButton.title, role: buttonRole(for: alertButton.role)) {
                        let action = alertButton.action
                        if action == .dismissOnly {
                            onDismissGitSyncAlert()
                        } else {
                            onConfirmGitSyncAction(action)
                        }
                    }
                }
            } message: { alert in
                Text(alert.message)
            }
    }

    private var approvalAlertIsPresented: Binding<Bool> {
        Binding(
            get: { alertApprovalRequest != nil },
            set: { isPresented in
                if !isPresented {
                    alertApprovalRequest = nil
                }
            }
        )
    }

    private var gitSyncAlertIsPresented: Binding<Bool> {
        Binding(
            get: { gitSyncAlert != nil },
            set: { isPresented in
                if !isPresented {
                    onDismissGitSyncAlert()
                }
            }
        )
    }

    private func approvalAlertMessage(for request: CodexApprovalRequest) -> String {
        var lines: [String] = []

        if let reason = request.reason?.trimmingCharacters(in: .whitespacesAndNewlines),
           !reason.isEmpty {
            lines.append(reason)
        }

        if let command = request.command?.trimmingCharacters(in: .whitespacesAndNewlines),
           !command.isEmpty {
            lines.append("Command: \(command)")
        }

        if lines.isEmpty {
            return "The desktop session is requesting permission to continue."
        }

        return lines.joined(separator: "\n\n")
    }

    private func buttonRole(for role: TurnGitSyncAlertButtonRole?) -> ButtonRole? {
        switch role {
        case .cancel:
            return .cancel
        case .destructive:
            return .destructive
        case nil:
            return nil
        }
    }
}

extension View {
    func turnViewAlerts(
        alertApprovalRequest: Binding<CodexApprovalRequest?>,
        isShowingNothingToCommitAlert: Binding<Bool>,
        gitSyncAlert: Binding<TurnGitSyncAlert?>,
        onDeclineApproval: @escaping () -> Void,
        onApproveApproval: @escaping () -> Void,
        onConfirmGitSyncAction: @escaping (TurnGitSyncAlertAction) -> Void,
        onDismissGitSyncAlert: @escaping () -> Void
    ) -> some View {
        modifier(
            TurnViewAlertModifier(
                alertApprovalRequest: alertApprovalRequest,
                isShowingNothingToCommitAlert: isShowingNothingToCommitAlert,
                gitSyncAlert: gitSyncAlert,
                onDeclineApproval: onDeclineApproval,
                onApproveApproval: onApproveApproval,
                onConfirmGitSyncAction: onConfirmGitSyncAction,
                onDismissGitSyncAlert: onDismissGitSyncAlert
            )
        )
    }
}
