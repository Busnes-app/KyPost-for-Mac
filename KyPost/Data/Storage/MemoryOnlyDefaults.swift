//
//  MemoryOnlyDefaults.swift
//  KyPost
//
//  A `UserDefaults` that never touches disk, for the stores Hostile Location
//  Protection keeps in memory (`SingletonGraph.hostileMemoryDefaults`).
//
//  The graph is rebuilt whenever the mode flips, so a store only has to be
//  handed the right defaults when it is built — one switch in the graph rather
//  than a memory branch in every store. Every accessor those stores use is
//  overridden here and none calls `super`: anything that reached the real
//  defaults would write the user's data to a plist in exactly the mode that
//  promises it does not.
//

import Foundation

nonisolated final class MemoryOnlyDefaults: UserDefaults, @unchecked Sendable {
    private let lock = NSLock()
    private var values: [String: Any] = [:]

    init() {
        // A suite nobody writes to; every read and write below is answered
        // from `values` and never reaches it.
        super.init(suiteName: nil)!
    }

    /// Forgets everything, for the security wipe.
    func removeAll() {
        lock.lock(); defer { lock.unlock() }
        values.removeAll()
    }

    override func object(forKey defaultName: String) -> Any? {
        lock.lock(); defer { lock.unlock() }
        return values[defaultName]
    }

    override func set(_ value: Any?, forKey defaultName: String) {
        lock.lock(); defer { lock.unlock() }
        values[defaultName] = value
    }

    override func removeObject(forKey defaultName: String) {
        set(nil, forKey: defaultName)
    }

    override func set(_ value: Int, forKey defaultName: String) { set(value as Any?, forKey: defaultName) }
    override func set(_ value: Float, forKey defaultName: String) { set(value as Any?, forKey: defaultName) }
    override func set(_ value: Double, forKey defaultName: String) { set(value as Any?, forKey: defaultName) }
    override func set(_ value: Bool, forKey defaultName: String) { set(value as Any?, forKey: defaultName) }
    override func set(_ url: URL?, forKey defaultName: String) { set(url as Any?, forKey: defaultName) }

    override func string(forKey defaultName: String) -> String? { object(forKey: defaultName) as? String }
    override func array(forKey defaultName: String) -> [Any]? { object(forKey: defaultName) as? [Any] }
    override func stringArray(forKey defaultName: String) -> [String]? { object(forKey: defaultName) as? [String] }
    override func data(forKey defaultName: String) -> Data? { object(forKey: defaultName) as? Data }
    override func url(forKey defaultName: String) -> URL? { object(forKey: defaultName) as? URL }

    override func dictionary(forKey defaultName: String) -> [String: Any]? {
        object(forKey: defaultName) as? [String: Any]
    }

    override func integer(forKey defaultName: String) -> Int {
        (object(forKey: defaultName) as? NSNumber)?.intValue ?? 0
    }

    override func float(forKey defaultName: String) -> Float {
        (object(forKey: defaultName) as? NSNumber)?.floatValue ?? 0
    }

    override func double(forKey defaultName: String) -> Double {
        (object(forKey: defaultName) as? NSNumber)?.doubleValue ?? 0
    }

    override func bool(forKey defaultName: String) -> Bool {
        (object(forKey: defaultName) as? NSNumber)?.boolValue ?? false
    }

    override func dictionaryRepresentation() -> [String: Any] {
        lock.lock(); defer { lock.unlock() }
        return values
    }

    override func persistentDomain(forName domainName: String) -> [String: Any]? { nil }
    override func synchronize() -> Bool { true }
}
