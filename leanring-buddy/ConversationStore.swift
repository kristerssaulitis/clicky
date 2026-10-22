//
//  ConversationStore.swift
//  leanring-buddy
//
//  Persists per-agent conversations as JSON files under the agent's
//  Conversations/ folder and exposes the active conversation for each agent
//  as observable state. Replaces CompanionManager's in-memory history array.
//

import Combine
import Foundation
import SwiftUI

@MainActor
final class ConversationStore: ObservableObject {

    /// The active (most recent) conversation per agent, loaded lazily and kept
    /// in memory. Keyed by agent UUID.
    @Published private(set) var activeConversationsByAgent: [UUID: AgentConversation] = [:]

    private let fileManager = FileManager.default

    // MARK: - Access

    /// Loads every agent's most recent conversation up front so dashboard
    /// reads never lazily mutate published state during view body evaluation.
    func preloadConversations(agentIDs: [UUID]) {
        for agentID in agentIDs {
            _ = activeConversation(forAgentID: agentID)
        }
    }

    /// The agent's active conversation, loading it from disk (or creating an
    /// empty one) on first access.
    func activeConversation(forAgentID agentID: UUID) -> AgentConversation {
        if let existingConversation = activeConversationsByAgent[agentID] {
            return existingConversation
        }

        let loadedConversation = loadMostRecentConversationFromDisk(agentID: agentID)
            ?? AgentConversation(agentID: agentID)
        activeConversationsByAgent[agentID] = loadedConversation
        return loadedConversation
    }

    /// Appends a message to the agent's active conversation, persists the
    /// conversation file, and publishes the change.
    func appendMessage(_ message: ConversationMessage, toAgentConversation agentID: UUID) {
        var conversation = activeConversation(forAgentID: agentID)
        conversation.messages.append(message)
        activeConversationsByAgent[agentID] = conversation
        persistConversationToDisk(conversation)
    }

    // MARK: - API context

    /// The last `maxExchanges` exchanges flattened to (user, assistant) text
    /// pairs for the Claude API payload. Tool blocks from the current session
    /// are handled separately by AgentSession; this is the persisted view.
    func recentExchanges(forAgentID agentID: UUID, maxExchanges: Int) -> [(userText: String, assistantText: String)] {
        let messages = activeConversation(forAgentID: agentID).messages

        var exchanges: [(userText: String, assistantText: String)] = []
        var index = 0
        while index < messages.count {
            let message = messages[index]
            if message.role == .user {
                var assistantText: String? = nil
                if index + 1 < messages.count, messages[index + 1].role == .assistant {
                    assistantText = messages[index + 1].text
                    index += 1
                }
                exchanges.append((userText: message.text, assistantText: assistantText ?? ""))
            }
            index += 1
        }

        return Array(exchanges.suffix(maxExchanges))
    }

    // MARK: - Persistence

    private func conversationsDirectoryURL(forAgentID agentID: UUID) -> URL {
        AgentProfileStore.workspaceURL(forAgentID: agentID)
            .appendingPathComponent("Conversations", isDirectory: true)
    }

    private func loadMostRecentConversationFromDisk(agentID: UUID) -> AgentConversation? {
        let directoryURL = conversationsDirectoryURL(forAgentID: agentID)
        guard let fileURLs = try? fileManager.contentsOfDirectory(
            at: directoryURL,
            includingPropertiesForKeys: [.contentModificationDateKey],
            options: .skipsHiddenFiles
        ) else { return nil }

        let decoder = JSONDecoder()
        decoder.dateDecodingStrategy = .iso8601
        let conversations = fileURLs
            .filter { $0.pathExtension == "json" }
            .compactMap { fileURL -> AgentConversation? in
                guard let conversationData = try? Data(contentsOf: fileURL) else { return nil }
                return try? decoder.decode(AgentConversation.self, from: conversationData)
            }
            .sorted { $0.createdAt > $1.createdAt }

        return conversations.first
    }

    private func persistConversationToDisk(_ conversation: AgentConversation) {
        let directoryURL = conversationsDirectoryURL(forAgentID: conversation.agentID)
        try? fileManager.createDirectory(at: directoryURL, withIntermediateDirectories: true)

        let conversationFileURL = directoryURL
            .appendingPathComponent(conversation.id.uuidString)
            .appendingPathExtension("json")

        let encoder = JSONEncoder()
        encoder.dateEncodingStrategy = .iso8601
        guard let conversationData = try? encoder.encode(conversation) else { return }
        try? conversationData.write(to: conversationFileURL)
    }
}
