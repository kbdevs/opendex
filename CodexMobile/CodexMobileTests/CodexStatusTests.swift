// FILE: CodexStatusTests.swift
// Purpose: Verifies `/status` data loading and rate-limit update decoding.
// Layer: Unit Test
// Exports: CodexStatusTests
// Depends on: XCTest, CodexMobile

import XCTest
@testable import CodexMobile

@MainActor
final class CodexStatusTests: XCTestCase {
    private static var retainedServices: [CodexService] = []

    func testRefreshRateLimitsDecodesBucketsFromReadResponse() async {
        let service = makeService()
        service.isConnected = true

        service.requestTransportOverride = { method, params in
            XCTAssertEqual(method, "account/rateLimits/read")
            XCTAssertEqual(params, .null)
            return RPCMessage(
                id: .string(UUID().uuidString),
                result: .object([
                    "rateLimitsByLimitId": .object([
                        "codex_5h": .object([
                            "limitId": .string("codex_5h"),
                            "limitName": .string("codex_5h"),
                            "primary": .object([
                                "usedPercent": .integer(3),
                                "windowDurationMins": .integer(300),
                                "resetsAt": .integer(1_742_000_000),
                            ]),
                        ]),
                        "codex_7d": .object([
                            "limitId": .string("codex_7d"),
                            "primary": .object([
                                "usedPercent": .integer(6),
                                "windowDurationMins": .integer(10_080),
                                "resetsAt": .integer(1_742_500_000),
                            ]),
                        ]),
                    ]),
                ]),
                includeJSONRPC: false
            )
        }

        await service.refreshRateLimits()

        XCTAssertEqual(service.rateLimitBuckets.map(\.limitId), ["codex_5h", "codex_7d"])
        XCTAssertEqual(service.rateLimitBuckets.first?.displayLabel, "5h")
        XCTAssertEqual(service.rateLimitBuckets.first?.primary?.remainingPercent, 97)
        XCTAssertNil(service.rateLimitsErrorMessage)
        XCTAssertFalse(service.isLoadingRateLimits)
    }

    func testRefreshRateLimitsRetriesWithEmptyObjectAfterInvalidNullParams() async {
        let service = makeService()
        service.isConnected = true
        var observedParams: [JSONValue?] = []

        service.requestTransportOverride = { method, params in
            XCTAssertEqual(method, "account/rateLimits/read")
            observedParams.append(params)

            if observedParams.count == 1 {
                throw CodexServiceError.rpcError(
                    RPCError(code: -32602, message: "invalid type: null, expected map")
                )
            }

            return RPCMessage(
                id: .string(UUID().uuidString),
                result: .object([
                    "rateLimitsByLimitId": .object([
                        "codex_5h": .object([
                            "primary": .object([
                                "usedPercent": .integer(20),
                                "windowDurationMins": .integer(300),
                            ]),
                        ]),
                    ]),
                ]),
                includeJSONRPC: false
            )
        }

        await service.refreshRateLimits()

        XCTAssertEqual(observedParams.count, 2)
        XCTAssertEqual(observedParams[0], .null)
        XCTAssertEqual(observedParams[1], .object([:]))
        XCTAssertEqual(service.rateLimitBuckets.map(\.limitId), ["codex_5h"])
        XCTAssertNil(service.rateLimitsErrorMessage)
    }

    func testIncomingRateLimitUpdateRefreshesCachedBuckets() {
        let service = makeService()

        service.handleIncomingRPCMessage(
            RPCMessage(
                method: "account/rateLimits/updated",
                params: .object([
                    "rateLimits": .object([
                        "limitId": .string("codex"),
                        "limitName": .string("Codex"),
                        "primary": .object([
                            "usedPercent": .integer(42),
                            "windowDurationMins": .integer(60),
                            "resetsAt": .integer(1_742_100_000),
                        ]),
                    ]),
                ])
            )
        )

        XCTAssertEqual(service.rateLimitBuckets.count, 1)
        XCTAssertEqual(service.rateLimitBuckets.first?.limitId, "primary")
        XCTAssertEqual(service.rateLimitBuckets.first?.primary?.remainingPercent, 58)
    }

    func testIncomingRateLimitUpdateDecodesSnakeCaseWindowKeys() {
        let service = makeService()

        service.handleIncomingRPCMessage(
            RPCMessage(
                method: "account/rateLimits/updated",
                params: .object([
                    "rateLimitsByLimitId": .object([
                        "codex_weekly": .object([
                            "limit_id": .string("codex_weekly"),
                            "secondary_window": .object([
                                "used_percent": .integer(12),
                                "window_duration_mins": .integer(10_080),
                            ]),
                        ]),
                    ]),
                ])
            )
        )

        XCTAssertEqual(service.rateLimitBuckets.count, 1)
        XCTAssertEqual(service.rateLimitBuckets.first?.limitId, "codex_weekly")
        XCTAssertEqual(service.rateLimitBuckets.first?.secondary?.remainingPercent, 88)
    }

    func testRateLimitWeeklyWindowUsesWeeklyDisplayLabel() {
        let bucket = CodexRateLimitBucket(
            limitId: "codex_weekly",
            limitName: nil,
            primary: CodexRateLimitWindow(
                usedPercent: 12,
                windowDurationMins: 10_080,
                resetsAt: nil
            ),
            secondary: nil
        )

        XCTAssertEqual(bucket.displayLabel, "Weekly")
    }

    func testRateLimitBucketDisplayRowsSplitPrimaryAndSecondaryWindows() {
        let bucket = CodexRateLimitBucket(
            limitId: "codex",
            limitName: "Codex",
            primary: CodexRateLimitWindow(
                usedPercent: 5,
                windowDurationMins: 300,
                resetsAt: nil
            ),
            secondary: CodexRateLimitWindow(
                usedPercent: 83,
                windowDurationMins: 10_080,
                resetsAt: nil
            )
        )

        XCTAssertEqual(bucket.displayRows.map(\.label), ["5h", "Weekly"])
    }

    func testRefreshRateLimitsDecodesDirectPrimaryAndSecondaryPayload() async {
        let service = makeService()
        service.isConnected = true

        service.requestTransportOverride = { method, params in
            XCTAssertEqual(method, "account/rateLimits/read")
            XCTAssertEqual(params, .null)
            return RPCMessage(
                id: .string(UUID().uuidString),
                result: .object([
                    "primary": .object([
                        "usedPercent": .integer(15),
                        "windowDurationMins": .integer(300),
                    ]),
                    "secondary": .object([
                        "usedPercent": .integer(35),
                        "windowDurationMins": .integer(10_080),
                    ]),
                ]),
                includeJSONRPC: false
            )
        }

        await service.refreshRateLimits()

        XCTAssertEqual(service.rateLimitBuckets.map(\.limitId), ["primary", "secondary"])
        XCTAssertEqual(service.rateLimitBuckets.first?.primary?.remainingPercent, 85)
        XCTAssertEqual(service.rateLimitBuckets.last?.primary?.remainingPercent, 65)
    }

    func testIncomingRateLimitUpdateMergesPartialBucketsIntoExistingCache() {
        let service = makeService()
        service.rateLimitBuckets = [
            CodexRateLimitBucket(
                limitId: "primary",
                limitName: nil,
                primary: CodexRateLimitWindow(
                    usedPercent: 10,
                    windowDurationMins: 300,
                    resetsAt: nil
                ),
                secondary: nil
            ),
            CodexRateLimitBucket(
                limitId: "secondary",
                limitName: nil,
                primary: CodexRateLimitWindow(
                    usedPercent: 20,
                    windowDurationMins: 10_080,
                    resetsAt: nil
                ),
                secondary: nil
            ),
        ]

        service.handleIncomingRPCMessage(
            RPCMessage(
                method: "account/rateLimits/updated",
                params: .object([
                    "primary": .object([
                        "usedPercent": .integer(55),
                    ]),
                ])
            )
        )

        XCTAssertEqual(service.rateLimitBuckets.map(\.limitId), ["secondary", "primary"])
        XCTAssertEqual(service.rateLimitBuckets.first(where: { $0.limitId == "primary" })?.primary?.remainingPercent, 45)
        XCTAssertEqual(service.rateLimitBuckets.first(where: { $0.limitId == "secondary" })?.primary?.remainingPercent, 80)
    }

    func testRefreshRateLimitsClearsCachedBucketsWhenRequestFails() async {
        let service = makeService()
        service.isConnected = true
        service.rateLimitBuckets = [
            CodexRateLimitBucket(
                limitId: "stale",
                limitName: "stale",
                primary: CodexRateLimitWindow(
                    usedPercent: 25,
                    windowDurationMins: 60,
                    resetsAt: Date(timeIntervalSince1970: 1_742_100_000)
                ),
                secondary: nil
            ),
        ]

        service.requestTransportOverride = { _, _ in
            throw CodexServiceError.disconnected
        }

        await service.refreshRateLimits()

        XCTAssertTrue(service.rateLimitBuckets.isEmpty)
        XCTAssertEqual(service.rateLimitsErrorMessage, CodexServiceError.disconnected.localizedDescription)
    }

    func testSendRequestTimesOutAndClearsPendingState() async {
        let service = makeService()
        service.isConnected = true
        service.webSocketTask = URLSession.shared.webSocketTask(with: URL(string: "wss://example.com/socket")!)
        service.requestTimeoutNanosecondsOverride = 50_000_000
        service.outboundMessageTransportOverride = { _ in }

        do {
            _ = try await service.sendRequest(method: "thread/list", params: .object([:]))
            XCTFail("Expected request to time out")
        } catch let error as CodexServiceError {
            guard case .invalidInput(let message) = error else {
                return XCTFail("Expected invalidInput timeout error, got \(error)")
            }
            XCTAssertTrue(message.contains("thread/list"))
            XCTAssertTrue(message.contains("timed out"))
        } catch {
            XCTFail("Unexpected error: \(error)")
        }

        XCTAssertTrue(service.pendingRequests.isEmpty)
        XCTAssertTrue(service.pendingRequestTimeoutTasks.isEmpty)
    }

    func testFailAllPendingRequestsCancelsTimeoutTasks() async {
        let service = makeService()
        service.isConnected = true
        service.webSocketTask = URLSession.shared.webSocketTask(with: URL(string: "wss://example.com/socket")!)
        service.requestTimeoutNanosecondsOverride = 5_000_000_000
        service.outboundMessageTransportOverride = { _ in }

        let requestTask = Task {
            try await service.sendRequest(method: "model/list", params: nil)
        }

        try? await Task.sleep(nanoseconds: 50_000_000)
        XCTAssertEqual(service.pendingRequests.count, 1)
        XCTAssertEqual(service.pendingRequestTimeoutTasks.count, 1)

        service.failAllPendingRequests(with: CodexServiceError.disconnected)

        do {
            _ = try await requestTask.value
            XCTFail("Expected request to fail after disconnect")
        } catch {
            XCTAssertTrue(error is CodexServiceError)
        }

        XCTAssertTrue(service.pendingRequests.isEmpty)
        XCTAssertTrue(service.pendingRequestTimeoutTasks.isEmpty)
    }

    private func makeService() -> CodexService {
        let suiteName = "CodexStatusTests.\(UUID().uuidString)"
        let defaults = UserDefaults(suiteName: suiteName) ?? .standard
        defaults.removePersistentDomain(forName: suiteName)
        let service = CodexService(defaults: defaults)
        Self.retainedServices.append(service)
        return service
    }
}
