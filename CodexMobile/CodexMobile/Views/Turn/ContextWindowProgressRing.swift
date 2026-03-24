// FILE: ContextWindowProgressRing.swift
// Purpose: Compact button that opens the rate-limit status popover.
// Layer: View Component
// Exports: ContextWindowProgressRing
// Depends on: SwiftUI, HapticFeedback, UsageStatusSummaryContent

import SwiftUI

struct ContextWindowProgressRing: View {
    let rateLimitBuckets: [CodexRateLimitBucket]
    let isLoadingRateLimits: Bool
    let rateLimitsErrorMessage: String?
    let shouldAutoRefreshStatus: Bool
    let onRefreshStatus: (() async -> Void)?
    @State private var isShowingPopover = false
    @State private var isRefreshing = false

    private let ringSize: CGFloat = 18
    private let lineWidth: CGFloat = 2.25
    private let tapTargetSize: CGFloat = 36

    var body: some View {
        Button {
            HapticFeedback.shared.triggerImpactFeedback(style: .light)
            isShowingPopover = true
        } label: {
            ZStack {
                Circle()
                    .stroke(Color(.systemGray5), lineWidth: lineWidth)

                Image(systemName: "speedometer")
                    .font(AppFont.system(size: 9, weight: .semibold))
                    .foregroundStyle(Color(.secondaryLabel))
            }
            .frame(width: ringSize, height: ringSize)
            .frame(width: tapTargetSize, height: tapTargetSize)
            .adaptiveGlass(.regular, in: Circle())
            .contentShape(Circle())
        }
        .buttonStyle(.plain)
        .accessibilityLabel("Status")
        .accessibilityValue(statusAccessibilityValue)
        .popover(isPresented: $isShowingPopover) {
            popoverContent
                .presentationCompactAdaptation(.popover)
        }
        .onChange(of: isShowingPopover) { _, isPresented in
            guard isPresented, shouldAutoRefreshStatus else { return }
            refreshStatus(triggerHaptic: false)
        }
    }

    private var popoverContent: some View {
        UsageStatusSummaryContent(
            rateLimitBuckets: rateLimitBuckets,
            isLoadingRateLimits: isLoadingRateLimits,
            rateLimitsErrorMessage: rateLimitsErrorMessage,
            refreshControl: onRefreshStatus.map { _ in
                UsageStatusRefreshControl(
                    title: "Refresh",
                    isRefreshing: isRefreshing,
                    action: { refreshStatus() }
                )
            }
        )
        .padding()
        .frame(minWidth: 260)
    }

    private var statusAccessibilityValue: String {
        if isLoadingRateLimits || isRefreshing {
            return "Refreshing"
        }
        if let rateLimitsErrorMessage, !rateLimitsErrorMessage.isEmpty {
            return rateLimitsErrorMessage
        }
        return rateLimitBuckets.isEmpty ? "Rate limits unavailable" : "Rate limits available"
    }

    // Refreshes account-level status for the compact status popover.
    private func refreshStatus(triggerHaptic: Bool = true) {
        guard !isRefreshing, let onRefreshStatus else { return }
        if triggerHaptic {
            HapticFeedback.shared.triggerImpactFeedback(style: .light)
        }
        isRefreshing = true

        Task {
            await onRefreshStatus()
            await MainActor.run {
                isRefreshing = false
            }
        }
    }
}
