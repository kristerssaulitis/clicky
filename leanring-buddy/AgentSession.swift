//
//  AgentSession.swift
//  leanring-buddy
//
//  Drives the agent-mode tool loop for one agent conversation:
//  user message → Claude turn → tool_use? execute → tool_result → repeat
//  (capped) → final text. Keeps the full API-format message history (including
//  tool traffic) in memory for the session; persisted display messages go
//  through ConversationStore.
//

import Foundation

/// A parsed <ROUTINE>{"action":...}</ROUTINE> command from an agent's final message.
struct RoutineCommand: Equatable {
    enum Action: String {
        case create
        case update
        case delete
        case pause
        case resume
    }

    let action: Action
    var everyMinutes: Int?
    var title: String
    var task: String?
}

/// Everything the caller needs from one completed agent turn.
struct AgentTurnResult {
    /// Final assistant text with [POINT:...] and <ROUTINE> tags stripped.
    let displayText: String
    /// Parsed [POINT:...] coordinate info (same fields as the voice path).
    let pointingResult: CompanionManager.PointingParseResult
    /// Routine commands the agent requested (may be empty).
    let routineCommands: [RoutineCommand]
}

@MainActor
final class AgentSession {

    /// Maximum tool rounds before the loop gives up and returns what it has.
    private static let maxToolRounds = 15

    private let agentProfile: AgentProfile
    private let claudeAPI: ClaudeAPI
    private let toolExecutor: AgentToolExecutor
    private let conversationStore: ConversationStore

    /// Full API-format message history including tool_use/tool_result blocks.
    /// Seeded from the persisted conversation on first use of the session.
    private var apiMessages: [[String: Any]] = []

    /// Whether apiMessages has been seeded from ConversationStore yet.
    private var hasSeededHistoryFromStore = false

    /// Live progress line for the dashboard ("running shell…"). Changes are
    /// surfaced through onActivityChange, which CompanionManager wires to its
    /// published per-agent activity map.
    private var currentActivityDescription: String? = nil {
        didSet { onActivityChange?(currentActivityDescription) }
    }

    /// Wired by CompanionManager to mirror activity into the dashboard.
    var onActivityChange: ((String?) -> Void)?

    /// Screen captures attached to the most recent turn — kept so the caller
    /// can map a [POINT:...] coordinate back to a display for the flight
    /// animation.
    private(set) var lastTurnScreenCaptures: [CompanionScreenCapture]? = nil

    init(agentProfile: AgentProfile, claudeAPI: ClaudeAPI, toolExecutor: AgentToolExecutor, conversationStore: ConversationStore) {
        self.agentProfile = agentProfile
        self.claudeAPI = claudeAPI
        self.toolExecutor = toolExecutor
        self.conversationStore = conversationStore
    }

    // MARK: - System prompt (B2: per-agent memory injection)

    /// Builds the agent-mode system prompt: persona + AGENTS.md + Notes.md
    /// (size-capped) + skill list + working rules + the routine protocol.
    func buildSystemPrompt() -> String {
        let workspaceURL = AgentProfileStore.workspaceURL(forAgentID: agentProfile.id)
        let agentsMarkdown = Self.sizeCappedFileContents(url: workspaceURL.appendingPathComponent("AGENTS.md"), maxBytes: 2_000)
        let notesMarkdown = Self.sizeCappedFileContents(url: workspaceURL.appendingPathComponent("Notes.md"), maxBytes: 2_000)

        let skillSummaries = SkillCatalog.bundledSkillSummaries()
        let skillListText = skillSummaries.map { skillSummary in
            "- \(skillSummary.name): \(skillSummary.description) (read Skills/\(skillSummary.fileName) before first use)"
        }.joined(separator: "\n")

        return """
        you're \(agentProfile.name), one of this person's named helpers living on their Mac. \(agentProfile.personaBrief.isEmpty ? "" : "your job: \(agentProfile.personaBrief).") your final message appears in your chat with them and its first sentence may be read aloud, so lead with the result and write plainly.

        # who you are
        \(agentsMarkdown)

        # your notes
        \(notesMarkdown)

        # skills available
        read the skill file with read_file before using one for the first time.
        \(skillListText)

        # how to work
        - your working folder is your home base. deliverables go in `output/`, scratch files in `tmp/`. when you're done, `output/` holds only what was asked for.
        - figure out what they actually want, then do it. when the result depends on something only they know, do the part that doesn't depend on the answer first, then ask one bundled set of specific questions. never invent their facts or put dummy data where theirs belongs.
        - the user's request is the approval: do the writes they asked for directly and say what you did. confirm first only before deleting their data, overwriting something they didn't ask you to change, sending email, or spending money.
        - never state something happened unless it did. never invent a fact, file, address, price, or citation — look it up with your tools or ask.
        - keep answers concise. this may be spoken aloud, so avoid heavy markdown in short answers. write for the ear when the answer is short.

        # routines
        if the user asks you to do something on a recurring schedule, you can end your FINAL message with a routine command tag, then confirm in plain text. format:
        <ROUTINE>{"action":"create","every_minutes":60,"title":"market check","task":"check the markets and summarize moves"}</ROUTINE>
        actions: create, update (match by exact title, supply new task and/or every_minutes), delete, pause, resume (all match by exact title). every_minutes must be at least 1. the task text should be a full standalone instruction to future-you. only one routine tag per message.
        """
    }

    /// Reads a file for prompt injection, capping its size so a bloated
    /// AGENTS.md/Notes.md can't blow the context.
    private static func sizeCappedFileContents(url: URL, maxBytes: Int) -> String {
        guard let fileData = try? Data(contentsOf: url), !fileData.isEmpty else {
            return "(empty)"
        }
        if fileData.count > maxBytes {
            return (String(data: fileData.prefix(maxBytes), encoding: .utf8) ?? "") + "\n…(truncated)"
        }
        return String(data: fileData, encoding: .utf8) ?? "(unreadable)"
    }

    // MARK: - The loop

    /// Runs one full agent turn. Throws only on API/network failure.
    /// - Parameters:
    ///   - userText: the user's message (or the routine task on routine runs).
    ///   - screenCaptures: optional screenshots attached to the user message.
    ///   - systemNote: optional note appended to the user message (routine runs).
    ///   - onStreamingText: called with partial assistant text for the cursor bubble.
    func runTurn(
        userText: String,
        screenCaptures: [CompanionScreenCapture] = [],
        systemNote: String? = nil,
        onStreamingText: @escaping (String) -> Void
    ) async throws -> AgentTurnResult {
        seedHistoryFromStoreIfNeeded()
        lastTurnScreenCaptures = screenCaptures.isEmpty ? nil : screenCaptures

        // Build the user message: text plus optional screenshots and system note
        var userContentBlocks: [[String: Any]] = screenCaptures.map { capture in
            let dimensionInfo = " (image dimensions: \(capture.screenshotWidthInPixels)x\(capture.screenshotHeightInPixels) pixels)"
            return [
                "type": "image",
                "source": [
                    "type": "base64",
                    "media_type": "image/jpeg",
                    "data": capture.imageData.base64EncodedString()
                ],
                "label": capture.label + dimensionInfo
            ]
        }
        var userMessageText = userText
        if let systemNote {
            userMessageText += "\n\n(system: \(systemNote))"
        }
        userContentBlocks.append(["type": "text", "text": userMessageText])
        apiMessages.append(["role": "user", "content": userContentBlocks])

        var finalResult = ClaudeAgentTurnResult(responseBlocks: [], stopReason: "error")
        var roundCount = 0

        while true {
            currentActivityDescription = roundCount == 0 ? "thinking…" : "working…"
            let turnResult = try await claudeAPI.sendAgentTurn(
                messages: apiMessages,
                tools: AgentToolExecutor.toolDefinitions(),
                systemPrompt: buildSystemPrompt(),
                onTextChunk: onStreamingText
            )
            finalResult = turnResult
            roundCount += 1

            guard turnResult.stopReason == "tool_use", !turnResult.toolUses.isEmpty, roundCount < Self.maxToolRounds else {
                break
            }

            // Echo the assistant turn (text + tool_use blocks) back into history
            apiMessages.append(["role": "assistant", "content": Self.apiContentBlocks(from: turnResult.responseBlocks)])

            // Execute every tool call and collect tool_result blocks
            var toolResultBlocks: [[String: Any]] = []
            for toolUseBlock in turnResult.toolUses {
                currentActivityDescription = "running \(toolUseBlock.toolName)…"
                let toolOutput = await executeToolUse(toolUseBlock)
                toolResultBlocks.append([
                    "type": "tool_result",
                    "tool_use_id": toolUseBlock.toolUseID,
                    "content": toolOutput
                ])
            }
            apiMessages.append(["role": "user", "content": toolResultBlocks])
        }

        currentActivityDescription = nil

        // Parse tags out of the final text
        let rawText = finalResult.text
        let routineCommands = Self.parseRoutineCommands(from: rawText)
        let textWithoutRoutines = Self.stripRoutineTags(from: rawText)
        let pointingResult = CompanionManager.parsePointingCoordinates(from: textWithoutRoutines)

        // Persist the exchange (display form only)
        conversationStore.appendMessage(
            ConversationMessage(role: .user, text: userText),
            toAgentConversation: agentProfile.id
        )
        conversationStore.appendMessage(
            ConversationMessage(
                role: .assistant,
                text: pointingResult.spokenText,
                pointTag: CompanionManager.rawPointTag(from: pointingResult)
            ),
            toAgentConversation: agentProfile.id
        )

        return AgentTurnResult(
            displayText: pointingResult.spokenText,
            pointingResult: pointingResult,
            routineCommands: routineCommands
        )
    }

    /// Executes one tool call, converting malformed input JSON into an error
    /// result Claude can read.
    private func executeToolUse(_ toolUseBlock: ClaudeToolUseBlock) async -> String {
        guard let inputData = toolUseBlock.inputJSONString.data(using: .utf8),
              let toolInput = try? JSONSerialization.jsonObject(with: inputData) as? [String: Any] else {
            return "Error: could not parse tool input JSON"
        }
        return await toolExecutor.executeTool(toolName: toolUseBlock.toolName, toolInput: toolInput)
    }

    /// Converts response blocks into the API content-block shape for echoing
    /// the assistant turn back into the next request.
    private static func apiContentBlocks(from responseBlocks: [ClaudeResponseBlock]) -> [[String: Any]] {
        responseBlocks.map { responseBlock in
            switch responseBlock {
            case let .text(text):
                return ["type": "text", "text": text]
            case let .toolUse(toolUseBlock):
                let inputObject = (toolUseBlock.inputJSONString.data(using: .utf8))
                    .flatMap { try? JSONSerialization.jsonObject(with: $0) }
                    as? [String: Any] ?? [:]
                return [
                    "type": "tool_use",
                    "id": toolUseBlock.toolUseID,
                    "name": toolUseBlock.toolName,
                    "input": inputObject
                ]
            }
        }
    }

    /// Seeds the in-memory API history with the persisted conversation
    /// (flattened to text) once per session. API payload capped at the last
    /// 10 exchanges to match the voice path.
    private func seedHistoryFromStoreIfNeeded() {
        guard !hasSeededHistoryFromStore else { return }
        hasSeededHistoryFromStore = true

        let exchanges = conversationStore.recentExchanges(forAgentID: agentProfile.id, maxExchanges: 10)
        for exchange in exchanges {
            apiMessages.append(["role": "user", "content": exchange.userText])
            apiMessages.append(["role": "assistant", "content": exchange.assistantText])
        }
    }

    // MARK: - Routine tag parsing

    /// Extracts every <ROUTINE>{...}</ROUTINE> command from the final text.
    static func parseRoutineCommands(from responseText: String) -> [RoutineCommand] {
        let pattern = #"<ROUTINE>\s*(\{.*?\})\s*</ROUTINE>"#
        guard let regex = try? NSRegularExpression(pattern: pattern, options: [.dotMatchesLineSeparators]) else {
            return []
        }

        let fullRange = NSRange(responseText.startIndex..., in: responseText)
        let matches = regex.matches(in: responseText, options: [], range: fullRange)

        return matches.compactMap { match in
            guard let jsonRange = Range(match.range(at: 1), in: responseText),
                  let payloadData = String(responseText[jsonRange]).data(using: .utf8),
                  let payload = try? JSONSerialization.jsonObject(with: payloadData) as? [String: Any],
                  let actionRaw = payload["action"] as? String,
                  let action = RoutineCommand.Action(rawValue: actionRaw),
                  let title = payload["title"] as? String else {
                return nil
            }

            var everyMinutes: Int? = nil
            if let everyMinutesRaw = payload["every_minutes"] as? Int {
                everyMinutes = max(everyMinutesRaw, 1) // clamp to ≥1
            } else if let everyMinutesDouble = payload["every_minutes"] as? Double {
                everyMinutes = max(Int(everyMinutesDouble), 1)
            }

            return RoutineCommand(
                action: action,
                everyMinutes: everyMinutes,
                title: title,
                task: payload["task"] as? String
            )
        }
    }

    /// Removes all <ROUTINE>...</ROUTINE> tags from display/TTS text.
    static func stripRoutineTags(from responseText: String) -> String {
        let pattern = #"<ROUTINE>.*?</ROUTINE>"#
        guard let regex = try? NSRegularExpression(pattern: pattern, options: [.dotMatchesLineSeparators]) else {
            return responseText
        }
        let fullRange = NSRange(responseText.startIndex..., in: responseText)
        return regex.stringByReplacingMatches(in: responseText, options: [], range: fullRange, withTemplate: "")
            .trimmingCharacters(in: .whitespacesAndNewlines)
    }
}
