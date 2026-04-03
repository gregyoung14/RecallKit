import Dispatch
import Foundation

private final class ParallelState<U>: @unchecked Sendable {
    private let lock = NSLock()
    private(set) var results: [U?]
    private(set) var firstError: Error?

    init(count: Int) {
        results = Array(repeating: nil, count: count)
    }

    func shouldContinue() -> Bool {
        lock.lock()
        defer { lock.unlock() }
        return firstError == nil
    }

    func store(_ value: U, at index: Int) {
        lock.lock()
        results[index] = value
        lock.unlock()
    }

    func store(error: Error) {
        lock.lock()
        if firstError == nil {
            firstError = error
        }
        lock.unlock()
    }
}

enum Parallel {
    static func mapOrdered<T: Sendable, U: Sendable>(
        _ items: [T],
        transform: @escaping @Sendable (T) throws -> U
    ) throws -> [U] {
        let state = ParallelState<U>(count: items.count)

        DispatchQueue.concurrentPerform(iterations: items.count) { index in
            guard state.shouldContinue() else {
                return
            }

            do {
                let value = try transform(items[index])
                state.store(value, at: index)
            } catch {
                state.store(error: error)
            }
        }

        if let firstError = state.firstError {
            throw firstError
        }

        return state.results.compactMap { $0 }
    }

    static func compactMapOrdered<T: Sendable, U: Sendable>(
        _ items: [T],
        transform: @escaping @Sendable (T) throws -> U?
    ) throws -> [U] {
        try mapOrdered(items, transform: transform).compactMap { $0 }
    }
}