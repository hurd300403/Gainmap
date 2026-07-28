//
//  UHDRToolProcess.swift
//  GainmapCore
//
//  The side-effecting half of the uhdrtool wrapper: spawning the bundled CLI
//  as a child Process, wiring its stderr, and mapping cancellation/quit onto
//  child termination. macOS-only — iOS has no Process; the in-process encoder
//  replaces this whole file at the `runTool` seam in P2.
//

#if os(macOS)

import Foundation
import AppKit

// MARK: - Child-process lifetime

/// Terminates bundled-tool children when the app quits, so quitting mid-merge
/// can't orphan uhdrtool to keep writing files after the window is gone.
final class ToolReaper: @unchecked Sendable {
    static let shared = ToolReaper()
    private let lock = NSLock()
    private var procs: [ObjectIdentifier: Process] = [:]

    private init() {
        NotificationCenter.default.addObserver(
            forName: NSApplication.willTerminateNotification, object: nil, queue: nil
        ) { [weak self] _ in self?.terminateAll() }
    }

    func register(_ p: Process) { lock.lock(); procs[ObjectIdentifier(p)] = p; lock.unlock() }
    func unregister(_ p: Process) { lock.lock(); procs.removeValue(forKey: ObjectIdentifier(p)); lock.unlock() }
    func terminateAll() {
        lock.lock(); let ps = Array(procs.values); procs.removeAll(); lock.unlock()
        for p in ps where p.isRunning { p.terminate() }
    }
}

/// Hands a Process across the Task-cancellation boundary: whichever side gets
/// there first wins (cancel-before-launch still terminates right after launch).
private final class ProcessBox: @unchecked Sendable {
    private let lock = NSLock()
    private var proc: Process?
    private var wantsTermination = false

    func set(_ p: Process) {
        lock.lock(); proc = p; let t = wantsTermination; lock.unlock()
        if t, p.isRunning { p.terminate() }
    }
    func terminate() {
        lock.lock(); wantsTermination = true; let p = proc; lock.unlock()
        if let p, p.isRunning { p.terminate() }
    }
    var terminated: Bool { lock.lock(); defer { lock.unlock() }; return wantsTermination }
}

// MARK: - Execution (the only side-effecting method)

extension UHDRRunner {

    /// Run uhdrtool for `job`. Runs off the main actor; safe to `await` from UI.
    /// Task cancellation terminates the child promptly and removes the partial
    /// output; app quit terminates it via ToolReaper.
    public func run(_ job: Job, toolURL: URL? = nil) async -> RunOutcome {
        let tool: URL
        do {
            tool = try toolURL ?? Self.bundledToolURL()
        } catch {
            return .failure(message: (error as? LocalizedError)?.errorDescription ?? "\(error)")
        }

        let box = ProcessBox()
        return await withTaskCancellationHandler {
            await withCheckedContinuation { cont in
                // Process I/O (blocking reads + waitUntilExit) runs off the main
                // thread so the UI stays responsive during a merge.
                DispatchQueue.global(qos: .userInitiated).async {
                    let proc = Process()
                    proc.executableURL = tool
                    proc.arguments = Self.arguments(for: job)

                    let errPipe = Pipe()
                    proc.standardError = errPipe
                    // Discard stdout via the null device — an unread Pipe() would fill
                    // its 64KB buffer and deadlock the tool (blocked write → no exit →
                    // readDataToEndOfFile on stderr never returns) if uhdrtool ever
                    // grew stdout logging.
                    proc.standardOutput = FileHandle.nullDevice

                    do {
                        try proc.run()
                    } catch {
                        cont.resume(returning: .failure(message: "Could not launch uhdrtool: \(error.localizedDescription)"))
                        return
                    }
                    ToolReaper.shared.register(proc)
                    box.set(proc)   // late-binding: a cancel that already happened fires now

                    let errData = errPipe.fileHandleForReading.readDataToEndOfFile()
                    proc.waitUntilExit()
                    ToolReaper.shared.unregister(proc)

                    if box.terminated {
                        try? FileManager.default.removeItem(at: job.out)   // partial write
                        cont.resume(returning: .failure(message: "Stopped."))
                        return
                    }
                    let stderr = String(data: errData, encoding: .utf8) ?? ""
                    cont.resume(returning: Self.parseOutcome(
                        exitCode: proc.terminationStatus, stderr: stderr, output: job.out))
                }
            }
        } onCancel: {
            box.terminate()
        }
    }
}

#endif
