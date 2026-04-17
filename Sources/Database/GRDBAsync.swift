import Foundation
import GRDB

enum GRDBAsync {
    static func read<T: Sendable>(
        from dbQueue: DatabaseQueue,
        qos: DispatchQoS.QoSClass = .userInitiated,
        _ block: @escaping (Database) throws -> T
    ) async throws -> T {
        try await withCheckedThrowingContinuation { continuation in
            DispatchQueue.global(qos: qos).async {
                do {
                    let value = try dbQueue.read(block)
                    continuation.resume(returning: value)
                } catch {
                    continuation.resume(throwing: error)
                }
            }
        }
    }

    static func write<T: Sendable>(
        to dbQueue: DatabaseQueue,
        qos: DispatchQoS.QoSClass = .userInitiated,
        _ block: @escaping (Database) throws -> T
    ) async throws -> T {
        try await withCheckedThrowingContinuation { continuation in
            DispatchQueue.global(qos: qos).async {
                do {
                    let value = try dbQueue.write(block)
                    continuation.resume(returning: value)
                } catch {
                    continuation.resume(throwing: error)
                }
            }
        }
    }
}
