//
//  AgentToolExecutor.swift
//  leanring-buddy
//
//  Executes Claude tool calls for agent mode: shell, file tools (jailed to
//  the agent workspace), and web_fetch. Read-only shell commands run without
//  asking; anything else pauses the loop for user consent via the consent
//  handler wired up by CompanionManager.
//
//  ponytail: the read-only denylist is a UX guardrail, not a security
//  boundary — a determined prompt can bypass it. cwd jail + consent + output
//  caps are what keeps the agent polite; the sandbox being off is documented.
//

import Combine
import Foundation

/// A shell command awaiting user consent.
struct AgentToolConsentRequest: Identifiable, Equatable {
    let id: UUID
    let agentName: String
    let command: String

    init(agentName: String, command: String) {
        self.id = UUID()
        self.agentName = agentName
        self.command = command
    }
}

/// What the user decided about a consent request.
enum AgentToolConsentDecision {
    case allowOnce
    case allowAlwaysThisSession
    case deny
}

/// Executes one tool call and returns the tool_result content string.
@MainActor
final class AgentToolExecutor: ObservableObject {

    /// The agent workspace everything is jailed to.
    private let workspaceURL: URL
    private let agentName: String

    /// Wired by CompanionManager — presents the consent card and awaits the
    /// user's decision. Commands the denylist flags pause here.
    var consentHandler: ((AgentToolConsentRequest) async -> AgentToolConsentDecision)?

    /// Commands the user approved "always this session" — auto-approved on
    /// later matches. Reset when the executor is recreated (per app launch).
    private var sessionApprovedCommands: Set<String> = []

    /// Shell commands that touch state, so they require consent. Matched as
    /// substrings — crude by design (see file header).
    private static let writeOperationMarkers: [String] = [
        ">", ">>", "rm ", "rm -", "mv ", "cp ", "mkdir", "touch ", "rmdir",
        "chmod", "chown", "ln ", "dd ", "truncate", "shred", "tee ",
        "sudo", "kill", "killall", "git push", "git reset", "git checkout",
        "git clean", "git commit", "git merge", "git rebase", "git rm",
        "curl ", "wget ", "ssh ", "scp ", "npm install", "npm uninstall",
        "pip install", "pip3 install", "brew ", "uv pip", "open ", "osascript",
        "defaults write", "defaults delete", "launchctl", "hdiutil", "xattr"
    ]

    init(workspaceURL: URL, agentName: String) {
        self.workspaceURL = workspaceURL
        self.agentName = agentName
    }

    /// Tool schemas sent to Claude in the `tools` array.
    static func toolDefinitions() -> [[String: Any]] {
        [
            [
                "name": "shell",
                "description": "Run a shell command in the agent working folder. Use for anything the other tools can't do. Output is capped at ~50KB.",
                "input_schema": [
                    "type": "object",
                    "properties": [
                        "command": ["type": "string", "description": "The shell command to run"],
                        "timeout_s": ["type": "integer", "description": "Timeout in seconds (default 60, max 300)"]
                    ],
                    "required": ["command"]
                ]
            ],
            [
                "name": "read_file",
                "description": "Read a text file from the working folder (relative path).",
                "input_schema": [
                    "type": "object",
                    "properties": [
                        "path": ["type": "string", "description": "File path relative to the working folder"]
                    ],
                    "required": ["path"]
                ]
            ],
            [
                "name": "write_file",
                "description": "Create or overwrite a text file in the working folder (relative path). Parent folders are created as needed.",
                "input_schema": [
                    "type": "object",
                    "properties": [
                        "path": ["type": "string", "description": "File path relative to the working folder"],
                        "content": ["type": "string", "description": "Full file contents"]
                    ],
                    "required": ["path", "content"]
                ]
            ],
            [
                "name": "edit_file",
                "description": "Replace an exact string in a file in the working folder. The old_string must appear exactly once.",
                "input_schema": [
                    "type": "object",
                    "properties": [
                        "path": ["type": "string", "description": "File path relative to the working folder"],
                        "old_string": ["type": "string", "description": "Exact text to replace"],
                        "new_string": ["type": "string", "description": "Replacement text"]
                    ],
                    "required": ["path", "old_string", "new_string"]
                ]
            ],
            [
                "name": "web_fetch",
                "description": "Fetch a URL with GET and return the response body (text, capped at ~100KB).",
                "input_schema": [
                    "type": "object",
                    "properties": [
                        "url": ["type": "string", "description": "The URL to fetch"]
                    ],
                    "required": ["url"]
                ]
            ]
        ]
    }

    /// Dispatches one tool call to its implementation. Never throws — errors
    /// come back as tool_result text so Claude can read and adapt.
    func executeTool(toolName: String, toolInput: [String: Any]) async -> String {
        switch toolName {
        case "shell":
            let command = toolInput["command"] as? String ?? ""
            let timeoutSeconds = min(max(toolInput["timeout_s"] as? Int ?? 60, 1), 300)
            return await executeShellCommand(command: command, timeoutSeconds: timeoutSeconds)
        case "read_file":
            return executeReadFile(path: toolInput["path"] as? String ?? "")
        case "write_file":
            return executeWriteFile(
                path: toolInput["path"] as? String ?? "",
                content: toolInput["content"] as? String ?? ""
            )
        case "edit_file":
            return executeEditFile(
                path: toolInput["path"] as? String ?? "",
                oldString: toolInput["old_string"] as? String ?? "",
                newString: toolInput["new_string"] as? String ?? ""
            )
        case "web_fetch":
            return await executeWebFetch(url: toolInput["url"] as? String ?? "")
        default:
            return "Error: unknown tool \(toolName)"
        }
    }

    // MARK: - shell

    private func executeShellCommand(command: String, timeoutSeconds: Int) async -> String {
        guard !command.isEmpty else { return "Error: empty command" }

        // Read-only commands (no marker in the denylist) run without asking.
        // Everything else pauses the loop for consent.
        let needsConsent = Self.writeOperationMarkers.contains { marker in
            command.lowercased().contains(marker)
        }
        if needsConsent && !sessionApprovedCommands.contains(command) {
            guard let consentHandler else {
                return "Error: user consent unavailable — command not run"
            }
            let decision = await consentHandler(AgentToolConsentRequest(agentName: agentName, command: command))
            switch decision {
            case .allowAlwaysThisSession:
                sessionApprovedCommands.insert(command)
            case .deny:
                return "The user denied this command. Adapt without it — do not retry the same command."
            case .allowOnce:
                break
            }
        }

        return await runProcess(
            launchPath: "/bin/zsh",
            arguments: ["-c", command],
            currentDirectoryURL: workspaceURL,
            timeoutSeconds: timeoutSeconds
        )
    }

    /// Runs a Process with an output cap and a wall-clock timeout.
    private func runProcess(
        launchPath: String,
        arguments: [String],
        currentDirectoryURL: URL,
        timeoutSeconds: Int
    ) async -> String {
        let process = Process()
        process.executableURL = URL(fileURLWithPath: launchPath)
        process.arguments = arguments
        process.currentDirectoryURL = currentDirectoryURL

        let stdoutPipe = Pipe()
        let stderrPipe = Pipe()
        process.standardOutput = stdoutPipe
        process.standardError = stderrPipe
        // Silence stdin — interactive prompts would otherwise hang until timeout
        process.standardInput = FileHandle.nullDevice

        do {
            try process.run()
        } catch {
            return "Error: failed to launch process — \(error.localizedDescription)"
        }

        let timeoutTask = Task.detached {
            try? await Task.sleep(nanoseconds: UInt64(timeoutSeconds) * 1_000_000_000)
            if process.isRunning {
                process.terminate()
            }
        }
        defer { timeoutTask.cancel() }

        process.waitUntilExit()

        // Cap combined output at ~50KB so a chatty command can't blow the context
        let maxOutputBytes = 50_000
        var outputData = stdoutPipe.fileHandleForReading.readDataToEndOfFile()
        let stderrData = stderrPipe.fileHandleForReading.readDataToEndOfFile()
        if outputData.count > maxOutputBytes {
            outputData = outputData.prefix(maxOutputBytes)
            outputData.append(Data("\n…(output truncated)".utf8))
        }
        var stderrText = String(data: stderrData, encoding: .utf8) ?? ""
        if stderrText.count > 5_000 {
            stderrText = String(stderrText.prefix(5_000)) + "\n…(stderr truncated)"
        }

        let stdoutText = String(data: outputData, encoding: .utf8) ?? "(non-utf8 output)"
        let exitCode = process.terminationStatus

        var resultText = stdoutText
        if !stderrText.isEmpty {
            resultText += (resultText.isEmpty ? "" : "\n") + "stderr: " + stderrText
        }
        if exitCode != 0 {
            resultText += (resultText.isEmpty ? "" : "\n") + "(exit code \(exitCode))"
        }
        return resultText.isEmpty ? "(no output)" : resultText
    }

    // MARK: - File tools (jailed to the workspace)

    /// Resolves a relative path against the workspace and rejects anything
    /// that escapes it via `..` or absolute paths.
    private func resolveJailedPath(_ path: String) -> URL? {
        guard !path.isEmpty else { return nil }
        let resolvedURL: URL
        if path.hasPrefix("/") {
            // Absolute paths are only allowed if they're inside the workspace
            resolvedURL = URL(fileURLWithPath: path).standardized
        } else {
            resolvedURL = workspaceURL.appendingPathComponent(path).standardized
        }

        let workspacePath = workspaceURL.standardized.path
        guard resolvedURL.path == workspacePath || resolvedURL.path.hasPrefix(workspacePath + "/") else {
            return nil
        }
        return resolvedURL
    }

    private func executeReadFile(path: String) -> String {
        guard let fileURL = resolveJailedPath(path) else {
            return "Error: path must stay inside the working folder"
        }
        guard let fileData = try? Data(contentsOf: fileURL) else {
            return "Error: cannot read \(path)"
        }
        if fileData.count > 100_000 {
            return String(data: fileData.prefix(100_000), encoding: .utf8).map { $0 + "\n…(file truncated at 100KB)" }
                ?? "Error: file too large to read"
        }
        return String(data: fileData, encoding: .utf8) ?? "Error: not a UTF-8 text file"
    }

    private func executeWriteFile(path: String, content: String) -> String {
        guard let fileURL = resolveJailedPath(path) else {
            return "Error: path must stay inside the working folder"
        }
        do {
            let parentDirectoryURL = fileURL.deletingLastPathComponent()
            try FileManager.default.createDirectory(at: parentDirectoryURL, withIntermediateDirectories: true)
            try content.data(using: .utf8)?.write(to: fileURL)
            return "Wrote \(content.count) chars to \(path)"
        } catch {
            return "Error: \(error.localizedDescription)"
        }
    }

    private func executeEditFile(path: String, oldString: String, newString: String) -> String {
        guard let fileURL = resolveJailedPath(path) else {
            return "Error: path must stay inside the working folder"
        }
        guard let fileText = try? String(contentsOf: fileURL, encoding: .utf8) else {
            return "Error: cannot read \(path)"
        }
        let occurrenceCount = fileText.components(separatedBy: oldString).count - 1
        guard occurrenceCount == 1 else {
            return "Error: old_string appears \(occurrenceCount) times — must appear exactly once"
        }
        let updatedText = fileText.replacingOccurrences(of: oldString, with: newString)
        do {
            try updatedText.write(to: fileURL, atomically: true, encoding: .utf8)
            return "Edited \(path)"
        } catch {
            return "Error: \(error.localizedDescription)"
        }
    }

    // MARK: - web_fetch

    private func executeWebFetch(url urlString: String) async -> String {
        guard let requestURL = URL(string: urlString), requestURL.scheme != nil else {
            return "Error: invalid URL"
        }
        var request = URLRequest(url: requestURL)
        request.httpMethod = "GET"
        request.timeoutInterval = 30

        do {
            let (data, response) = try await URLSession.shared.data(for: request)
            let statusCode = (response as? HTTPURLResponse)?.statusCode ?? 0
            // Cap the body so a huge page can't blow the context
            let bodyText = String(data: data.prefix(100_000), encoding: .utf8) ?? "(non-text response)"
            let truncationNote = data.count > 100_000 ? "\n…(body truncated at 100KB)" : ""
            return "HTTP \(statusCode)\n\(bodyText)\(truncationNote)"
        } catch {
            return "Error: \(error.localizedDescription)"
        }
    }
}
