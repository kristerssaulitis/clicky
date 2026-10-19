//
//  ConversationMessage.swift
//  leanring-buddy
//
//  One message in an agent conversation. Persisted per agent by
//  ConversationStore; only the display form (user text / assistant text) is
//  persisted — tool traffic stays in memory for the current session.
//

import Foundation

/// Role of a persisted conversation message.
enum ConversationMessageRole: String, Codable {
    case user
    case assistant
}

/// A single exchange message in an agent's conversation transcript.
struct ConversationMessage: Codable, Identifiable, Equatable {
    var id: UUID
    var role: ConversationMessageRole
    /// Message body. Assistant text has any [POINT:...] and <ROUTINE>...>
    /// tags already stripped before storage.
    var text: String
    var timestamp: Date
    /// The raw [POINT:...] tag Claude appended, if any — kept so the
    /// transcript can later show where the buddy pointed. Not re-sent to the API.
    var pointTag: String?

    init(id: UUID = UUID(), role: ConversationMessageRole, text: String, timestamp: Date = Date(), pointTag: String? = nil) {
        self.id = id
        self.role = role
        self.text = text
        self.timestamp = timestamp
        self.pointTag = pointTag
    }
}

/// One persisted conversation for an agent. Stored as a single JSON file in
/// the agent's Conversations/ folder.
struct AgentConversation: Codable, Equatable {
    var id: UUID
    var agentID: UUID
    var createdAt: Date
    var messages: [ConversationMessage]

    init(id: UUID = UUID(), agentID: UUID, createdAt: Date = Date(), messages: [ConversationMessage] = []) {
        self.id = id
        self.agentID = agentID
        self.createdAt = createdAt
        self.messages = messages
    }
}
