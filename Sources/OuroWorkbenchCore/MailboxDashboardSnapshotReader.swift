import Foundation

public struct MailboxDashboardSnapshotReader: Sendable {
    public var configuration: MailboxClientConfiguration
    private let dataLoader: @Sendable (URL, TimeInterval) throws -> (Data, Int)
    private let builder: BossDashboardBuilder

    public init(
        configuration: MailboxClientConfiguration = MailboxClientConfiguration(requestTimeoutNanoseconds: 1_000_000_000),
        dataLoader: @escaping @Sendable (URL, TimeInterval) throws -> (Data, Int) = MailboxDashboardSnapshotReader.defaultDataLoader,
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
        var request = URLRequest(url: url)
        request.httpMethod = "GET"
        request.timeoutInterval = timeoutSeconds

        let semaphore = DispatchSemaphore(value: 0)
        let box = SyncMailboxResponseBox()
        let task = URLSession.shared.dataTask(with: request) { data, response, error in
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

        if semaphore.wait(timeout: .now() + timeoutSeconds + 0.25) == .timedOut {
            task.cancel()
            throw MailboxClientError.timeout
        }
        guard let result = box.result else {
            throw MailboxClientError.timeout
        }
        return try result.get()
    }

    private func url(for endpoint: MailboxEndpoint) throws -> URL {
        guard let url = URL(string: endpoint.path, relativeTo: configuration.baseURL)?.absoluteURL else {
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
