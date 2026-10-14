//
//  PresenceContext.swift
//  KyPost
//
//  The one authenticated `LAContext` the vault reuses, so the private key's
//  presence prompt appears at most once per app unlock.
//
//  The policy (chosen by the user): opening encrypted mail does not prompt
//  again until the app locks. The app unlock's own evaluated context is
//  adopted here (`AppLockManager.requestUnlock`); with the app lock off, or
//  after a PIN unlock, the first vault open prompts once and its context is
//  kept instead. Every lock trigger — `AppLockManager.lock()` and
//  `lockAfterGrace()`, so iOS backgrounding and the macOS screen lock — and
//  every vault teardown invalidates it, and the next open prompts again.
//
//  What the context unlocks is a Secure Enclave key operation, never key
//  bytes: the record stays sealed on disk and the plaintext lives in
//  `EnrollmentSession`, which has its own, shorter lifetime.
//

import Foundation
import LocalAuthentication

nonisolated final class PresenceContext: @unchecked Sendable {
    static let shared = PresenceContext()

    /// One context handed out for one presence-checked operation.
    struct Lease {
        let context: LAContext
        /// The invalidation count when the lease was taken. A lease from
        /// before a lock is never kept.
        let generation: UInt64
        /// True when this is the held context, already authenticated.
        let wasHeld: Bool
    }

    private let lock = NSLock()
    private var held: LAContext?
    private var generation: UInt64 = 0

    /// True while an authenticated context is held.
    var isHeld: Bool {
        lock.lock(); defer { lock.unlock() }
        return held != nil
    }

    /// The held context, or a fresh one that will prompt on first use.
    func lease(reason: String) -> Lease {
        lock.lock(); defer { lock.unlock() }
        if let held { return Lease(context: held, generation: generation, wasHeld: true) }
        let context = LAContext()
        context.localizedReason = reason
        return Lease(context: context, generation: generation, wasHeld: false)
    }

    /// A presence-checked operation succeeded under `lease`: hold its context
    /// for the rest of this unlock. Returns false, holding nothing, when the
    /// lock engaged meanwhile — the caller must then discard the operation's
    /// result, not just the context.
    @discardableResult
    func keep(_ lease: Lease) -> Bool {
        lock.lock(); defer { lock.unlock() }
        guard lease.generation == generation else { return false }
        if held == nil { held = lease.context }
        return true
    }

    /// The app unlock's evaluated context, so the vault does not prompt again
    /// right after the user just authenticated.
    func adopt(_ context: LAContext) {
        lock.lock(); defer { lock.unlock() }
        if let held, held !== context { held.invalidate() }
        held = context
    }

    /// The held context stopped working (the system can invalidate one):
    /// forget it, if it is still the one held, so the next lease prompts.
    func discard(_ lease: Lease) {
        lock.lock(); defer { lock.unlock() }
        guard held === lease.context else { return }
        held = nil
    }

    /// The lock engaged, or the vault was torn down. The next presence-checked
    /// operation prompts.
    func invalidate() {
        lock.lock(); defer { lock.unlock() }
        held?.invalidate()
        held = nil
        generation &+= 1
    }
}
