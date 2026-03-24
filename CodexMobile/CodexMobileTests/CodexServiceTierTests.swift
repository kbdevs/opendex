// FILE: CodexServiceTierTests.swift
// Purpose: Verifies service-tier controls stay disabled in the Opendex runtime.
// Layer: Unit Test
// Exports: CodexServiceTierTests
// Depends on: XCTest, CodexMobile

import XCTest
@testable import CodexMobile

@MainActor
final class CodexServiceTierTests: XCTestCase {
    private static var retainedServices: [CodexService] = []

    func testTurnStartDoesNotIncludeServiceTier() async throws {
        let service = makeService()
        service.isConnected = true
        service.availableModels = [makeModel()]
        service.setSelectedModelId("gpt-5.4")
        service.setSelectedServiceTier(.fast)

        var capturedTurnStartParams: [JSONValue] = []
        service.requestTransportOverride = { method, params in
            XCTAssertEqual(method, "turn/start")
            capturedTurnStartParams.append(params ?? .null)
            return RPCMessage(
                id: .string(UUID().uuidString),
                result: .object(["turnId": .string("turn-fast")]),
                includeJSONRPC: false
            )
        }

        try await service.sendTurnStart("Ship this quickly", to: "thread-fast")

        XCTAssertNil(capturedTurnStartParams.first?.objectValue?["serviceTier"]?.stringValue)
    }

    func testSetSelectedServiceTierAlwaysClearsChoice() {
        let service = makeService()

        service.setSelectedServiceTier(.fast)

        XCTAssertNil(service.selectedServiceTier)
        XCTAssertNil(service.defaults.string(forKey: CodexService.selectedServiceTierDefaultsKey))
    }

    func testSelectingServiceTierDoesNotTriggerCompatibilityPrompt() async throws {
        let service = makeService()
        service.isConnected = true
        service.availableModels = [makeModel()]
        service.setSelectedModelId("gpt-5.4")
        service.setSelectedServiceTier(.fast)

        var capturedTurnStartParams: [JSONValue] = []
        service.requestTransportOverride = { method, params in
            XCTAssertEqual(method, "turn/start")
            let safeParams = params ?? .null
            capturedTurnStartParams.append(safeParams)

            return RPCMessage(
                id: .string(UUID().uuidString),
                result: .object(["turnId": .string(UUID().uuidString)]),
                includeJSONRPC: false
            )
        }

        try await service.sendTurnStart("First send", to: "thread-fast-1")
        try await service.sendTurnStart("Second send", to: "thread-fast-2")

        XCTAssertEqual(capturedTurnStartParams.count, 2)
        XCTAssertTrue(capturedTurnStartParams.allSatisfy { params in
            params.objectValue?["serviceTier"]?.stringValue == nil
        })
        XCTAssertFalse(service.supportsServiceTier)
        XCTAssertNil(service.bridgeUpdatePrompt)
    }

    private func makeService() -> CodexService {
        let suiteName = "CodexServiceTierTests.\(UUID().uuidString)"
        let defaults = UserDefaults(suiteName: suiteName) ?? .standard
        defaults.removePersistentDomain(forName: suiteName)
        let service = CodexService(defaults: defaults)
        Self.retainedServices.append(service)
        return service
    }

    private func makeModel() -> CodexModelOption {
        CodexModelOption(
            id: "gpt-5.4",
            model: "gpt-5.4",
            displayName: "GPT-5.4",
            description: "Test model",
            isDefault: true,
            supportedReasoningEfforts: [
                CodexReasoningEffortOption(reasoningEffort: "medium", description: "Medium"),
            ],
            defaultReasoningEffort: "medium"
        )
    }
}
