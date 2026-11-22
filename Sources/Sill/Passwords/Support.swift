// Adapted from Search by Office Commun (MIT License, (c) 2026 Office Commun),
// https://github.com/driceroland/Search. The glue Sill's port needs.
import Foundation

enum Store { static let testing = false }

/// The few site helpers the Apple Passwords port uses.
enum Vault {
    /// example.com for www.example.com and accounts.example.com; bbc.co.uk stays bbc.co.uk.
    static func registrable(_ host: String) -> String { Domains.registrable(host) }

    static func host(of text: String) -> String {
        var value = text.trimmingCharacters(in: .whitespaces)
        if !value.contains("://") { value = "https://" + value }
        guard let url = URL(string: value), ["http", "https"].contains(url.scheme?.lowercased() ?? ""),
              let host = url.host()?.lowercased()
        else { return "" }
        return host.hasPrefix("www.") ? String(host.dropFirst(4)) : host
    }
}

struct NativeHostRefused: LocalizedError {
    let why: String
    var errorDescription: String? { why }
}

/// One host program and the framing Chrome uses to talk to it.
@available(macOS 15.4, *)
final class HostPipe: @unchecked Sendable {
    /// How long a host that has exited may leave its output open (a child
    /// of its own still holding it) before the connection ends anyway.
    static let exitGrace: TimeInterval = 1.5
    /// How long a host has, once asked to stop, before it is killed, as in Chrome.
    static let killGrace: TimeInterval = 2
    /// The most a host may send in one message, as in Chrome; a message to it is held to the same.
    static let frameCap = 1 << 20

    private let process = Process()
    private let input = Pipe()
    private let output = Pipe()
    private var buffer = Data()
    private let lock = NSLock()
    /// Held around each use of the input handle, so it is never written once closed.
    private let writing = NSLock()
    var onMessage: ((Any) -> Void)?
    var onExit: (() -> Void)?
    /// Once the host's process has exited: how it ended (its status or the
    /// signal) and what came first, in plain words for a log. Nothing it sent.
    var onTerminated: ((String) -> Void)?
    private var waiters: [(id: Int, continuation: CheckedContinuation<Any?, Error>)] = []
    private var nextWaiter = 0
    private var stopped = false
    private var outputClosed = false
    private var finished = false
    private var inputClosed = false
    private var ending = false

    private static var exited: Error { NativeHostRefused(why: "Native host has exited.") }

    init(program: URL, origin: String) {
        process.executableURL = program
        process.arguments = [origin]
        process.standardInput = input
        process.standardOutput = output
        process.standardError = FileHandle.nullDevice
        // A host that is already gone — refused to run, killed as it
        // started — would take the browser with it: writing to its closed
        // pipe raises SIGPIPE. Refused, the write only fails.
        _ = fcntl(input.fileHandleForWriting.fileDescriptor, F_SETNOSIGPIPE, 1)
    }

    func start() throws {
        output.fileHandleForReading.readabilityHandler = { [weak self] handle in
            let chunk = handle.availableData
            guard let self else { return }
            if chunk.isEmpty {
                handle.readabilityHandler = nil
                self.lock.lock()
                self.outputClosed = true
                self.lock.unlock()
                self.finish()
                // As in Chrome, a host whose output has closed is done with,
                // even if it runs on.
                self.end()
                return
            }
            self.take(chunk)
        }
        // A host may exit the moment its last reply is written, before that
        // reply has been read: the end is when its output closes, as in
        // Chrome. But a child of the host's may hold that output open long
        // after, so an exit ends things after a grace in any case.
        process.terminationHandler = { [weak self] process in
            guard let self else { return }
            self.lock.lock()
            let now = self.stopped || self.outputClosed
            let first = self.stopped ? "stopped by the browser" : self.outputClosed ? "its output closed first" : "exited on its own"
            self.lock.unlock()
            let how = process.terminationReason == .uncaughtSignal
                ? "signal \(process.terminationStatus)" : "status \(process.terminationStatus)"
            self.onTerminated?("\(how), \(first)")
            if now {
                self.finish()
            } else {
                DispatchQueue.global().asyncAfter(deadline: .now() + Self.exitGrace) { self.finish(); self.end() }
            }
        }
        try process.run()
    }

    func stop() {
        lock.lock()
        stopped = true
        lock.unlock()
        output.fileHandleForReading.readabilityHandler = nil
        if process.isRunning { end() } else { finish() }
    }

    func write(_ message: Any) throws {
        let json = try JSONSerialization.data(withJSONObject: message, options: [.fragmentsAllowed])
        guard json.count <= Self.frameCap else { throw NativeHostRefused(why: "Message too long for a native host") }
        var length = UInt32(json.count).littleEndian
        var frame = Data(bytes: &length, count: 4)
        frame.append(json)
        writing.lock()
        defer { writing.unlock() }
        guard !inputClosed else { throw Self.exited }
        try input.fileHandleForWriting.write(contentsOf: frame)
    }

    func readOne() async throws -> Any? {
        try await withCheckedThrowingContinuation { continuation in
            if wait(continuation) == nil { continuation.resume(throwing: Self.exited) }
        }
    }

    /// Writes `message` and reads the reply. The reply's waiter is in place
    /// before the message goes, so a host quick to answer isn't missed.
    func request(_ message: Any) async throws -> Any? {
        try await withCheckedThrowingContinuation { continuation in
            guard let id = wait(continuation) else { return continuation.resume(throwing: Self.exited) }
            do {
                try write(message)
            } catch {
                // Unless a reply or the end got to it first.
                lock.lock()
                let index = waiters.firstIndex { $0.id == id }
                if let index { waiters.remove(at: index) }
                lock.unlock()
                if index != nil { continuation.resume(throwing: error) }
            }
        }
    }

    /// Adds a waiter for the next message, or nil once the connection has ended.
    private func wait(_ continuation: CheckedContinuation<Any?, Error>) -> Int? {
        lock.lock()
        defer { lock.unlock() }
        guard !finished else { return nil }
        nextWaiter += 1
        waiters.append((nextWaiter, continuation))
        return nextWaiter
    }

    private func take(_ chunk: Data) {
        lock.lock()
        guard !finished else { return lock.unlock() }
        buffer.append(chunk)
        var messages: [Any] = []
        var overlong = false
        while buffer.count >= 4 {
            let length = Int(buffer.prefix(4).withUnsafeBytes { $0.loadUnaligned(as: UInt32.self).littleEndian })
            if length > Self.frameCap { overlong = true; buffer = Data(); break }
            guard buffer.count >= 4 + length else { break }
            let body = buffer.subdata(in: 4..<(4 + length))
            buffer.removeSubrange(0..<(4 + length))
            if let message = try? JSONSerialization.jsonObject(with: body, options: [.fragmentsAllowed]) {
                messages.append(message)
            }
        }
        var handed: [(CheckedContinuation<Any?, Error>, Any)] = []
        for message in messages where !waiters.isEmpty {
            handed.append((waiters.removeFirst().continuation, message))
        }
        let rest = messages.dropFirst(handed.count)
        lock.unlock()
        handed.forEach { $0.0.resume(returning: $0.1) }
        rest.forEach { onMessage?($0) }
        // As in Chrome, a host claiming a message past the cap is done with;
        // what it sent before that in the same read is still heard.
        if overlong { finish(); end() }
    }

    /// Stops the host as Chrome does: its input closed and SIGTERM, then
    /// SIGKILL if it is still running after a grace.
    private func end() {
        lock.lock()
        let first = !ending
        ending = true
        lock.unlock()
        guard first else { return }
        // Off the caller's thread: a write stuck on a host that doesn't read
        // holds `writing` until the signals below free it.
        DispatchQueue.global().async {
            self.writing.lock()
            if !self.inputClosed {
                self.inputClosed = true
                try? self.input.fileHandleForWriting.close()
            }
            self.writing.unlock()
        }
        guard process.isRunning else { return }
        let pid = process.processIdentifier
        guard pid > 0 else { return }
        process.terminate()
        DispatchQueue.global().asyncAfter(deadline: .now() + Self.killGrace) {
            if self.process.isRunning { kill(pid, SIGKILL) }
        }
    }

    private func finish() {
        lock.lock()
        guard !finished else { return lock.unlock() }
        finished = true
        let pending = waiters
        waiters = []
        let exit = onExit
        onExit = nil
        lock.unlock()
        output.fileHandleForReading.readabilityHandler = nil
        pending.forEach { $0.continuation.resume(throwing: Self.exited) }
        exit?()
    }
}
