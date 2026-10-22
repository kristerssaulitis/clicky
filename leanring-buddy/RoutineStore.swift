//
//  RoutineStore.swift
//  leanring-buddy
//
//  Recurring agent tasks. Each agent's routines persist as JSON in its
//  workspace; the agent creates/updates/deletes them via the <ROUTINE> tag
//  in its final message (see AgentSession).
//

import Combine
import Foundation

/// A routine paired with the agent that owns it (dashboard + scheduler list).
struct RoutineEntry: Identifiable {
    var id: UUID { routine.id }
    let agentID: UUID
    let routine: Routine
}

/// One recurring task for one agent.
struct Routine: Codable, Identifiable, Equatable {
    let id: UUID
    var title: String
    /// Full standalone instruction given to the agent on each run.
    var task: String
    /// Run cadence in minutes (clamped to ≥ 1).
    var everyMinutes: Int
    var isPaused: Bool
    var createdAt: Date
    /// Last time the scheduler actually ran this routine (nil = never).
    var lastRunAt: Date?

    init(id: UUID = UUID(), title: String, task: String, everyMinutes: Int, isPaused: Bool = false, createdAt: Date = Date(), lastRunAt: Date? = nil) {
        self.id = id
        self.title = title
        self.task = task
        self.everyMinutes = max(everyMinutes, 1)
        self.isPaused = isPaused
        self.createdAt = createdAt
        self.lastRunAt = lastRunAt
    }
}

/// Persists routines per agent and applies the <ROUTINE> protocol commands
/// (create/update/delete/pause/resume, matched by exact title).
@MainActor
final class RoutineStore: ObservableObject {

    /// Routines per agent ID. Observed by the dashboard.
    @Published private(set) var routinesByAgent: [UUID: [Routine]] = [:]

    private let fileManager = FileManager.default

    // MARK: - Access

    func routines(forAgentID agentID: UUID) -> [Routine] {
        loadRoutinesFromDisk(agentID: agentID) // small files; read live so edits by hand show up
    }

    func allRoutines(agentProfiles: [AgentProfile]) -> [RoutineEntry] {
        var allRoutines: [RoutineEntry] = []
        for agentProfile in agentProfiles {
            for routine in routines(forAgentID: agentProfile.id) {
                allRoutines.append(RoutineEntry(agentID: agentProfile.id, routine: routine))
            }
        }
        return allRoutines
    }

    // MARK: - Protocol commands (from <ROUTINE> tags)

    /// Applies one <ROUTINE> command. Returns a short confirmation of what changed.
    @discardableResult
    func applyRoutineCommand(_ command: RoutineCommand, agentID: UUID) -> String {
        var routines = loadRoutinesFromDisk(agentID: agentID)

        switch command.action {
        case .create:
            guard let everyMinutes = command.everyMinutes, let task = command.task, !task.isEmpty else {
                return "routine create needs every_minutes and task"
            }
            if routines.contains(where: { $0.title == command.title }) {
                // Exact-title match already exists — treat as update
                return applyRoutineCommand(
                    RoutineCommand(action: .update, everyMinutes: everyMinutes, title: command.title, task: task),
                    agentID: agentID
                )
            }
            routines.append(Routine(title: command.title, task: task, everyMinutes: everyMinutes))
            saveRoutinesToDisk(routines, agentID: agentID)
            return "created routine \"\(command.title)\" every \(everyMinutes) min"

        case .update:
            guard let routineIndex = routines.firstIndex(where: { $0.title == command.title }) else {
                return "no routine titled \"\(command.title)\" to update"
            }
            if let everyMinutes = command.everyMinutes {
                routines[routineIndex].everyMinutes = max(everyMinutes, 1)
            }
            if let task = command.task, !task.isEmpty {
                routines[routineIndex].task = task
            }
            saveRoutinesToDisk(routines, agentID: agentID)
            return "updated routine \"\(command.title)\""

        case .delete:
            guard let routineIndex = routines.firstIndex(where: { $0.title == command.title }) else {
                return "no routine titled \"\(command.title)\" to delete"
            }
            routines.remove(at: routineIndex)
            saveRoutinesToDisk(routines, agentID: agentID)
            return "deleted routine \"\(command.title)\""

        case .pause:
            guard let routineIndex = routines.firstIndex(where: { $0.title == command.title }) else {
                return "no routine titled \"\(command.title)\" to pause"
            }
            routines[routineIndex].isPaused = true
            saveRoutinesToDisk(routines, agentID: agentID)
            return "paused routine \"\(command.title)\""

        case .resume:
            guard let routineIndex = routines.firstIndex(where: { $0.title == command.title }) else {
                return "no routine titled \"\(command.title)\" to resume"
            }
            routines[routineIndex].isPaused = false
            saveRoutinesToDisk(routines, agentID: agentID)
            return "resumed routine \"\(command.title)\""
        }
    }

    // MARK: - Scheduler support

    /// Dashboard pause/resume toggle.
    func setRoutinePaused(routineID: UUID, isPaused: Bool, agentID: UUID) {
        var routines = loadRoutinesFromDisk(agentID: agentID)
        guard let routineIndex = routines.firstIndex(where: { $0.id == routineID }) else { return }
        routines[routineIndex].isPaused = isPaused
        saveRoutinesToDisk(routines, agentID: agentID)
    }

    /// Dashboard delete.
    func deleteRoutine(routineID: UUID, agentID: UUID) {
        var routines = loadRoutinesFromDisk(agentID: agentID)
        routines.removeAll { $0.id == routineID }
        saveRoutinesToDisk(routines, agentID: agentID)
    }

    func setLastRunAt(_ lastRunAt: Date, forRoutineID routineID: UUID, agentID: UUID) {
        var routines = loadRoutinesFromDisk(agentID: agentID)
        guard let routineIndex = routines.firstIndex(where: { $0.id == routineID }) else { return }
        routines[routineIndex].lastRunAt = lastRunAt
        saveRoutinesToDisk(routines, agentID: agentID)
    }

    // MARK: - Persistence

    private func routinesFileURL(agentID: UUID) -> URL {
        AgentProfileStore.workspaceURL(forAgentID: agentID).appendingPathComponent("Routines.json")
    }

    private func loadRoutinesFromDisk(agentID: UUID) -> [Routine] {
        let decoder = JSONDecoder()
        decoder.dateDecodingStrategy = .iso8601
        guard let routineData = try? Data(contentsOf: routinesFileURL(agentID: agentID)),
              let routines = try? decoder.decode([Routine].self, from: routineData) else {
            return routinesByAgent[agentID] ?? []
        }
        routinesByAgent[agentID] = routines
        return routines
    }

    private func saveRoutinesToDisk(_ routines: [Routine], agentID: UUID) {
        routinesByAgent[agentID] = routines
        let encoder = JSONEncoder()
        encoder.dateEncodingStrategy = .iso8601
        guard let routineData = try? encoder.encode(routines) else { return }
        try? routineData.write(to: routinesFileURL(agentID: agentID))
    }
}
