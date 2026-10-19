//
//  HomeSpaceView.swift
//  leanring-buddy
//
//  The Home Space dashboard: agent rows, per-agent conversations with a text
//  input, routine controls, and the bundled skills list. Hosted in a standard
//  activating window (see HomeSpaceWindowManager).
//

import SwiftUI

// MARK: - Root dashboard

/// Thin wrapper — the dashboard reads state from several ObservableObjects
/// (stores), so the real content lives in HomeSpaceContent which observes
/// each store directly.
struct HomeSpaceView: View {
    @ObservedObject var companionManager: CompanionManager

    var body: some View {
        HomeSpaceContent(
            companionManager: companionManager,
            agentStore: companionManager.agentStore,
            conversationStore: companionManager.conversationStore,
            routineStore: companionManager.routineStore
        )
    }
}

struct HomeSpaceContent: View {
    @ObservedObject var companionManager: CompanionManager
    @ObservedObject var agentStore: AgentProfileStore
    @ObservedObject var conversationStore: ConversationStore
    @ObservedObject var routineStore: RoutineStore
    @State private var isShowingNewAgentSheet = false

    var body: some View {
        NavigationStack {
            List {
                Section("AGENTS") {
                    ForEach(agentStore.agents) { agentProfile in
                        NavigationLink(value: agentProfile.id) {
                            AgentRowView(
                                agentProfile: agentProfile,
                                lastMessage: conversationStore
                                    .activeConversation(forAgentID: agentProfile.id).messages.last
                            )
                        }
                        .listRowBackground(DS.Colors.surface1)
                    }

                    Button {
                        isShowingNewAgentSheet = true
                    } label: {
                        Label("New agent", systemImage: "plus")
                            .font(.system(size: 13, weight: .medium))
                            .foregroundColor(DS.Colors.accentText)
                    }
                    .buttonStyle(.plain)
                    .pointerCursor()
                    .listRowBackground(DS.Colors.surface1)
                }

                if !routineRows.isEmpty {
                    Section("ROUTINES") {
                        ForEach(routineRows) { routineEntry in
                            RoutineRowView(
                                routineEntry: routineEntry,
                                companionManager: companionManager
                            )
                        }
                        .listRowBackground(DS.Colors.surface1)
                    }
                }

                Section("SKILLS") {
                    ForEach(SkillCatalog.bundledSkillSummaries()) { skillSummary in
                        VStack(alignment: .leading, spacing: 2) {
                            Text(skillSummary.name)
                                .font(.system(size: 13, weight: .medium))
                                .foregroundColor(DS.Colors.textPrimary)
                            if !skillSummary.description.isEmpty {
                                Text(skillSummary.description)
                                    .font(.system(size: 11))
                                    .foregroundColor(DS.Colors.textTertiary)
                            }
                        }
                        .listRowBackground(DS.Colors.surface1)
                    }
                }
            }
            .scrollContentBackground(.hidden)
            .background(DS.Colors.background)
            .navigationTitle("Home Space")
            .navigationDestination(for: UUID.self) { agentID in
                AgentConversationView(
                    agentID: agentID,
                    companionManager: companionManager,
                    conversationStore: conversationStore
                )
            }
            .sheet(isPresented: $isShowingNewAgentSheet) {
                NewAgentSheet { newAgentName, newAgentBrief in
                    if let newAgentProfile = agentStore.createAgent(name: newAgentName, personaBrief: newAgentBrief) {
                        // Load the empty conversation outside body evaluation so
                        // the row + detail read preloaded state
                        companionManager.conversationStore.preloadConversations(agentIDs: [newAgentProfile.id])
                    }
                    isShowingNewAgentSheet = false
                }
            }
            .overlay {
                // Consent card floats above everything while a command awaits approval
                if let pendingConsent = companionManager.pendingConsent {
                    ConsentCardView(
                        consentRequest: pendingConsent,
                        onDecision: { decision in
                            companionManager.resolveConsent(decision)
                        }
                    )
                    .padding(24)
                }
            }
        }
    }

    private var routineRows: [RoutineEntry] {
        routineStore.allRoutines(agentProfiles: agentStore.agents)
    }
}

// MARK: - Agent row (dashboard list)

struct AgentRowView: View {
    let agentProfile: AgentProfile
    let lastMessage: ConversationMessage?

    private let relativeFormatter: RelativeDateTimeFormatter = {
        let formatter = RelativeDateTimeFormatter()
        formatter.unitsStyle = .abbreviated
        return formatter
    }()

    var body: some View {
        HStack(spacing: 10) {
            AvatarCircleView(agentProfile: agentProfile, diameter: 34)

            VStack(alignment: .leading, spacing: 2) {
                Text(agentProfile.name)
                    .font(.system(size: 13, weight: .semibold))
                    .foregroundColor(DS.Colors.textPrimary)

                if let lastMessage {
                    Text(lastMessage.text)
                        .font(.system(size: 12))
                        .foregroundColor(DS.Colors.textTertiary)
                        .lineLimit(1)
                } else {
                    Text("no messages yet")
                        .font(.system(size: 12))
                        .foregroundColor(DS.Colors.textTertiary)
                }
            }

            Spacer()

            if let lastMessage {
                Text(relativeFormatter.localizedString(for: lastMessage.timestamp, relativeTo: Date()))
                    .font(.system(size: 11))
                    .foregroundColor(DS.Colors.textTertiary)
            }
        }
        .padding(.vertical, 2)
    }
}

/// Avatar circle with an SF Symbol, tinted with the agent's color.
struct AvatarCircleView: View {
    let agentProfile: AgentProfile
    var diameter: CGFloat = 34

    var body: some View {
        ZStack {
            Circle()
                .fill(agentProfile.avatarColor.opacity(0.22))
            Image(systemName: agentProfile.avatarSymbolName)
                .font(.system(size: diameter * 0.45, weight: .medium))
                .foregroundColor(agentProfile.avatarColor)
        }
        .frame(width: diameter, height: diameter)
    }
}

// MARK: - New agent sheet

struct NewAgentSheet: View {
    @Environment(\.dismiss) private var dismiss
    @State private var newAgentName = ""
    @State private var newAgentBrief = ""
    let onCreate: (String, String) -> Void

    var body: some View {
        VStack(alignment: .leading, spacing: 14) {
            Text("New agent")
                .font(.system(size: 16, weight: .semibold))
                .foregroundColor(DS.Colors.textPrimary)

            VStack(alignment: .leading, spacing: 4) {
                Text("NAME")
                    .font(.system(size: 10, weight: .semibold, design: .rounded))
                    .foregroundColor(DS.Colors.textTertiary)
                TextField("shippy", text: $newAgentName)
                    .textFieldStyle(.plain)
                    .font(.system(size: 13))
                    .foregroundColor(DS.Colors.textPrimary)
                    .padding(.horizontal, 10)
                    .padding(.vertical, 8)
                    .background(
                        RoundedRectangle(cornerRadius: DS.CornerRadius.medium, style: .continuous)
                            .fill(Color.white.opacity(0.08))
                    )
            }

            VStack(alignment: .leading, spacing: 4) {
                Text("WHAT'S IT FOR?")
                    .font(.system(size: 10, weight: .semibold, design: .rounded))
                    .foregroundColor(DS.Colors.textTertiary)
                TextField("watches my inbox and drafts replies", text: $newAgentBrief)
                    .textFieldStyle(.plain)
                    .font(.system(size: 13))
                    .foregroundColor(DS.Colors.textPrimary)
                    .padding(.horizontal, 10)
                    .padding(.vertical, 8)
                    .background(
                        RoundedRectangle(cornerRadius: DS.CornerRadius.medium, style: .continuous)
                            .fill(Color.white.opacity(0.08))
                    )
            }

            HStack {
                Spacer()
                Button("Cancel") { dismiss() }
                    .buttonStyle(.plain)
                    .pointerCursor()
                    .keyboardShortcut(.cancelAction)

                Button("Create") {
                    onCreate(newAgentName, newAgentBrief)
                }
                .buttonStyle(.plain)
                .pointerCursor()
                .keyboardShortcut(.defaultAction)
                .disabled(newAgentName.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty)
            }
        }
        .padding(20)
        .frame(width: 380)
        .background(DS.Colors.surface2)
    }
}

// MARK: - Per-agent conversation view

struct AgentConversationView: View {
    let agentID: UUID
    @ObservedObject var companionManager: CompanionManager
    @ObservedObject var conversationStore: ConversationStore
    @State private var draftMessage = ""
    @FocusState private var isInputFocused: Bool

    private var agentProfile: AgentProfile? {
        companionManager.agentStore.profile(forAgentID: agentID)
    }

    private var conversation: AgentConversation {
        conversationStore.activeConversation(forAgentID: agentID)
    }

    var body: some View {
        VStack(spacing: 0) {
            // Transcript
            ScrollViewReader { scrollProxy in
                ScrollView {
                    LazyVStack(alignment: .leading, spacing: 10) {
                        ForEach(conversation.messages) { conversationMessage in
                            ConversationBubbleView(conversationMessage: conversationMessage)
                                .id(conversationMessage.id)
                        }

                        if companionManager.isAgentTurnRunning(agentID: agentID) {
                            HStack(spacing: 8) {
                                ProgressView()
                                    .scaleEffect(0.6)
                                Text(companionManager.agentActivityDescription(agentID: agentID) ?? "working…")
                                    .font(.system(size: 12))
                                    .foregroundColor(DS.Colors.textTertiary)
                            }
                            .id("activity-indicator")
                        }
                    }
                    .padding(16)
                }
                .onChange(of: conversation.messages.count) { _ in
                    withAnimation {
                        if let lastMessageID = conversation.messages.last?.id {
                            scrollProxy.scrollTo(lastMessageID, anchor: .bottom)
                        } else {
                            scrollProxy.scrollTo("activity-indicator", anchor: .bottom)
                        }
                    }
                }
                .onAppear {
                    scrollProxy.scrollTo(conversation.messages.last?.id, anchor: .bottom)
                }
            }

            Divider()
                .background(DS.Colors.borderSubtle)

            // Text input
            HStack(spacing: 10) {
                TextField("message \(agentProfile?.name ?? "agent")…", text: $draftMessage, axis: .vertical)
                    .textFieldStyle(.plain)
                    .font(.system(size: 13))
                    .foregroundColor(DS.Colors.textPrimary)
                    .focused($isInputFocused)
                    .lineLimit(1...4)
                    .onSubmit { sendDraftMessage() }
                    .onAppear { isInputFocused = true }

                Button(action: sendDraftMessage) {
                    Image(systemName: "arrow.up.circle.fill")
                        .font(.system(size: 22))
                        .foregroundColor(
                            draftMessage.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty
                                ? DS.Colors.textTertiary.opacity(0.4)
                                : DS.Colors.accent
                        )
                }
                .buttonStyle(.plain)
                .pointerCursor()
                .disabled(draftMessage.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty)
            }
            .padding(.horizontal, 16)
            .padding(.vertical, 12)
        }
        .background(DS.Colors.background)
        .navigationTitle(agentProfile?.name ?? "agent")
    }

    private func sendDraftMessage() {
        let outgoingMessage = draftMessage.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !outgoingMessage.isEmpty else { return }
        draftMessage = ""
        companionManager.sendDashboardText(agentID: agentID, text: outgoingMessage)
    }
}

/// One transcript bubble. User messages right-aligned in accent blue;
/// assistant messages left-aligned on surface.
struct ConversationBubbleView: View {
    let conversationMessage: ConversationMessage

    var body: some View {
        HStack {
            if conversationMessage.role == .user { Spacer(minLength: 48) }

            Text(conversationMessage.text)
                .font(.system(size: 13))
                .foregroundColor(conversationMessage.role == .user ? .white : DS.Colors.textPrimary)
                .textSelection(.enabled)
                .padding(.horizontal, 12)
                .padding(.vertical, 8)
                .background(
                    RoundedRectangle(cornerRadius: DS.CornerRadius.extraLarge, style: .continuous)
                        .fill(conversationMessage.role == .user ? DS.Colors.helpChatUserBubble : DS.Colors.surface2)
                )

            if conversationMessage.role == .assistant { Spacer(minLength: 48) }
        }
    }
}

// MARK: - Routine row

struct RoutineRowView: View {
    let routineEntry: RoutineEntry
    @ObservedObject var companionManager: CompanionManager

    var body: some View {
        HStack(spacing: 10) {
            AvatarCircleView(
                agentProfile: companionManager.agentStore.profile(forAgentID: routineEntry.agentID)
                    ?? fallbackProfile,
                diameter: 24
            )

            VStack(alignment: .leading, spacing: 2) {
                Text(routineEntry.routine.title)
                    .font(.system(size: 13, weight: .medium))
                    .foregroundColor(routineEntry.routine.isPaused ? DS.Colors.textTertiary : DS.Colors.textPrimary)
                Text("every \(routineEntry.routine.everyMinutes) min · \(routineEntry.routine.isPaused ? "paused" : "on")")
                    .font(.system(size: 11))
                    .foregroundColor(DS.Colors.textTertiary)
            }

            Spacer()

            HStack(spacing: 6) {
                routineActionButton(icon: "play.fill", helpText: "Run now") {
                    companionManager.runRoutineNow(agentID: routineEntry.agentID, routine: routineEntry.routine)
                }
                routineActionButton(
                    icon: routineEntry.routine.isPaused ? "playpause.fill" : "pause.fill",
                    helpText: routineEntry.routine.isPaused ? "Resume" : "Pause"
                ) {
                    companionManager.setRoutinePaused(
                        agentID: routineEntry.agentID,
                        routineID: routineEntry.routine.id,
                        isPaused: !routineEntry.routine.isPaused
                    )
                }
                routineActionButton(icon: "trash", helpText: "Delete") {
                    companionManager.deleteRoutine(agentID: routineEntry.agentID, routineID: routineEntry.routine.id)
                }
            }
        }
        .padding(.vertical, 2)
    }

    private var fallbackProfile: AgentProfile {
        AgentProfile(
            id: routineEntry.agentID,
            name: "agent",
            avatarSymbolName: "bird.fill",
            avatarColorHex: "#60A5FA",
            personaBrief: "",
            createdAt: Date()
        )
    }

    private func routineActionButton(icon: String, helpText: String, action: @escaping () -> Void) -> some View {
        Button(action: action) {
            Image(systemName: icon)
                .font(.system(size: 10, weight: .semibold))
                .foregroundColor(DS.Colors.textSecondary)
                .frame(width: 22, height: 22)
                .background(Circle().fill(Color.white.opacity(0.08)))
        }
        .buttonStyle(.plain)
        .pointerCursor()
        .help(helpText)
    }
}

// MARK: - Consent card (shared by dashboard and panel)

struct ConsentCardView: View {
    let consentRequest: AgentToolConsentRequest
    let onDecision: (AgentToolConsentDecision) -> Void

    var body: some View {
        VStack(alignment: .leading, spacing: 12) {
            HStack(spacing: 8) {
                Image(systemName: "terminal")
                    .font(.system(size: 13, weight: .medium))
                    .foregroundColor(DS.Colors.warning)
                Text("\(consentRequest.agentName) wants to run a command")
                    .font(.system(size: 13, weight: .semibold))
                    .foregroundColor(DS.Colors.textPrimary)
            }

            Text(consentRequest.command)
                .font(.system(size: 12, design: .monospaced))
                .foregroundColor(DS.Colors.codeText)
                .textSelection(.enabled)
                .padding(10)
                .frame(maxWidth: .infinity, alignment: .leading)
                .background(
                    RoundedRectangle(cornerRadius: DS.CornerRadius.medium, style: .continuous)
                        .fill(Color.white.opacity(0.06))
                )
                .lineLimit(6)

            HStack(spacing: 8) {
                Button("Allow") {
                    onDecision(.allowOnce)
                }
                .buttonStyle(.plain)
                .pointerCursor()
                .keyboardShortcut(.defaultAction)
                .font(.system(size: 12, weight: .semibold))
                .foregroundColor(DS.Colors.textOnAccent)
                .padding(.horizontal, 12)
                .padding(.vertical, 6)
                .background(Capsule().fill(DS.Colors.accent))

                Button("Always this session") {
                    onDecision(.allowAlwaysThisSession)
                }
                .buttonStyle(.plain)
                .pointerCursor()
                .font(.system(size: 12, weight: .medium))
                .foregroundColor(DS.Colors.textSecondary)
                .padding(.horizontal, 12)
                .padding(.vertical, 6)
                .background(Capsule().stroke(DS.Colors.borderSubtle, lineWidth: 0.8))

                Button("Deny") {
                    onDecision(.deny)
                }
                .buttonStyle(.plain)
                .pointerCursor()
                .keyboardShortcut(.cancelAction)
                .font(.system(size: 12, weight: .medium))
                .foregroundColor(DS.Colors.destructiveText)
            }
        }
        .padding(16)
        .background(
            RoundedRectangle(cornerRadius: DS.CornerRadius.extraLarge, style: .continuous)
                .fill(DS.Colors.surface3)
                .shadow(color: .black.opacity(0.5), radius: 16, x: 0, y: 8)
        )
        .overlay(
            RoundedRectangle(cornerRadius: DS.CornerRadius.extraLarge, style: .continuous)
                .stroke(DS.Colors.borderStrong, lineWidth: 0.8)
        )
    }
}
