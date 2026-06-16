import Foundation

public struct MailboxDashboardSnapshotReader: Sendable {
    public var configuration: MailboxClientConfiguration
    private let dataLoader: @Sendable (URL, TimeInterval) throws -> (Data, Int)
    private let builder: BossDashboardBuilder

    public init() {
        self.init(configuration: MailboxClientConfiguration(requestTimeoutNanoseconds: 1_000_000_000))
    }

    public init(configuration: MailboxClientConfiguration) {
        self.configuration = configuration
        self.dataLoader = Self.defaultDataLoader
        self.builder = BossDashboardBuilder()
    }

    public init(
        configuration: MailboxClientConfiguration = MailboxClientConfiguration(requestTimeoutNanoseconds: 1_000_000_000),
        dataLoader: @escaping @Sendable (URL, TimeInterval) throws -> (Data, Int),
        builder: BossDashboardBuilder = BossDashboardBuilder()
    ) {
        self.configuration = configuration
        self.dataLoader = dataLoader
        self.builder = builder
    }

    public func read(boss: BossAgentSelection) -> BossDashboardSnapshot {
        let machine: FetchResult<MailboxMachineView> = fetch(.machine, label: "machine")
        let needsMe: FetchResult<MailboxNeedsMeView> = fetch(.needsMe(boss.agentName), label: "needs-me")
        let coding: FetchResult<MailboxCodingSummary> = fetch(.coding(boss.agentName), label: "coding")
        let habitHistory: FetchResult<MailboxHabitSessionSummaryView> = fetch(.habitRunSummaries(boss.agentName, limit: 5), label: "habit-history")

        return builder.build(
            boss: boss,
            machine: machine.value,
            needsMe: needsMe.value,
            coding: coding.value,
            habitHistory: habitHistory.value,
            availability: .mailbox(
                machineIssue: machine.issue,
                needsMeIssue: needsMe.issue,
                codingIssue: coding.issue,
                habitHistoryIssue: habitHistory.issue
            )
        )
    }

    public static func defaultDataLoader(url: URL, timeoutSeconds: TimeInterval) throws -> (Data, Int) {
        try syncDataLoader(
            url: url,
            timeoutSeconds: timeoutSeconds,
            makeTask: { request, completion in
                let task = URLSession.shared.dataTask(with: request, completionHandler: completion)
                return MailboxSyncTask(resume: { task.resume() }, cancel: { task.cancel() })
            }
        )
    }

    static func syncDataLoader(
        url: URL,
        timeoutSeconds: TimeInterval,
        makeTask: @Sendable (URLRequest, @escaping @Sendable (Data?, URLResponse?, Error?) -> Void) -> MailboxSyncTask,
        waitOverride: (@Sendable (DispatchSemaphore, DispatchTime) -> DispatchTimeoutResult)? = nil
    ) throws -> (Data, Int) {
        var request = URLRequest(url: url)
        request.httpMethod = "GET"
        request.timeoutInterval = timeoutSeconds

        let semaphore = DispatchSemaphore(value: 0)
        let box = SyncMailboxResponseBox()
        let task = makeTask(request) { data, response, error in
            if let error {
                box.result = .failure(error)
            } else if let http = response as? HTTPURLResponse {
                box.result = .success((data ?? Data(), http.statusCode))
            } else {
                box.result = .failure(MailboxClientError.invalidURL)
            }
            semaphore.signal()
        }
        task.resume()

        let waitResult = waitOverride?(semaphore, .now() + timeoutSeconds + 0.25) ?? semaphore.wait(timeout: .now() + timeoutSeconds + 0.25)
        if waitResult == .timedOut {
            task.cancel()
            throw MailboxClientError.timeout
        }
        guard let result = box.result else {
            throw MailboxClientError.timeout
        }
        return try result.get()
    }

    struct MailboxSyncTask: Sendable {
        var resume: @Sendable () -> Void
        var cancel: @Sendable () -> Void
    }

    private func url(for endpoint: MailboxEndpoint) throws -> URL {
        try Self.resolvedURL(path: endpoint.path, baseURL: configuration.baseURL)
    }

    static func resolvedURL(path: String, baseURL: URL) throws -> URL {
        guard let url = URL(string: path, relativeTo: baseURL)?.absoluteURL else {
            throw MailboxClientError.invalidURL
        }
        return url
    }

    private func fetch<T: Decodable & Sendable>(_ endpoint: MailboxEndpoint, label: String) -> FetchResult<T> {
        do {
            let timeoutSeconds = max(0.1, Double(configuration.requestTimeoutNanoseconds) / 1_000_000_000)
            let (data, statusCode) = try dataLoader(try url(for: endpoint), timeoutSeconds)
            guard (200..<300).contains(statusCode) else {
                throw MailboxClientError.badStatus(statusCode)
            }
            return FetchResult(value: try JSONDecoder().decode(T.self, from: data), issue: nil)
        } catch {
            return FetchResult(value: nil, issue: "\(label): \(error.localizedDescription)")
        }
    }
}

private struct FetchResult<T: Sendable>: Sendable {
    var value: T?
    var issue: String?
}

private final class SyncMailboxResponseBox: @unchecked Sendable {
    var result: Result<(Data, Int), Error>?
}
