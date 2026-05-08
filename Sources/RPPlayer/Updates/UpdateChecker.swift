import Foundation

public protocol UpdateChecking: Sendable, AnyObject {
    func start() async
    func checkNow() async
    func dismissCurrentForButton() async
    var stateUpdates: AsyncStream<UpdateState> { get async }
    var currentState: UpdateState { get async }
}

public final class NoopUpdateChecker: UpdateChecking {
    public init() {}
    public func start() async {}
    public func checkNow() async {}
    public func dismissCurrentForButton() async {}
    public var stateUpdates: AsyncStream<UpdateState> {
        get async {
            AsyncStream { continuation in
                continuation.yield(.unknown)
                continuation.finish()
            }
        }
    }
    public var currentState: UpdateState { get async { .unknown } }
}

public actor UpdateChecker: UpdateChecking {
    private let currentVersion: SemVer
    private let repoOwner: String
    private let repoName: String
    private let urlSession: URLSession
    private let configStore: any ConfigStore
    private let logger: AppLogger
    private let clock: @Sendable () -> Date

    private var state: UpdateState = .unknown
    private var continuations: [UUID: AsyncStream<UpdateState>.Continuation] = [:]
    private var settingsTask: Task<Void, Never>?

    public init(
        currentVersion: SemVer,
        repoOwner: String,
        repoName: String,
        urlSession: URLSession,
        configStore: any ConfigStore,
        logger: AppLogger,
        clock: @escaping @Sendable () -> Date
    ) {
        self.currentVersion = currentVersion
        self.repoOwner = repoOwner
        self.repoName = repoName
        self.urlSession = urlSession
        self.configStore = configStore
        self.logger = logger
        self.clock = clock
    }

    public var currentState: UpdateState { state }

    public var stateUpdates: AsyncStream<UpdateState> {
        let id = UUID()
        let snapshot = state
        return AsyncStream { continuation in
            self.continuations[id] = continuation
            continuation.yield(snapshot)
            continuation.onTermination = { [weak self] _ in
                Task { [weak self] in await self?.unregister(id: id) }
            }
        }
    }

    public func start() async {
        let snapshot = await configStore.settings
        if let cached = snapshot.cachedLatestRelease, cached.version > currentVersion {
            let dismissed = snapshot.dismissedUpdateVersion == cached.tagName
            emit(.available(cached, dismissedFromButton: dismissed))
        } else if let last = snapshot.lastUpdateCheckAt {
            emit(.upToDate(checkedAt: last))
        }

        guard snapshot.updateCheckEnabled else { return }

        await checkNow()
        scheduleDailyTicker()

        settingsTask?.cancel()
        let stream = await configStore.changes
        settingsTask = Task { [weak self] in
            var lastEnabled: Bool?
            for await snapshot in stream {
                guard let self else { return }
                let enabled = snapshot.updateCheckEnabled
                if let last = lastEnabled, last == enabled { continue }
                lastEnabled = enabled
                if !enabled {
                    await self.handleToggleOff()
                }
            }
        }
    }

    private func handleToggleOff() async {
        do {
            try await configStore.update { $0.cachedLatestRelease = nil }
        } catch {
            logger.debug("update checker config write failed: \(error)")
        }
        emit(.unknown)
    }

    private func scheduleDailyTicker() {
        Task { [weak self] in
            while !Task.isCancelled {
                try? await Task.sleep(nanoseconds: UInt64(3600 * 1_000_000_000))
                guard let self else { return }
                await self.tickIfDue()
            }
        }
    }

    func tickIfDue() async {
        let snapshot = await configStore.settings
        guard snapshot.updateCheckEnabled else { return }
        let now = clock()
        if let last = snapshot.lastUpdateCheckAt, now.timeIntervalSince(last) < 24 * 3600 {
            return
        }
        await checkNow()
    }

    public func checkNow() async {
        guard let url = URL(string: "https://api.github.com/repos/\(repoOwner)/\(repoName)/releases/latest") else {
            logger.debug("update check could not build URL for \(repoOwner)/\(repoName)")
            return
        }
        var request = URLRequest(url: url)
        request.setValue("application/vnd.github+json", forHTTPHeaderField: "Accept")
        request.setValue("2022-11-28", forHTTPHeaderField: "X-GitHub-Api-Version")

        let data: Data
        let response: URLResponse
        do {
            (data, response) = try await urlSession.data(for: request)
        } catch {
            logger.debug("update check failed: \(error)")
            return
        }
        guard let http = response as? HTTPURLResponse, (200..<300).contains(http.statusCode) else {
            logger.debug("update check non-2xx: \((response as? HTTPURLResponse)?.statusCode ?? -1)")
            return
        }

        let release: GitHubRelease
        do {
            release = try GitHubRelease.decode(from: data)
        } catch {
            logger.debug("update check decode failed: \(error)")
            return
        }

        let now = clock()

        if release.draft || release.prerelease {
            await applyUpToDate(now: now)
            return
        }

        guard let info = ReleaseInfo(release: release) else {
            logger.debug("update check tag unparseable: \(release.tagName)")
            return
        }

        if info.version > currentVersion {
            let dismissed = await readDismissedTag() == info.tagName
            await applyAvailable(info: info, dismissedFromButton: dismissed, now: now)
        } else {
            await applyUpToDate(now: now)
        }
    }

    public func dismissCurrentForButton() async {
        guard case .available(let info, _) = state else { return }
        do {
            try await configStore.update { $0.dismissedUpdateVersion = info.tagName }
        } catch {
            logger.debug("update checker config write failed: \(error)")
        }
        emit(.available(info, dismissedFromButton: true))
    }

    private func readDismissedTag() async -> String? {
        await configStore.settings.dismissedUpdateVersion
    }

    private func applyAvailable(info: ReleaseInfo, dismissedFromButton: Bool, now: Date) async {
        do {
            try await configStore.update {
                $0.lastUpdateCheckAt = now
                $0.cachedLatestRelease = info
            }
        } catch {
            logger.debug("update checker config write failed: \(error)")
        }
        emit(.available(info, dismissedFromButton: dismissedFromButton))
    }

    private func applyUpToDate(now: Date) async {
        do {
            try await configStore.update {
                $0.lastUpdateCheckAt = now
                $0.cachedLatestRelease = nil
            }
        } catch {
            logger.debug("update checker config write failed: \(error)")
        }
        emit(.upToDate(checkedAt: now))
    }

    private func emit(_ next: UpdateState) {
        state = next
        for c in continuations.values {
            c.yield(next)
        }
    }

    private func unregister(id: UUID) {
        continuations.removeValue(forKey: id)
    }
}
