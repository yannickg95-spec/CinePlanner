//
//  ProjectSharingSheet.swift
//  CinePlanner
//
//  Sharing a project. For one of ours that isn't shared yet: what sharing means,
//  and Start Sharing (which moves it to the shared store). Once shared: how it
//  stands with iCloud, the people it's shared with — can edit or view only, invited
//  or joined — and what they changed lately, with Invite People… (a one-time link
//  in the system's share window), Copy Invitation Link and Stop Sharing. For a
//  project shared with us: whose it is, what we may do, and Leave.
//
//  Opened from the project list, keyed by the project's uid: starting to share
//  replaces the project object (it moves stores), so this looks it up each time.
//

import SwiftUI
import SwiftData
import CloudKit
#if os(iOS)
import UIKit
import LinkPresentation
#else
import AppKit
#endif

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
    @State private var removingParticipant: CKShare.Participant?
    @State private var linkCopied = false
    @State private var refresh = 0
    #if os(macOS)
    @State private var inviteAnchor = PickerAnchor()
    #endif

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
            // While open: who's in it now — someone may join or leave meanwhile,
            // and a Mac hears about it from iCloud only now and then.
            .task(id: refresh) { await keepShareFresh() }
            .onChange(of: sync.sharesGeneration) { Task { await reloadShare() } }
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
            Label("They can't save it as a project file of their own. When you stop sharing, you choose whether they keep a copy.",
                  systemImage: "hand.raised")
            Label("Photos and videos in the project count toward your iCloud storage.",
                  systemImage: "icloud")
        }
        Section {
            Button {
                guard access.canCollaborate else { showingPaywall = true; return }
                Task {
                    guard await sync.accountAvailable() else {
                        errorMessage = "Sign in to iCloud in Settings to share projects."
                        return
                    }
                    do {
                        _ = try sync.startSharing(project)
                        refresh += 1
                    } catch {
                        errorMessage = error.localizedDescription
                    }
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
        statusSection(project)
        Section {
            if loadingShare && share == nil {
                ProgressView()
            } else if let share, !people(share).isEmpty {
                ForEach(people(share), id: \.self) { participant in
                    participantRow(participant, in: share)
                }
            } else {
                Text("Nobody has joined yet. Invite people to work on this project with you.")
                    .foregroundStyle(.secondary)
            }
        } header: {
            Text("People")
        }
        .confirmationDialog(removingParticipant.map { "Remove \(name(of: $0))?" } ?? "",
                            isPresented: Binding(get: { removingParticipant != nil },
                                                 set: { if !$0 { removingParticipant = nil } }),
                            presenting: removingParticipant) { participant in
            Button("Remove, Let Them Keep a Copy") { remove(participant, removeCopy: false) }
            Button("Remove and Delete Their Copy", role: .destructive) { remove(participant, removeCopy: true) }
        } message: { participant in
            Text("\(name(of: participant)) can no longer open or change “\(project.filmName)”. They can keep their own copy, which no longer updates — or it can go from their devices.")
        }
        activitySection(project)
        Section {
            // A one-time link of ours, on every platform: ShareLink with a share
            // opened nothing on iOS, and the system's own invitations there didn't
            // open for the people invited.
            Button {
                invite(project)
            } label: {
                Label("Invite People…", systemImage: "person.badge.plus")
            }
            #if os(macOS)
            .background(PickerAnchorView(anchor: inviteAnchor))
            #endif
            .disabled(!access.canCollaborate || working)
            Button {
                copyInvitation(project)
            } label: {
                Label("Copy Invitation Link", systemImage: "link")
            }
            .disabled(!access.canCollaborate || working)
            if let share, !unused(share).isEmpty {
                Button {
                    withdrawUnused()
                } label: {
                    Label(unused(share).count == 1 ? "Withdraw the Unused Invitation"
                                                   : "Withdraw \(unused(share).count) Unused Invitations",
                          systemImage: "xmark.circle")
                }
                .disabled(working)
            }
            Button("Stop Sharing", role: .destructive) { confirmingStop = true }
                .disabled(working)
        } footer: {
            Text(linkCopied
                 ? "Invitation link copied. Paste it in a message to one person — each link lets one person in."
                 : "Each invitation is a link that lets one person open the project in CinePlanner.")
        }
        .confirmationDialog("Stop sharing “\(project.filmName)”?", isPresented: $confirmingStop) {
            Button("Stop Sharing, Let Them Keep a Copy") { stop(project, removeCopies: false) }
            Button("Stop Sharing and Delete Their Copies", role: .destructive) { stop(project, removeCopies: true) }
        } message: {
            Text("The project goes back to being yours alone. The people it was shared with can keep their own copy, which no longer updates — or it can go from their devices.")
        }
    }

    /// Makes an invitation link and offers it to send; one that isn't sent after
    /// all is taken back.
    private func invite(_ project: Project) {
        working = true
        Task {
            defer { working = false }
            do {
                let invitation = try await sync.makeInvitationLink(forProjectUID: project.uid)
                share = try? await sync.fetchShare(forProjectUID: projectUID)
                let done: (Bool) -> Void = { sent in
                    Task {
                        if !sent { await sync.withdrawInvitation(invitation.participantID, projectUID: projectUID) }
                        share = try? await sync.fetchShare(forProjectUID: projectUID)
                    }
                }
                #if os(iOS)
                InvitationShareWindow.present(invitation.url, title: project.filmName, completion: done)
                #else
                InvitationShareWindow.present(invitation.url, from: inviteAnchor.view, completion: done)
                #endif
            } catch {
                errorMessage = error.localizedDescription
            }
        }
    }

    /// Makes an invitation link and puts it on the clipboard, to paste anywhere.
    private func copyInvitation(_ project: Project) {
        working = true
        Task {
            do {
                let invitation = try await sync.makeInvitationLink(forProjectUID: project.uid)
                #if os(iOS)
                UIPasteboard.general.string = invitation.url.absoluteString
                #else
                NSPasteboard.general.clearContents()
                NSPasteboard.general.setString(invitation.url.absoluteString, forType: .string)
                #endif
                working = false
                linkCopied = true
                share = try? await sync.fetchShare(forProjectUID: projectUID)
                try? await Task.sleep(for: .seconds(8))
                linkCopied = false
            } catch {
                working = false
                errorMessage = error.localizedDescription
            }
        }
    }

    // MARK: Status and activity

    @ViewBuilder
    private func statusSection(_ project: Project) -> some View {
        if let status = sync.status(for: project) {
            Section {
                Label {
                    VStack(alignment: .leading, spacing: 2) {
                        Text(status.title)
                        Text(status.detail).font(.caption).foregroundStyle(.secondary)
                    }
                } icon: {
                    Image(systemName: status.labelImage).foregroundStyle(status.tint)
                }
            }
        }
    }

    /// What other people changed lately (since this device started).
    @ViewBuilder
    private func activitySection(_ project: Project) -> some View {
        let recent = sync.activity["Project-\(project.uid)"] ?? []
        if !recent.isEmpty {
            Section("Recent Changes") {
                ForEach(recent.prefix(10)) { item in
                    HStack(alignment: .firstTextBaseline) {
                        Text(item.sentence)
                        Spacer(minLength: 8)
                        Text(item.date, format: .relative(presentation: .named))
                            .font(.caption).foregroundStyle(.secondary)
                    }
                }
            }
        }
    }

    /// Those who joined. (An invitation link is a participant on the share too,
    /// until someone uses it — those are the unused ones.)
    private func people(_ share: CKShare) -> [CKShare.Participant] {
        share.participants.filter { $0.role != .owner && $0.acceptanceStatus == .accepted }
    }

    private func unused(_ share: CKShare) -> [CKShare.Participant] {
        share.participants.filter { $0.role != .owner && $0.acceptanceStatus == .pending }
    }

    /// Links sent or copied that nobody used: they stop working.
    private func withdrawUnused() {
        guard let share else { return }
        working = true
        Task {
            defer { working = false }
            for participant in unused(share) { share.removeParticipant(participant) }
            do {
                try await sync.saveShare(share)
                self.share = try await sync.fetchShare(forProjectUID: projectUID)
            } catch {
                errorMessage = error.localizedDescription
            }
        }
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
                removingParticipant = participant
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
        ProjectSync.name(of: participant) ?? "Someone"
    }

    private func stop(_ project: Project, removeCopies: Bool) {
        working = true
        Task {
            defer { working = false }
            do {
                try await sync.stopSharing(project, removeCopies: removeCopies)
                share = nil
                refresh += 1
            } catch {
                errorMessage = error.localizedDescription
            }
        }
    }

    private func remove(_ participant: CKShare.Participant, removeCopy: Bool) {
        guard let share else { return }
        working = true
        Task {
            defer { working = false }
            do {
                try await sync.removeParticipant(participant, from: share, removeCopy: removeCopy)
                self.share = try await sync.fetchShare(forProjectUID: projectUID)
            } catch {
                errorMessage = error.localizedDescription
            }
        }
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
        statusSection(project)
        Section {
            LabeledContent("Shared by", value: info?.ownerName ?? "Someone")
            LabeledContent("You can", value: info?.canEdit == true ? "Make changes" : "View only")
        }
        activitySection(project)
        Section {
            Button("Leave Shared Project", role: .destructive) { confirmingLeave = true }
        } footer: {
            Text("Only the owner can invite people or change what they may do.")
        }
        .confirmationDialog("Leave “\(project.filmName)”?", isPresented: $confirmingLeave) {
            Button("Leave", role: .destructive) {
                Task { await sync.leave(project) }
                dismiss()
            }
        } message: {
            Text("It disappears from your projects. The owner and everyone else keep working on it.")
        }
    }

    private func reloadShare() async {
        guard !working, let project, SharedProjectStore.contains(project) else { return }
        if let fresh = try? await sync.fetchShare(forProjectUID: project.uid) { share = fresh }
    }

    private func keepShareFresh() async {
        while !Task.isCancelled {
            try? await Task.sleep(for: .seconds(10))
            guard !Task.isCancelled else { return }
            await reloadShare()
        }
    }

    private func loadShare() async {
        guard let project, SharedProjectStore.contains(project) else { return }
        sync.askToNotify()      // so it can say when someone joins
        loadingShare = true
        defer { loadingShare = false }
        share = try? await sync.fetchShare(forProjectUID: project.uid)
    }
}

#if os(iOS)
/// The regular share window for an invitation link, over whatever is showing
/// (the sharing sheet). Tells whether the link went somewhere.
enum InvitationShareWindow {
    static func present(_ url: URL, title: String, completion: @escaping (_ sent: Bool) -> Void) {
        guard let presenter = topViewController() else { completion(false); return }
        let controller = UIActivityViewController(activityItems: [InvitationItem(url: url, title: title)],
                                                  applicationActivities: nil)
        controller.completionWithItemsHandler = { _, completed, _, _ in completion(completed) }
        // On the iPad it's a popover, anchored mid-sheet.
        if let popover = controller.popoverPresentationController {
            popover.sourceView = presenter.view
            popover.sourceRect = CGRect(x: presenter.view.bounds.midX, y: presenter.view.bounds.midY, width: 0, height: 0)
            popover.permittedArrowDirections = []
        }
        presenter.present(controller, animated: true)
    }

    private static func topViewController() -> UIViewController? {
        let scenes = UIApplication.shared.connectedScenes.compactMap { $0 as? UIWindowScene }
        let windows = (scenes.filter { $0.activationState == .foregroundActive }
                       + scenes.filter { $0.activationState != .foregroundActive }).flatMap(\.windows)
        var top = (windows.first(where: \.isKeyWindow) ?? windows.first)?.rootViewController
        while let presented = top?.presentedViewController, !presented.isBeingDismissed { top = presented }
        return top
    }
}

/// The link, with the project's name as its preview and mail subject.
private final class InvitationItem: NSObject, UIActivityItemSource {
    let url: URL
    let title: String

    init(url: URL, title: String) {
        self.url = url
        self.title = title
    }

    private var invitationText: String { "Join “\(title)” in CinePlanner" }

    func activityViewControllerPlaceholderItem(_ controller: UIActivityViewController) -> Any { url }

    func activityViewController(_ controller: UIActivityViewController,
                                itemForActivityType activityType: UIActivity.ActivityType?) -> Any? { url }

    func activityViewController(_ controller: UIActivityViewController,
                                subjectForActivityType activityType: UIActivity.ActivityType?) -> String { invitationText }

    func activityViewControllerLinkMetadata(_ controller: UIActivityViewController) -> LPLinkMetadata? {
        let metadata = LPLinkMetadata()
        metadata.title = invitationText
        metadata.originalURL = url
        metadata.url = url
        return metadata
    }
}
#endif

#if os(macOS)
/// The Mac's share picker for an invitation link, pointing at the Invite button.
/// Tells whether a way to send it was picked.
enum InvitationShareWindow {
    private static var delegate: InvitationPickerDelegate?

    static func present(_ url: URL, from view: NSView?, completion: @escaping (_ sent: Bool) -> Void) {
        guard let view, view.window != nil else { completion(false); return }
        let picker = NSSharingServicePicker(items: [url])
        let delegate = InvitationPickerDelegate(completion: completion)
        picker.delegate = delegate
        Self.delegate = delegate
        picker.show(relativeTo: view.bounds, of: view, preferredEdge: .minY)
    }
}

private final class InvitationPickerDelegate: NSObject, NSSharingServicePickerDelegate {
    let completion: (Bool) -> Void

    init(completion: @escaping (Bool) -> Void) { self.completion = completion }

    // Closed without a choice: the link went nowhere. Once a way to send it is
    // picked it's kept — whether it actually went out can't always be told.
    func sharingServicePicker(_ sharingServicePicker: NSSharingServicePicker, didChoose service: NSSharingService?) {
        completion(service != nil)
    }
}

/// Where the share picker points from.
final class PickerAnchor {
    weak var view: NSView?
}

struct PickerAnchorView: NSViewRepresentable {
    let anchor: PickerAnchor

    func makeNSView(context: Context) -> NSView {
        let view = NSView()
        anchor.view = view
        return view
    }

    func updateNSView(_ nsView: NSView, context: Context) { anchor.view = nsView }
}
#endif

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
