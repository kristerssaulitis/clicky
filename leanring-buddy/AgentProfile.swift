//
//  AgentProfile.swift
//  leanring-buddy
//
//  Named helper agents ("Home Space"). Each agent is a small profile plus a
//  per-agent working folder on disk (AGENTS.md, Notes.md, output/, tmp/,
//  Conversations/, Skills/). Profiles persist as JSON inside the agent's own
//  folder so the whole agent is one directory you can inspect or delete.
//

import Foundation
import SwiftUI

/// One named agent. Persisted to `<workspace>/profile.json`.
struct AgentProfile: Codable, Identifiable, Equatable {
    let id: UUID
    var name: String
    /// SF Symbol name shown in the dashboard avatar circle.
    var avatarSymbolName: String
    /// Avatar tint as hex (e.g. "#60A5FA") so it survives Codable round-trips.
    var avatarColorHex: String
    /// One-line description of what this agent is for, injected into its system prompt.
    var personaBrief: String
    var createdAt: Date

    /// Avatar tint resolved for SwiftUI.
    var avatarColor: Color {
        Color(hex: avatarColorHex)
    }
}

/// Owns the set of agents on disk under
/// `~/Library/Application Support/Clicky/Agents/<agentID>/`.
/// Auto-creates the default "clicky" agent on first launch so the existing
/// voice flow works unchanged.
@MainActor
final class AgentProfileStore: ObservableObject {

    /// Root folder that holds every agent workspace.
    static var agentsRootURL: URL {
        let appSupport = FileManager.default.urls(for: .applicationSupportDirectory, in: .userDomainMask).first!
        return appSupport.appendingPathComponent("Clicky/Agents", isDirectory: true)
    }

    static func workspaceURL(forAgentID agentID: UUID) -> URL {
        agentsRootURL.appendingPathComponent(agentID.uuidString, isDirectory: true)
    }

    /// All agents, oldest first. Observed by the dashboard so new agents appear live.
    @Published private(set) var agents: [AgentProfile] = []

    /// Fixed avatar pool the "new agent" sheet cycles through.
    static let avatarSymbolChoices = [
        ("bird.fill", "#60A5FA"),
        ("ladybug.fill", "#E5484D"),
        ("leaf.fill", "#34D399"),
        ("moon.stars.fill", "#8F46EB"),
        ("fish.fill", "#FF8C33"),
        ("ant.fill", "#ADB5B2")
    ]

    init() {
        loadAllAgentsFromDisk()
        if agents.isEmpty {
            _ = createDefaultClickyAgentIfNeeded()
        }
    }

    func profile(forAgentID agentID: UUID) -> AgentProfile? {
        agents.first { $0.id == agentID }
    }

    /// The default agent used by the existing voice flow.
    func defaultAgentProfile() -> AgentProfile? {
        agents.min { $0.createdAt < $1.createdAt }
    }

    /// Creates a new agent: profile JSON + scaffolded working folder.
    /// Returns the new profile, or nil if the name is blank.
    @discardableResult
    func createAgent(name: String, personaBrief: String) -> AgentProfile? {
        let trimmedName = name.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !trimmedName.isEmpty else { return nil }

        let avatarChoice = Self.avatarSymbolChoices[agents.count % Self.avatarSymbolChoices.count]
        let newProfile = AgentProfile(
            id: UUID(),
            name: trimmedName,
            avatarSymbolName: avatarChoice.0,
            avatarColorHex: avatarChoice.1,
            personaBrief: personaBrief.trimmingCharacters(in: .whitespacesAndNewlines),
            createdAt: Date()
        )

        scaffoldWorkspace(for: newProfile)
        agents.append(newProfile)
        persistProfile(newProfile)
        return newProfile
    }

    func deleteAgent(agentID: UUID) {
        guard agents.count > 1 else { return } // never delete the last agent
        agents.removeAll { $0.id == agentID }
        try? FileManager.default.removeItem(at: Self.workspaceURL(forAgentID: agentID))
    }

    // MARK: - Workspace scaffolding

    /// Creates the agent's folder tree and seed files:
    /// AGENTS.md (persona + working rules), Notes.md, output/, tmp/, Conversations/, Skills/.
    private func scaffoldWorkspace(for profile: AgentProfile) {
        let workspaceURL = Self.workspaceURL(forAgentID: profile.id)
        let fileManager = FileManager.default

        for subdirectory in ["output", "tmp", "Conversations", "Skills"] {
            try? fileManager.createDirectory(
                at: workspaceURL.appendingPathComponent(subdirectory, isDirectory: true),
                withIntermediateDirectories: true
            )
        }

        // AGENTS.md — the agent's persistent memory of who it is. Injected into
        // its system prompt at the start of every turn.
        let agentsMarkdown = """
        # \(profile.name)

        \(profile.personaBrief.isEmpty ? "You are one of this person's named helpers on their Mac." : profile.personaBrief)

        ## Working rules
        - Work in this folder. Deliverables go in `output/`, scratch work in `tmp/`.
        - When you learn something durable (a preference, a decision), append it to `Notes.md` with today's date. Never store passwords, tokens, or other secrets there.
        - When two facts disagree, the newest dated one wins.
        - Never invent facts. Look them up with your tools, or ask.
        - The user's request is the approval: do the writes they asked for and say what you did. Confirm first only before deleting data, overwriting something they didn't ask you to change, sending email, or spending money.
        """

        fileManager.createFile(
            atPath: workspaceURL.appendingPathComponent("AGENTS.md").path,
            contents: agentsMarkdown.data(using: .utf8)
        )
        fileManager.createFile(
            atPath: workspaceURL.appendingPathComponent("Notes.md").path,
            contents: Data("".utf8)
        )

        copyBundledSkillsIntoWorkspace(workspaceURL: workspaceURL)
    }

    /// Copies the skill markdown files bundled with the app into the agent's
    /// Skills/ folder so the agent can read them with its own file tools
    /// (which are jailed to its workspace).
    private func copyBundledSkillsIntoWorkspace(workspaceURL: URL) {
        for skillName in SkillCatalog.bundledSkillNames {
            guard let skillURL = SkillCatalog.bundledSkillURL(named: skillName) else { continue }
            let destinationURL = workspaceURL
                .appendingPathComponent("Skills", isDirectory: true)
                .appendingPathComponent(skillURL.lastPathComponent)
            try? FileManager.default.removeItem(at: destinationURL)
            try? FileManager.default.copyItem(at: skillURL, to: destinationURL)
        }
    }

    // MARK: - Persistence

    private func loadAllAgentsFromDisk() {
        let fileManager = FileManager.default
        try? fileManager.createDirectory(at: Self.agentsRootURL, withIntermediateDirectories: true)

        guard let agentFolderURLs = try? fileManager.contentsOfDirectory(
            at: Self.agentsRootURL,
            includingPropertiesForKeys: nil,
            options: .skipsHiddenFiles
        ) else { return }

        var loadedAgents: [AgentProfile] = []
        for folderURL in agentFolderURLs where folderURL.hasDirectoryPath {
            let profileURL = folderURL.appendingPathComponent("profile.json")
            guard let profileData = try? Data(contentsOf: profileURL),
                  let profile = try? JSONDecoder().decode(AgentProfile.self, from: profileData) else {
                continue
            }
            loadedAgents.append(profile)
        }

        agents = loadedAgents.sorted { $0.createdAt < $1.createdAt }
    }

    private func persistProfile(_ profile: AgentProfile) {
        let profileURL = Self.workspaceURL(forAgentID: profile.id).appendingPathComponent("profile.json")
        guard let profileData = try? JSONEncoder().encode(profile) else { return }
        try? profileData.write(to: profileURL)
    }

    /// Creates the original "clicky" agent on first launch so the existing
    /// voice flow has an agent to talk to. Returns nil if any agent exists.
    @discardableResult
    private func createDefaultClickyAgentIfNeeded() -> AgentProfile? {
        guard agents.isEmpty else { return nil }
        guard let clickyProfile = createAgent(
            name: "clicky",
            personaBrief: "the friendly always-on companion that lives in the menu bar"
        ) else { return nil }
        persistProfile(clickyProfile)
        return clickyProfile
    }
}

/// One bundled skill as shown in the dashboard and the agent system prompt.
struct SkillSummary: Identifiable {
    var id: String { fileName }
    let fileName: String
    let name: String
    let description: String
}

/// Static description of the skills bundled with the app, used to build the
/// "skills" section of each agent's system prompt and the dashboard list.
enum SkillCatalog {
    /// Base names (without .md) of skills shipped in the app bundle.
    static let bundledSkillNames = [
        "ocr-and-documents",
        "apple-notes",
        "apple-reminders",
        "github-issues",
        "clicky-workspace"
    ]

    /// Finds a bundled skill file no matter how Xcode laid out the bundle
    /// (flat at root, or inside a Resources/Skills folder).
    static func bundledSkillURL(named skillName: String) -> URL? {
        let subdirectoryCandidates: [String?] = [nil, "Skills", "Resources/Skills", "Resources"]
        for subdirectory in subdirectoryCandidates {
            if let skillURL = Bundle.main.url(forResource: skillName, withExtension: "md", subdirectory: subdirectory) {
                return skillURL
            }
        }
        return nil
    }

    /// Reads each bundled skill's YAML frontmatter to pull out `name` and
    /// `description` for the system prompt listing.
    static func bundledSkillSummaries() -> [SkillSummary] {
        bundledSkillNames.map { skillName in
            guard let skillURL = bundledSkillURL(named: skillName),
                  let skillText = try? String(contentsOf: skillURL, encoding: .utf8) else {
                // Fall back to the file name if frontmatter can't be read
                return SkillSummary(fileName: "\(skillName).md", name: skillName, description: "")
            }
            return SkillSummary(
                fileName: "\(skillName).md",
                name: skillName,
                description: parseYAMLDescription(from: skillText)
            )
        }
    }

    /// Pulls the `description:` value out of a skill's YAML frontmatter.
    static func parseYAMLDescription(from skillMarkdown: String) -> String {
        for line in skillMarkdown.split(separator: "\n", omittingEmptySubsequences: true).prefix(15) {
            let trimmedLine = line.trimmingCharacters(in: .whitespaces)
            if trimmedLine.hasPrefix("description:") {
                var description = trimmedLine.dropFirst("description:".count)
                    .trimmingCharacters(in: .whitespaces)
                if description.hasPrefix("\"") && description.hasSuffix("\"") && description.count >= 2 {
                    description = String(description.dropFirst().dropLast())
                }
                return description
            }
        }
        return ""
    }
}
