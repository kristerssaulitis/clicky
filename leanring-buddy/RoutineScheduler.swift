//
//  RoutineScheduler.swift
//  leanring-buddy
//
//  Timer-driven scheduler for agent routines. Ticks every 30 seconds; any
  //  unpaused routine whose cadence has elapsed runs once. After sleep, the
//  next tick settles all overdue routines in one pass (each runs once, then
//  its lastRunAt advances).
//

import Foundation

@MainActor
final class RoutineScheduler {

    private let routineStore: RoutineStore
    private let agentProfileStore: AgentProfileStore
    /// Runs one routine turn in the owning agent's conversation.
    /// Provided by CompanionManager (wires TTS, cursor bubble, dashboard).
    private let runRoutineTurn: (UUID, Routine) async -> Void

    private var tickTimer: Timer?
    /// Only one routine runs at a time across all agents.
    private var isRoutineRunInFlight = false

    init(routineStore: RoutineStore, agentProfileStore: AgentProfileStore, runRoutineTurn: @escaping (UUID, Routine) async -> Void) {
        self.routineStore = routineStore
        self.agentProfileStore = agentProfileStore
        self.runRoutineTurn = runRoutineTurn
    }

    func start() {
        guard tickTimer == nil else { return }
        tickTimer = Timer.scheduledTimer(withTimeInterval: 30.0, repeats: true) { [weak self] _ in
            Task { @MainActor [weak self] in
                self?.tick()
            }
        }
    }

    func stop() {
        tickTimer?.invalidate()
        tickTimer = nil
    }

    /// Runs every due routine once. Skipped while another routine run is in
    /// flight — the next tick picks it up.
    func tick() {
        guard !isRoutineRunInFlight else { return }

        let now = Date()
        let dueEntries = routineStore.allRoutines(agentProfiles: agentProfileStore.agents).filter { entry in
            guard !entry.routine.isPaused else { return false }
            guard let lastRunAt = entry.routine.lastRunAt else { return true } // never run → due now
            return now.timeIntervalSince(lastRunAt) >= Double(entry.routine.everyMinutes) * 60.0
        }

        guard let firstDueEntry = dueEntries.first else { return }

        isRoutineRunInFlight = true
        let agentID = firstDueEntry.agentID
        let routine = firstDueEntry.routine
        routineStore.setLastRunAt(now, forRoutineID: routine.id, agentID: agentID)

        // The Task inherits MainActor context from this method
        Task {
            await runRoutineTurn(agentID, routine)
            self.isRoutineRunInFlight = false
            // Settle any routine that came due while this one ran
            self.tick()
        }
    }
}
