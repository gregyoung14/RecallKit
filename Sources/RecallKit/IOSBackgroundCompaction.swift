#if canImport(BackgroundTasks) && os(iOS)
import BackgroundTasks
import Foundation

private final class ProcessingTaskBox: @unchecked Sendable {
    let task: BGProcessingTask

    init(task: BGProcessingTask) {
        self.task = task
    }
}

@available(iOS 17.0, *)
/// Registers and schedules background compaction work for RecallKit on iOS.
public final class IOSBackgroundCompactionCoordinator {
    private let taskIdentifier: String
    private let serviceFactory: @Sendable () -> RecallKitIndexService

    public init(
        taskIdentifier: String,
        serviceFactory: @escaping @Sendable () -> RecallKitIndexService
    ) {
        self.taskIdentifier = taskIdentifier
        self.serviceFactory = serviceFactory
    }

    /// Registers the background task handler with `BGTaskScheduler`.
    public func register() {
        BGTaskScheduler.shared.register(forTaskWithIdentifier: taskIdentifier, using: nil) { [serviceFactory] task in
            guard let processingTask = task as? BGProcessingTask else {
                task.setTaskCompleted(success: false)
                return
            }

            let processingTaskBox = ProcessingTaskBox(task: processingTask)

            let worker = Task {
                do {
                    let service = serviceFactory()
                    try await service.bootstrap()
                    try await service.compact()
                    processingTaskBox.task.setTaskCompleted(success: true)
                } catch {
                    processingTaskBox.task.setTaskCompleted(success: false)
                }
            }

            processingTask.expirationHandler = {
                worker.cancel()
            }
        }
    }

    /// Schedules a future background compaction request.
    public func schedule(earliestBeginDate: Date? = nil, requiresExternalPower: Bool = false) throws {
        let request = BGProcessingTaskRequest(identifier: taskIdentifier)
        request.requiresNetworkConnectivity = false
        request.requiresExternalPower = requiresExternalPower
        request.earliestBeginDate = earliestBeginDate
        try BGTaskScheduler.shared.submit(request)
    }
}
#endif