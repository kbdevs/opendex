// FILE: CodexService+ThreadProjectRouting.swift
// Purpose: Keeps thread-to-project routing helpers separate from broader turn lifecycle code.
// Layer: Service Extension
// Exports: CodexService thread project routing helpers

import Foundation

struct CodexWorkspaceDirectoryEntry: Identifiable, Equatable, Sendable {
    let id: String
    let name: String
    let path: String
    let isHidden: Bool

    init?(from object: RPCObject) {
        guard let path = CodexThreadStartProjectBinding.normalizedProjectPath(object["path"]?.stringValue) else {
            return nil
        }

        let fallbackName = (path as NSString).lastPathComponent
        self.id = path
        self.path = path
        self.name = object["name"]?.stringValue ?? (fallbackName.isEmpty ? path : fallbackName)
        self.isHidden = object["isHidden"]?.boolValue ?? false
    }
}

struct CodexWorkspaceDirectoryListing: Equatable, Sendable {
    let currentPath: String
    let displayName: String
    let parentPath: String?
    let homePath: String?
    let rootPath: String?
    let volumesPath: String?
    let directories: [CodexWorkspaceDirectoryEntry]

    init?(from object: RPCObject) {
        guard let currentPath = CodexThreadStartProjectBinding.normalizedProjectPath(object["currentPath"]?.stringValue) else {
            return nil
        }

        self.currentPath = currentPath
        self.displayName = object["displayName"]?.stringValue ?? {
            let fallbackName = (currentPath as NSString).lastPathComponent
            return fallbackName.isEmpty ? currentPath : fallbackName
        }()
        self.parentPath = CodexThreadStartProjectBinding.normalizedProjectPath(object["parentPath"]?.stringValue)
        self.homePath = CodexThreadStartProjectBinding.normalizedProjectPath(object["homePath"]?.stringValue)
        self.rootPath = CodexThreadStartProjectBinding.normalizedProjectPath(object["rootPath"]?.stringValue)
        self.volumesPath = CodexThreadStartProjectBinding.normalizedProjectPath(object["volumesPath"]?.stringValue)
        self.directories = (object["directories"]?.arrayValue ?? []).compactMap { value in
            guard let entryObject = value.objectValue else {
                return nil
            }
            return CodexWorkspaceDirectoryEntry(from: entryObject)
        }
    }
}

extension CodexService {
    func listWorkspaceDirectories(path: String? = nil) async throws -> CodexWorkspaceDirectoryListing {
        let normalizedPath = CodexThreadStartProjectBinding.normalizedProjectPath(path)
        let params: JSONValue = .object(normalizedPath.map { ["path": .string($0)] } ?? [:])
        let response = try await sendRequest(method: "workspace/listDirectory", params: params)
        guard let resultObject = response.result?.objectValue,
              let listing = CodexWorkspaceDirectoryListing(from: resultObject) else {
            throw CodexServiceError.invalidResponse("Invalid response from bridge.")
        }
        return listing
    }

    // Reuses the same runtime-readiness gate across every UI entry point that starts a new chat.
    func startThreadIfReady(
        preferredProjectPath: String? = nil,
        pendingComposerAction: CodexPendingThreadComposerAction? = nil,
        runtimeOverride: CodexThreadRuntimeOverride? = nil
    ) async throws -> CodexThread {
        guard isConnected else {
            throw CodexServiceError.invalidInput("Connect to runtime first.")
        }
        guard isInitialized else {
            throw CodexServiceError.invalidInput("Runtime is still initializing. Wait a moment and retry.")
        }

        if let pendingComposerAction {
            return try await startThread(
                preferredProjectPath: preferredProjectPath,
                pendingComposerAction: pendingComposerAction,
                runtimeOverride: runtimeOverride
            )
        }

        return try await startThread(
            preferredProjectPath: preferredProjectPath,
            runtimeOverride: runtimeOverride
        )
    }

    // Rebinds the existing chat to a new local project path so worktree handoff keeps the same thread id.
    @discardableResult
    func moveThreadToProjectPath(threadId: String, projectPath: String) async throws -> CodexThread {
        let normalizedThreadId = normalizedInterruptIdentifier(threadId) ?? threadId
        guard let normalizedProjectPath = CodexThreadStartProjectBinding.normalizedProjectPath(projectPath) else {
            throw CodexServiceError.invalidInput("A valid project path is required.")
        }
        guard var currentThread = thread(for: normalizedThreadId) else {
            throw CodexServiceError.invalidInput("Thread not found.")
        }
        let previousThread = currentThread
        let wasResumed = resumedThreadIDs.contains(normalizedThreadId)

        currentThread.cwd = normalizedProjectPath
        currentThread.updatedAt = Date()
        upsertThread(currentThread)
        activeThreadId = normalizedThreadId
        markThreadAsViewed(normalizedThreadId)
        rememberRepoRoot(normalizedProjectPath, forWorkingDirectory: normalizedProjectPath)

        resumedThreadIDs.remove(normalizedThreadId)
        do {
            _ = try await ensureThreadResumed(threadId: normalizedThreadId, force: true)
        } catch {
            upsertThread(previousThread)
            if wasResumed {
                resumedThreadIDs.insert(normalizedThreadId)
            } else {
                resumedThreadIDs.remove(normalizedThreadId)
            }
            requestImmediateSync(threadId: normalizedThreadId)
            throw error
        }

        // Keep the local handoff authoritative even if the resume payload is sparse or stale.
        if var resumedThread = thread(for: normalizedThreadId),
           resumedThread.normalizedProjectPath != normalizedProjectPath {
            resumedThread.cwd = normalizedProjectPath
            resumedThread.updatedAt = max(resumedThread.updatedAt ?? .distantPast, Date())
            upsertThread(resumedThread)
        }

        requestImmediateSync(threadId: normalizedThreadId)
        return thread(for: normalizedThreadId) ?? currentThread
    }

    // Lets tool-call telemetry repair stale local/main thread bindings once a managed worktree path is observed.
    @discardableResult
    func adoptManagedWorktreeProjectPathIfNeeded(threadId: String, projectPath: String?) -> Bool {
        guard let normalizedThreadId = normalizedInterruptIdentifier(threadId),
              let observedProjectPath = CodexThreadStartProjectBinding.normalizedProjectPath(projectPath),
              var currentThread = thread(for: normalizedThreadId),
              currentThread.isManagedWorktreeProject,
              let currentProjectPath = currentThread.normalizedProjectPath else {
            return false
        }

        let canonicalCurrentPath = canonicalRepoIdentifier(for: currentProjectPath) ?? currentProjectPath
        let canonicalObservedPath = canonicalRepoIdentifier(for: observedProjectPath) ?? observedProjectPath
        guard canonicalCurrentPath == canonicalObservedPath,
              CodexThread.projectIconSystemName(for: canonicalObservedPath) == "arrow.triangle.branch" else {
            return false
        }

        if currentThread.normalizedProjectPath == canonicalObservedPath {
            return false
        }

        currentThread.cwd = canonicalObservedPath
        currentThread.updatedAt = Date()
        upsertThread(currentThread)
        rememberRepoRoot(canonicalObservedPath, forWorkingDirectory: observedProjectPath)
        if activeThreadId == normalizedThreadId {
            requestImmediateSync(threadId: normalizedThreadId)
        }
        return true
    }
}
