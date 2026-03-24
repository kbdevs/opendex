// FILE: CodexThreadForkTests.swift
// Purpose: Verifies native thread/fork payloads, cwd routing, and runtime compatibility fallback behavior.
// Layer: Unit Test
// Exports: CodexThreadForkTests
// Depends on: XCTest, CodexMobile

import XCTest
@testable import CodexMobile

@MainActor
final class CodexThreadForkTests: XCTestCase {
    private static var retainedServices: [CodexService] = []

    private func makeThreadListResponse(_ threads: [RPCObject]) -> RPCMessage {
        RPCMessage(
            id: .string(UUID().uuidString),
            result: .object([
                "threads": .array(threads.map(JSONValue.object)),
            ]),
            includeJSONRPC: false
        )
    }

    private func makeThreadReadResponse(_ thread: RPCObject) -> RPCMessage {
        RPCMessage(
            id: .string(UUID().uuidString),
            result: .object([
                "thread": .object(thread),
            ]),
            includeJSONRPC: false
        )
    }

    private func makeBackgroundSyncResponse(method: String, thread: RPCObject) -> RPCMessage? {
        switch method {
        case "thread/list":
            return makeThreadListResponse([thread])
        case "thread/read":
            return makeThreadReadResponse(thread)
        default:
            return nil
        }
    }

    func testLocalForkUsesSourceThreadWorkingDirectory() async throws {
        let service = makeService()
        service.isConnected = true
        service.isInitialized = true
        service.threads = [makeSourceThread()]

        var capturedForkParams: [String: JSONValue] = [:]
        service.requestTransportOverride = { method, params in
            let forkThread: RPCObject = [
                "id": .string("fork-local"),
                "cwd": .string("/tmp/remodex"),
                "title": .string("Fork Local"),
                "forkedFromThreadId": .string("source-thread"),
            ]
            switch method {
            case "thread/fork":
                capturedForkParams = params?.objectValue ?? [:]
                return RPCMessage(
                    id: .string(UUID().uuidString),
                    result: .object([
                        "cwd": .string("/tmp/remodex"),
                        "thread": .object(forkThread),
                    ]),
                    includeJSONRPC: false
                )
            case "thread/resume":
                return self.makeThreadReadResponse(forkThread)
            case "thread/list", "thread/read":
                return self.makeBackgroundSyncResponse(method: method, thread: forkThread)!
            default:
                XCTFail("Unexpected method: \(method)")
                throw CodexServiceError.invalidInput("Unexpected method")
            }
        }

        let forkedThread = try await service.forkThreadIfReady(from: "source-thread", target: .currentProject)

        XCTAssertEqual(capturedForkParams["threadId"]?.stringValue, "source-thread")
        XCTAssertEqual(capturedForkParams["cwd"]?.stringValue, "/tmp/remodex")
        XCTAssertEqual(capturedForkParams["model"]?.stringValue, "gpt-5.4")
        XCTAssertEqual(capturedForkParams["modelProvider"]?.stringValue, "openai")
        XCTAssertEqual(service.activeThreadId, "fork-local")
        XCTAssertEqual(forkedThread.id, "fork-local")
        XCTAssertEqual(service.thread(for: "fork-local")?.gitWorkingDirectory, "/tmp/remodex")
    }

    func testWorktreeForkUsesProvidedProjectPath() async throws {
        let service = makeService()
        service.isConnected = true
        service.isInitialized = true
        service.threads = [makeSourceThread()]

        var capturedForkParams: [String: JSONValue] = [:]
        service.requestTransportOverride = { method, params in
            let forkThread: RPCObject = [
                "id": .string("fork-worktree"),
                "cwd": .string("/tmp/remodex-worktree"),
                "title": .string("Fork Worktree"),
                "forkedFromThreadId": .string("source-thread"),
            ]
            switch method {
            case "thread/fork":
                capturedForkParams = params?.objectValue ?? [:]
                return RPCMessage(
                    id: .string(UUID().uuidString),
                    result: .object([
                        "cwd": .string("/tmp/remodex-worktree"),
                        "thread": .object(forkThread),
                    ]),
                    includeJSONRPC: false
                )
            case "thread/resume":
                return self.makeThreadReadResponse(forkThread)
            case "thread/list", "thread/read":
                return self.makeBackgroundSyncResponse(method: method, thread: forkThread)!
            default:
                XCTFail("Unexpected method: \(method)")
                throw CodexServiceError.invalidInput("Unexpected method")
            }
        }

        let forkedThread = try await service.forkThreadIfReady(
            from: "source-thread",
            target: .projectPath("/tmp/remodex-worktree")
        )

        XCTAssertEqual(capturedForkParams["cwd"]?.stringValue, "/tmp/remodex-worktree")
        XCTAssertEqual(forkedThread.gitWorkingDirectory, "/tmp/remodex-worktree")
    }

    func testForkStillReturnsCreatedThreadWhenHydrationFails() async throws {
        let service = makeService()
        service.isConnected = true
        service.isInitialized = true
        service.threads = [makeSourceThread()]

        var requestedMethods: [String] = []
        service.requestTransportOverride = { method, _ in
            requestedMethods.append(method)
            let forkThread: RPCObject = [
                "id": .string("fork-partial"),
                "cwd": .string("/tmp/remodex-worktree"),
                "title": .string("Fork Partial"),
                "forkedFromThreadId": .string("source-thread"),
            ]
            switch method {
            case "thread/fork":
                return RPCMessage(
                    id: .string(UUID().uuidString),
                    result: .object([
                        "cwd": .string("/tmp/remodex-worktree"),
                        "thread": .object(forkThread),
                    ]),
                    includeJSONRPC: false
                )
            case "thread/resume":
                throw CodexServiceError.disconnected
            case "thread/list", "thread/read":
                return self.makeBackgroundSyncResponse(method: method, thread: forkThread)!
            default:
                XCTFail("Unexpected method: \(method)")
                throw CodexServiceError.invalidInput("Unexpected method")
            }
        }

        let forkedThread = try await service.forkThreadIfReady(
            from: "source-thread",
            target: .projectPath("/tmp/remodex-worktree")
        )

        XCTAssertTrue(requestedMethods.contains("thread/fork"))
        XCTAssertTrue(requestedMethods.contains("thread/resume"))
        XCTAssertEqual(forkedThread.id, "fork-partial")
        XCTAssertEqual(forkedThread.gitWorkingDirectory, "/tmp/remodex-worktree")
        XCTAssertEqual(service.activeThreadId, "fork-partial")
        XCTAssertEqual(service.thread(for: "fork-partial")?.gitWorkingDirectory, "/tmp/remodex-worktree")
    }

    func testForkMarksCreatedThreadAsForkedFromSource() async throws {
        let service = makeService()
        service.isConnected = true
        service.isInitialized = true
        service.threads = [makeSourceThread()]

        service.requestTransportOverride = { method, _ in
            let forkThread: RPCObject = [
                "id": .string("fork-local"),
                "cwd": .string("/tmp/remodex"),
                "title": .string("Fork Local"),
                "forkedFromThreadId": .string("source-thread"),
            ]
            switch method {
            case "thread/fork":
                return RPCMessage(
                    id: .string(UUID().uuidString),
                    result: .object([
                        "thread": .object(forkThread),
                    ]),
                    includeJSONRPC: false
                )
            case "thread/resume":
                return self.makeThreadReadResponse(forkThread)
            case "thread/list", "thread/read":
                return self.makeBackgroundSyncResponse(method: method, thread: forkThread)!
            default:
                XCTFail("Unexpected method: \(method)")
                throw CodexServiceError.invalidInput("Unexpected method")
            }
        }

        let forkedThread = try await service.forkThreadIfReady(from: "source-thread", target: .currentProject)

        XCTAssertEqual(forkedThread.forkedFromThreadId, "source-thread")
        XCTAssertTrue(forkedThread.isForkedThread)
        XCTAssertEqual(service.thread(for: "fork-local")?.forkedFromThreadId, "source-thread")
    }

    func testForkAssignsLocalTimestampsWhenResponseOmitsThem() async throws {
        let service = makeService()
        service.isConnected = true
        service.isInitialized = true
        service.threads = [makeSourceThread()]

        service.requestTransportOverride = { method, _ in
            let forkThread: RPCObject = [
                "id": .string("fork-local"),
                "cwd": .string("/tmp/remodex"),
                "title": .string("Fork Local"),
                "forkedFromThreadId": .string("source-thread"),
            ]
            switch method {
            case "thread/fork":
                return RPCMessage(
                    id: .string(UUID().uuidString),
                    result: .object([
                        "thread": .object(forkThread),
                    ]),
                    includeJSONRPC: false
                )
            case "thread/resume":
                throw CodexServiceError.disconnected
            case "thread/list", "thread/read":
                return self.makeBackgroundSyncResponse(method: method, thread: forkThread)!
            default:
                XCTFail("Unexpected method: \(method)")
                throw CodexServiceError.invalidInput("Unexpected method")
            }
        }

        let forkedThread = try await service.forkThreadIfReady(from: "source-thread", target: .currentProject)

        XCTAssertNotNil(forkedThread.createdAt)
        XCTAssertNotNil(forkedThread.updatedAt)
        XCTAssertNotNil(service.thread(for: "fork-local")?.updatedAt)
    }

    func testPersistedForkOriginRehydratesAfterServiceReload() async throws {
        let suiteName = "CodexThreadForkTests.persistedForkOrigin.\(UUID().uuidString)"
        guard let defaults = UserDefaults(suiteName: suiteName) else {
            XCTFail("Expected isolated UserDefaults suite")
            return
        }
        defaults.removePersistentDomain(forName: suiteName)

        let service = makeService(defaults: defaults)
        service.isConnected = true
        service.isInitialized = true
        service.threads = [makeSourceThread()]

        service.requestTransportOverride = { method, _ in
            let forkThread: RPCObject = [
                "id": .string("fork-local"),
                "cwd": .string("/tmp/remodex"),
                "title": .string("Fork Local"),
                "forkedFromThreadId": .string("source-thread"),
            ]
            switch method {
            case "thread/fork":
                return RPCMessage(
                    id: .string(UUID().uuidString),
                    result: .object([
                        "thread": .object(forkThread),
                    ]),
                    includeJSONRPC: false
                )
            case "thread/resume":
                return self.makeThreadReadResponse(forkThread)
            case "thread/list", "thread/read":
                return self.makeBackgroundSyncResponse(method: method, thread: forkThread)!
            default:
                XCTFail("Unexpected method: \(method)")
                throw CodexServiceError.invalidInput("Unexpected method")
            }
        }

        _ = try await service.forkThreadIfReady(from: "source-thread", target: .currentProject)

        let reloadedService = makeService(defaults: defaults)
        reloadedService.upsertThread(
            CodexThread(
                id: "fork-local",
                title: "Fork Local",
                cwd: "/tmp/remodex"
            )
        )

        XCTAssertEqual(reloadedService.thread(for: "fork-local")?.forkedFromThreadId, "source-thread")
        XCTAssertTrue(reloadedService.thread(for: "fork-local")?.isForkedThread == true)
    }

    func testForkFallsBackToMinimalRequestWhenOverridesAreRejected() async throws {
        let service = makeService()
        service.isConnected = true
        service.isInitialized = true
        service.threads = [makeSourceThread()]

        var forkRequests: [[String: JSONValue]] = []
        var resumeRequests: [[String: JSONValue]] = []
        var forkAttemptCount = 0

        service.requestTransportOverride = { method, params in
            let object = params?.objectValue ?? [:]
            let forkThread: RPCObject = [
                "id": .string("fork-minimal"),
                "cwd": .string("/tmp/remodex-worktree"),
                "title": .string("Fork Minimal"),
                "forkedFromThreadId": .string("source-thread"),
            ]
            switch method {
            case "thread/fork":
                forkAttemptCount += 1
                forkRequests.append(object)
                if forkAttemptCount == 1 {
                    throw CodexServiceError.rpcError(
                        RPCError(code: -32602, message: "Invalid params: unknown field modelProvider")
                    )
                }

                return RPCMessage(
                    id: .string(UUID().uuidString),
                    result: .object([
                        "thread": .object(forkThread),
                    ]),
                    includeJSONRPC: false
                )
            case "thread/resume":
                resumeRequests.append(object)
                return self.makeThreadReadResponse(forkThread)
            case "thread/list", "thread/read":
                return self.makeBackgroundSyncResponse(method: method, thread: forkThread)!
            default:
                XCTFail("Unexpected method: \(method)")
                throw CodexServiceError.invalidInput("Unexpected method")
            }
        }

        let forkedThread = try await service.forkThreadIfReady(
            from: "source-thread",
            target: .projectPath("/tmp/remodex-worktree")
        )

        XCTAssertEqual(forkRequests.count, 2)
        XCTAssertEqual(forkRequests.first?["cwd"]?.stringValue, "/tmp/remodex-worktree")
        XCTAssertEqual(forkRequests.first?["modelProvider"]?.stringValue, "openai")
        XCTAssertEqual(forkRequests.last?["threadId"]?.stringValue, "source-thread")
        XCTAssertNil(forkRequests.last?["cwd"])
        XCTAssertNil(forkRequests.last?["model"])
        XCTAssertNil(forkRequests.last?["modelProvider"])
        XCTAssertEqual(resumeRequests.count, 1)
        XCTAssertEqual(resumeRequests.first?["threadId"]?.stringValue, "fork-minimal")
        XCTAssertEqual(resumeRequests.first?["cwd"]?.stringValue, "/tmp/remodex-worktree")
        XCTAssertEqual(resumeRequests.first?["model"]?.stringValue, "gpt-5.4")
        XCTAssertEqual(forkedThread.gitWorkingDirectory, "/tmp/remodex-worktree")
        XCTAssertEqual(service.thread(for: "fork-minimal")?.gitWorkingDirectory, "/tmp/remodex-worktree")
    }

    func testForkDoesNotFallbackWhenOverrideValueIsUnsupported() async {
        let service = makeService()
        service.isConnected = true
        service.isInitialized = true
        service.threads = [makeSourceThread()]

        var forkRequestCount = 0
        service.requestTransportOverride = { method, _ in
            switch method {
            case "thread/fork":
                forkRequestCount += 1
                throw CodexServiceError.rpcError(
                    RPCError(code: -32000, message: "model gpt-5.4 not supported")
                )
            case "thread/list":
                return self.makeThreadListResponse([])
            case "thread/read":
                return self.makeThreadReadResponse([
                    "id": .string("source-thread"),
                    "cwd": .string("/tmp/remodex"),
                    "title": .string("Source"),
                ])
            default:
                XCTFail("Unexpected method: \(method)")
                throw CodexServiceError.invalidInput("Unexpected method")
            }
        }

        do {
            _ = try await service.forkThreadIfReady(
                from: "source-thread",
                target: .projectPath("/tmp/remodex-worktree")
            )
            XCTFail("Expected unsupported model value to fail without retry")
        } catch {
            XCTAssertEqual(forkRequestCount, 1)
        }
    }

    func testUnsupportedThreadForkDisablesCapabilityAndShowsUpdatePrompt() async {
        let service = makeService()
        service.isConnected = true
        service.isInitialized = true
        service.threads = [makeSourceThread()]

        service.requestTransportOverride = { method, _ in
            switch method {
            case "thread/fork":
                throw CodexServiceError.rpcError(
                    RPCError(code: -32601, message: "Method not found: thread/fork")
                )
            case "thread/list":
                return self.makeThreadListResponse([])
            case "thread/read":
                return self.makeThreadReadResponse([
                    "id": .string("source-thread"),
                    "cwd": .string("/tmp/remodex"),
                    "title": .string("Source"),
                ])
            default:
                XCTFail("Unexpected method: \(method)")
                throw CodexServiceError.invalidInput("Unexpected method")
            }
        }

        do {
            _ = try await service.forkThreadIfReady(from: "source-thread", target: .currentProject)
            XCTFail("Expected thread/fork to fail")
        } catch {
            XCTAssertFalse(service.supportsThreadFork)
            XCTAssertEqual(service.bridgeUpdatePrompt?.title, "Update Opendex on your Mac to use /fork")
            XCTAssertEqual(
                service.bridgeUpdatePrompt?.message,
                "This Opendex bridge does not support native conversation forks yet. Update the bridge on your Mac to use /fork and worktree fork flows."
            )
            XCTAssertEqual(service.bridgeUpdatePrompt?.command, "bun add -g opendex@latest")
        }
    }

    func testLocalForkFallsBackToCurrentWorktreeWhenLocalCheckoutIsUnavailable() {
        let tempRoot = FileManager.default.temporaryDirectory
            .appendingPathComponent(UUID().uuidString, isDirectory: true)
        let worktreePath = tempRoot
            .appendingPathComponent(".codex/worktrees/a8b4/phodex-website", isDirectory: true)

        try? FileManager.default.createDirectory(at: worktreePath, withIntermediateDirectories: true)
        defer { try? FileManager.default.removeItem(at: tempRoot) }

        let worktreeThread = CodexThread(
            id: "source-thread",
            title: "Source",
            cwd: worktreePath.path,
            model: "gpt-5.4",
            modelProvider: "openai"
        )

        let fallbackPath = TurnThreadForkCoordinator.localForkProjectPath(
            for: worktreeThread,
            localCheckoutPath: nil
        )

        XCTAssertEqual(fallbackPath, worktreePath.path)
    }

    func testLocalForkAcceptsRemotePathsWithoutCheckingClientFilesystem() {
        let worktreeThread = CodexThread(
            id: "source-thread",
            title: "Source",
            cwd: "/Users/emanueledipietro/.codex/worktrees/a8b4/phodex-website",
            model: "gpt-5.4",
            modelProvider: "openai"
        )

        let localForkPath = TurnThreadForkCoordinator.localForkProjectPath(
            for: worktreeThread,
            localCheckoutPath: "/Users/emanueledipietro/Developer/Remodex/phodex-website"
        )

        XCTAssertEqual(localForkPath, "/Users/emanueledipietro/Developer/Remodex/phodex-website")
    }

    func testLocalForkIsUnavailableWhenCurrentWorktreeHasBeenRemoved() {
        let tempRoot = FileManager.default.temporaryDirectory
            .appendingPathComponent(UUID().uuidString, isDirectory: true)
        let missingWorktreePath = tempRoot
            .appendingPathComponent(".codex/worktrees/a8b4/phodex-website", isDirectory: true)

        let worktreeThread = CodexThread(
            id: "source-thread",
            title: "Source",
            cwd: missingWorktreePath.path,
            model: "gpt-5.4",
            modelProvider: "openai"
        )

        let fallbackPath = TurnThreadForkCoordinator.localForkProjectPath(
            for: worktreeThread,
            localCheckoutPath: nil,
            pathValidator: existingDirectoryPath
        )

        XCTAssertNil(fallbackPath)
    }

    private func existingDirectoryPath(_ rawPath: String?) -> String? {
        guard let rawPath else {
            return nil
        }

        let trimmedPath = rawPath.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !trimmedPath.isEmpty else {
            return nil
        }

        var isDirectory: ObjCBool = false
        guard FileManager.default.fileExists(atPath: trimmedPath, isDirectory: &isDirectory), isDirectory.boolValue else {
            return nil
        }

        return trimmedPath
    }

    private func makeService(defaults: UserDefaults? = nil) -> CodexService {
        let resolvedDefaults: UserDefaults
        if let defaults {
            resolvedDefaults = defaults
        } else {
            let suiteName = "CodexThreadForkTests.\(UUID().uuidString)"
            let isolatedDefaults = UserDefaults(suiteName: suiteName) ?? .standard
            isolatedDefaults.removePersistentDomain(forName: suiteName)
            resolvedDefaults = isolatedDefaults
        }
        let service = CodexService(defaults: resolvedDefaults)
        Self.retainedServices.append(service)
        return service
    }

    private func makeSourceThread() -> CodexThread {
        CodexThread(
            id: "source-thread",
            title: "Source",
            cwd: "/tmp/remodex",
            model: "gpt-5.4",
            modelProvider: "openai"
        )
    }
}
