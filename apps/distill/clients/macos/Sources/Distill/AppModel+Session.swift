import AppKit
import DistillKit
import Foundation

/// A call the core refused because the AI session it would resume is gone: what to send again
/// with `newSession` after the user's Continue (docs/specs/session-continuity.md).
struct SessionPrompt: Equatable {
    var jobID: String
    var info: SessionUnavailable
    /// approve | reply | allow | resume
    var action: String
    var text: String?
    var rules: [String]?
    /// Approve: the same version (labels later) and sources (part of a batch) again.
    var approve: ApproveOptions

    init(jobID: String, info: SessionUnavailable, action: String? = nil, text: String? = nil, rules: [String]? = nil,
         approve: ApproveOptions? = nil) {
        self.jobID = jobID
        self.info = info
        self.action = action ?? info.action ?? "reply"
        self.text = text ?? info.text
        self.rules = rules ?? info.rules
        self.approve = approve ?? ApproveOptions(labels: info.labels.flatMap(ApproveLabels.init(rawValue:)), pages: info.pages)
    }
}

struct ReturnedReply: Equatable {
    var jobID: String
    var text: String
    var id = UUID()
}

extension AppModel {
    /// Key of a job marker the user cancelled (a newer marker shows again).
    static func markerKey(_ jobID: String, _ s: SessionUnavailable) -> String { "\(jobID)|\(s.at ?? "")|\(s.action ?? "")" }

    /// What Review shows for this batch: a refused call from this window, else the job's own marker.
    func sessionPrompt(for job: Job) -> SessionPrompt? {
        if let p = sessionPrompts[job.id] { return p }
        guard let m = job.sessionUnavailable, job.state != .running,
              !dismissedSessionMarkers.contains(Self.markerKey(job.id, m)) else { return nil }
        return SessionPrompt(jobID: job.id, info: m)
    }

    func showSessionPrompt(_ s: SessionUnavailable, jobID: String, action: String, text: String? = nil, rules: [String]? = nil,
                           approve: ApproveOptions? = nil) {
        sessionPrompts[jobID] = SessionPrompt(jobID: jobID, info: s, action: action, text: text, rules: rules, approve: approve)
    }

    /// A batch call that may resume the session: a refusal shows the confirmation instead of an error.
    func sessionAware(_ id: String, action: String, text: String? = nil, rules: [String]? = nil,
                      _ call: @escaping (CoreClient) async throws -> Job?) {
        guard let client else { lastError = "The Distill core is not connected."; return }
        Task {
            do {
                let job = try await call(client)
                sessionPrompts[id] = nil
                upsert(job)
            } catch let e as CoreClientError where e.sessionUnavailable != nil {
                showSessionPrompt(e.sessionUnavailable!, jobID: id, action: action, text: text, rules: rules)
            } catch {
                report(error)
            }
        }
    }

    /// SessionReplaceConfirm → Continue: the same call again with `newSession`.
    func continueInNewSession(_ job: Job) {
        guard let prompt = sessionPrompt(for: job) else { return }
        guard let client else { lastError = "The Distill core is not connected."; return }
        sessionPrompts[job.id] = nil
        if let m = job.sessionUnavailable { dismissedSessionMarkers.insert(Self.markerKey(job.id, m)) }
        let id = job.id
        if prompt.action == "approve" { pendingActions["approve:\(id)"] = Date() }
        Task {
            do {
                let updated: Job?
                switch prompt.action {
                case "approve":
                    updated = prompt.approve.isEmpty ? try await client.approve(id, newSession: true)
                        : try await client.approve(id, options: prompt.approve, newSession: true)
                case "allow": updated = try await client.allow(id, rules: prompt.rules ?? [], newSession: true)
                default: updated = try await client.reply(id, text: prompt.text ?? "", newSession: true)
                }
                upsert(updated)
                if updated?.state != .awaitingApproval { pendingActions["approve:\(id)"] = nil }
            } catch {
                pendingActions["approve:\(id)"] = nil
                report(error)
            }
        }
    }

    /// SessionReplaceConfirm → Cancel: nothing changes; a reply goes back in its box.
    func cancelSessionPrompt(_ job: Job) {
        let prompt = sessionPrompt(for: job)
        sessionPrompts[job.id] = nil
        if let m = job.sessionUnavailable { dismissedSessionMarkers.insert(Self.markerKey(job.id, m)) }
        if let p = prompt, p.action == "reply", let text = p.text, !text.isEmpty { returnedReply = ReturnedReply(jobID: job.id, text: text) }
    }

    /// Open in Terminal → Open new session: a fresh interactive session primed with the batch.
    func continueTerminalInNewSession(_ job: Job) {
        terminalSessionPrompt = nil
        guard let client else { lastError = "The Distill core is not connected."; return }
        Task {
            do {
                let resume = try await client.jobResume(job.id, newSession: true)
                guard !resume.argv.isEmpty else {
                    lastError = "No AI runner can open a new session in Terminal."
                    return
                }
                openTerminalScript(try Self.writeTerminalScript(name: job.id, argv: resume.argv, cwd: resume.cwd ?? job.vaultPath))
            } catch {
                report(error)
            }
        }
    }
}
