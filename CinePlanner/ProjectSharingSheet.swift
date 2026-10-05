//
//  ProjectSharingSheet.swift
//  CinePlanner
//
//  Sharing a project. For one of ours that isn't shared yet: what sharing means,
//  and Start Sharing (which moves it to the shared store). Once shared: the people
//  it's shared with — can edit or view only, invited or joined — with Invite
//  People… (the system's sharing window) and Stop Sharing; the people keep their
//  own copy. For a project shared with us: whose it is, what we may do, and Leave.
//
//  Opened from the project list, keyed by the project's uid: starting to share
//  replaces the project object (it moves stores), so this looks it up each time.
//

import SwiftUI
import SwiftData
import CloudKit
import CoreTransferable

struct ProjectSharingSheet: View {
    let projectUID: String

    @EnvironmentObject private var access: AppAccess
    @Environment(\.dismiss) private var dismiss
    @State private var share: CKShare?
    @State private var loadingShare = false
    @State private var working = false
    @State private var errorMessage: String?
    @State private var showingPaywall = false
    @State private var confirmingStop = false
    @State private var confirmingLeave = false
    @State private var refresh = 0

    private var sync: ProjectSync { ProjectSync.shared }

    /// The project wherever it lives now.
    private var project: Project? {
        _ = refresh
        let descriptor = FetchDescriptor<Project>(predicate: #Predicate { $0.uid == projectUID })
        if let shared = try? SharedProjectStore.contextIfPresent()?.fetch(descriptor).first { return shared }
        return try? ProjectSync.shared.mainContext?.fetch(descriptor).first
    }

    var body: some View {
        NavigationStack {
            Form {
                if let project {
                    if !SharedProjectStore.contains(project) {
                        notSharedYet(project)
                    } else if sync.shareInfo(for: project)?.isOwner == false {
                        sharedWithUs(project)
                    } else {
                        ours(project)
                    }
                } else {
                    Text("This project is no longer here.").foregroundStyle(.secondary)
                }
            }
            .formStyle(.grouped)
            .navigationTitle(project.map { "Share “\($0.filmName)”" } ?? "Share")
            .toolbar {
                ToolbarItem(placement: .confirmationAction) { Button("Done") { dismiss() } }
            }
            .task(id: refresh) { await loadShare() }
            .sheet(isPresented: $showingPaywall) { PaywallView(dismissable: true) }
            .alert("Couldn't Update Sharing", isPresented: Binding(get: { errorMessage != nil },
                                                                  set: { if !$0 { errorMessage = nil } })) {
                Button("OK", role: .cancel) { }
            } message: {
                Text(errorMessage ?? "")
            }
        }
        #if os(macOS)
        .frame(minWidth: 460, minHeight: 420)
        #endif
    }

    // MARK: Not shared yet

    @ViewBuilder
    private func notSharedYet(_ project: Project) -> some View {
        Section {
            Label("Everyone you invite can open “\(project.filmName)” on their own iPhone, iPad or Mac, and changes — yours and theirs — appear for everyone within seconds.",
                  systemImage: "person.2")
            Label("You choose for each person whether they can make changes or only view.",
                  systemImage: "lock.open")
            Label("Photos and videos in the project count toward your iCloud storage.",
                  systemImage: "icloud")
        }
        Section {
            Button {
                guard access.canCollaborate else { showingPaywall = true; return }
                do {
                    _ = try sync.startSharing(project)
                    refresh += 1
                } catch {
                    errorMessage = error.localizedDescription
                }
            } label: {
                Label("Start Sharing", systemImage: "person.crop.circle.badge.plus")
            }
        } footer: {
            if !access.canCollaborate {
                Text("Sharing projects is part of CinePlanner Pro.")
            }
        }
    }

    // MARK: Ours

    @ViewBuilder
    private func ours(_ project: Project) -> some View {
        Section {
            if loadingShare && share == nil {
                ProgressView()
            } else if let share, !people(share).isEmpty {
                ForEach(people(share), id: \.self) { participant in
                    participantRow(participant, in: share)
                }
            } else {
                Text("Nobody yet. Invite people to work on this project with you.")
                    .foregroundStyle(.secondary)
            }
        } header: {
            Text("People")
        }
        Section {
            ShareLink(item: ProjectShareItem(projectUID: project.uid, title: project.filmName, existing: share),
                      preview: SharePreview(project.filmName, image: Image(systemName: "film"))) {
                Label("Invite People…", systemImage: "person.badge.plus")
            }
            .disabled(!access.canCollaborate)
            Button("Stop Sharing", role: .destructive) { confirmingStop = true }
        } footer: {
            Text("Invited people get a link that opens the project in CinePlanner.")
        }
        .confirmationDialog("Stop sharing “\(project.filmName)”?", isPresented: $confirmingStop) {
            Button("Stop Sharing", role: .destructive) {
                do {
                    try sync.stopSharing(project)
                    share = nil
                    refresh += 1
                } catch {
                    errorMessage = error.localizedDescription
                }
            }
        } message: {
            Text("The project goes back to being yours alone. The people it was shared with keep their own copy, which no longer updates.")
        }
    }

    private func people(_ share: CKShare) -> [CKShare.Participant] {
        share.participants.filter { $0.role != .owner && $0.acceptanceStatus != .removed }
    }

    private func participantRow(_ participant: CKShare.Participant, in share: CKShare) -> some View {
        HStack {
            VStack(alignment: .leading, spacing: 2) {
                Text(name(of: participant))
                Text(participant.acceptanceStatus == .accepted ? "Joined" : "Invited")
                    .font(.caption).foregroundStyle(.secondary)
            }
            Spacer()
            Picker("Access", selection: Binding(
                get: { participant.permission == .readOnly ? CKShare.ParticipantPermission.readOnly : .readWrite },
                set: { newValue in
                    participant.permission = newValue
                    save(share)
                })) {
                Text("Can Edit").tag(CKShare.ParticipantPermission.readWrite)
                Text("View Only").tag(CKShare.ParticipantPermission.readOnly)
            }
            .labelsHidden()
            .fixedSize()
            Button(role: .destructive) {
                share.removeParticipant(participant)
                save(share)
            } label: {
                Image(systemName: "person.crop.circle.badge.minus")
            }
            .buttonStyle(.borderless)
            .help("Remove from this project")
            .accessibilityLabel("Remove \(name(of: participant))")
        }
        .disabled(working)
    }

    private func name(of participant: CKShare.Participant) -> String {
        if let components = participant.userIdentity.nameComponents {
            let formatted = PersonNameComponentsFormatter.localizedString(from: components, style: .default)
            if !formatted.isEmpty { return formatted }
        }
        return participant.userIdentity.lookupInfo?.emailAddress
            ?? participant.userIdentity.lookupInfo?.phoneNumber
            ?? "Someone"
    }

    private func save(_ share: CKShare) {
        working = true
        Task {
            defer { working = false }
            do {
                try await sync.saveShare(share)
                self.share = try await sync.fetchShare(forProjectUID: projectUID)
            } catch {
                errorMessage = error.localizedDescription
            }
        }
    }

    // MARK: Shared with us

    @ViewBuilder
    private func sharedWithUs(_ project: Project) -> some View {
        let info = sync.shareInfo(for: project)
        Section {
            LabeledContent("Shared by", value: info?.ownerName ?? "Someone")
            LabeledContent("You can", value: info?.canEdit == true ? "Make changes" : "View only")
        }
        Section {
            Button("Leave Shared Project", role: .destructive) { confirmingLeave = true }
        } footer: {
            Text("Only the owner can invite people or change what they may do.")
        }
        .confirmationDialog("Leave “\(project.filmName)”?", isPresented: $confirmingLeave) {
            Button("Leave", role: .destructive) {
                sync.leave(project)
                dismiss()
            }
        } message: {
            Text("It disappears from your projects. The owner and everyone else keep working on it.")
        }
    }

    private func loadShare() async {
        guard let project, SharedProjectStore.contains(project) else { return }
        loadingShare = true
        defer { loadingShare = false }
        share = try? await sync.fetchShare(forProjectUID: project.uid)
    }
}

/// A project for the system's sharing window: its existing share, or one made
/// when the user picks how to invite.
nonisolated struct ProjectShareItem: Transferable {
    let projectUID: String
    let title: String
    let existing: CKShare?

    static var transferRepresentation: some TransferRepresentation {
        CKShareTransferRepresentation { item in
            let container = CKContainer(identifier: ProjectSync.containerIdentifier)
            if let share = item.existing {
                return .existing(share, container: container)
            }
            return .prepareShare(container: container) {
                try await ProjectSync.shared.createShare(forProjectUID: item.projectUID)
            }
        }
    }
}

/// A project to open the sharing window for, by uid.
struct SharingTarget: Identifiable {
    let uid: String
    var id: String { uid }
}

/// Sync's notes and problems ("Joined “Defrost”", a full iCloud) along the bottom
/// of the project list.
struct SyncNoticeBanner: View {
    private var sync: ProjectSync { ProjectSync.shared }

    var body: some View {
        if let text = sync.problem ?? sync.notice {
            Label(text, systemImage: sync.problem == nil ? "person.2" : "exclamationmark.icloud")
                .font(.callout)
                .padding(.horizontal, 14).padding(.vertical, 9)
                .background(.regularMaterial, in: Capsule())
                .padding(.bottom, 16)
                .transition(.move(edge: .bottom).combined(with: .opacity))
        }
    }
}
