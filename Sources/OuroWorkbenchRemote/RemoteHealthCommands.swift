import Foundation
import OuroWorkbenchCore

func remoteRunDoctor(_ context: RemoteHelperContext) throws {
    let checks = remoteCollectHealth(context)
    let secrets = remoteSecretValues(context.environment)
    let report = RemoteDoctor.report(checks: checks, now: Date(), staleAfter: 120, redacting: secrets)
    if context.invocation.hasFlag("json") {
        var data = try report.jsonData()
        data.append(0x0a)
        FileHandle.standardOutput.write(data)
    } else {
        for check in report.checks {
            print("\(check.state.rawValue)\t\(check.name)\t\(check.detail)")
        }
    }
}

func remoteRunObserve(_ context: RemoteHelperContext) throws {
    let observerRoot = URL(fileURLWithPath: try context.path("observer-root", environment: "OURO_OBSERVER_ROOT"), isDirectory: true)
    let now = Date()
    let output = try RemoteObserver(rootURL: observerRoot).record(
        checks: remoteCollectHealth(context, observedAt: now),
        observedAt: now,
        redacting: remoteSecretValues(context.environment)
    )
    try remoteWriteJSON(["observation": output.path])
}

private func remoteCollectHealth(_ context: RemoteHelperContext, observedAt: Date = Date()) -> [RemoteHealthCheck] {
    var checks: [RemoteHealthCheck] = []
    let configPath: String
    let registry: RemoteProfileRegistry
    do {
        configPath = try context.path("config", environment: "OURO_REMOTE_CONFIG")
        registry = try remoteLoadRegistry(configPath: configPath)
        checks.append(RemoteHealthCheck(name: "profile-registry", source: configPath, observedAt: observedAt, state: .healthy, detail: "\(registry.profiles.count) isolated profiles validated"))
    } catch {
        checks.append(RemoteHealthCheck(name: "profile-registry", source: "profile config", observedAt: observedAt, state: .corrupt, detail: remoteSafeHealthDetail(error)))
        return checks
    }

    let runner = RemoteSystemRunner(timeout: 10, maximumOutputBytes: 65_536)
    for profile in registry.profiles {
        var environment = remoteDiagnosticEnvironment(context.environment)
        environment["GH_CONFIG_DIR"] = profile.ghConfigDir
        do {
            let result = try runner.run(RemoteProcessRequest(
                executable: profile.ghExecutable,
                arguments: ["api", "/user", "--jq", ".login"],
                environment: environment,
                workingDirectory: profile.deskRoot
            ))
            let login = String(decoding: result.stdout, as: UTF8.self).trimmingCharacters(in: .whitespacesAndNewlines)
            let matches = result.exitCode == 0 && login == profile.githubLogin
            checks.append(RemoteHealthCheck(
                name: "github-account-\(profile.id)",
                source: profile.ghConfigDir,
                observedAt: observedAt,
                state: matches ? .healthy : (result.exitCode == 0 ? .accountMismatch : .unavailable),
                detail: matches ? "authenticated as \(profile.githubLogin)" : "isolated GitHub identity is unavailable or mismatched"
            ))
        } catch {
            checks.append(RemoteHealthCheck(name: "github-account-\(profile.id)", source: profile.ghConfigDir, observedAt: observedAt, state: .unavailable, detail: "GitHub identity probe failed"))
        }
    }

    if let rootPath = try? context.path("root", environment: "OURO_HERDR_ROOT") {
        let rootURL = URL(fileURLWithPath: rootPath, isDirectory: true)
        let activeURL = rootURL.appendingPathComponent("active-runtime.json")
        if !FileManager.default.fileExists(atPath: activeURL.path) {
            checks.append(RemoteHealthCheck(name: "herdr-active-generation", source: activeURL.path, observedAt: observedAt, state: .unknown, detail: "no active managed generation is published"))
        } else {
            do {
                let runtime = try JSONDecoder().decode(RemoteActiveRuntime.self, from: RemotePrivateFile.read(path: activeURL.path, maximumBytes: RemoteGuardian.maximumControlFileBytes))
                guard runtime.schemaVersion == 1, runtime.generation == runtime.sessionName else { throw RemoteControlError.guardian("active runtime identity is invalid") }
                let herdrPaths = Set(registry.profiles.map(\.herdrExecutable))
                guard herdrPaths.count == 1, let herdr = herdrPaths.first else { throw RemoteControlError.guardian("profile Herdr executables disagree") }
                let ledgerPath = try context.path("ledger", environment: "OURO_LEDGER_ROOT")
                let ledger = try RemoteResumeLedgerFactory.make(
                    ledgerRootURL: URL(fileURLWithPath: ledgerPath, isDirectory: true),
                    herdrRootURL: rootURL,
                    registry: registry,
                    inheritedEnvironment: context.environment
                )
                let adapter = RemoteHerdrAdapter(
                    rootURL: rootURL,
                    registry: registry,
                    ledger: ledger,
                    sessionMapURL: URL(fileURLWithPath: (try? context.path("session-map", environment: "OURO_SESSION_MAP")) ?? rootURL.appendingPathComponent("session-map.json").path),
                    herdrExecutable: herdr,
                    configPath: configPath,
                    helperPath: context.helperPath,
                    shimDirectory: context.environment["OURO_SHIM_DIRECTORY"] ?? URL(fileURLWithPath: context.helperPath).deletingLastPathComponent().path,
                    zdotdir: context.environment["OURO_ZDOTDIR"] ?? (context.environment["HOME"] ?? "/tmp"),
                    inheritedEnvironment: context.environment
                )
                switch try adapter.probe(sessionName: runtime.sessionName) {
                case let .running(inventory):
                    let exact = try adapter.activeRuntimeIsExact(runtime, inventory: inventory)
                    checks.append(RemoteHealthCheck(
                        name: "herdr-active-generation",
                        source: runtime.socketPath,
                        observedAt: observedAt,
                        state: exact ? .healthy : .degraded,
                        detail: exact ? "generation \(runtime.generation) has \(inventory.panes.count) exact managed panes" : "published generation inventory or worker identity is not exact"
                    ))
                case .absent:
                    checks.append(RemoteHealthCheck(name: "herdr-active-generation", source: runtime.socketPath, observedAt: observedAt, state: .unavailable, detail: "published generation is absent"))
                case let .degraded(detail):
                    checks.append(RemoteHealthCheck(name: "herdr-active-generation", source: runtime.socketPath, observedAt: observedAt, state: .degraded, detail: detail))
                }
            } catch {
                checks.append(RemoteHealthCheck(name: "herdr-active-generation", source: activeURL.path, observedAt: observedAt, state: .corrupt, detail: remoteSafeHealthDetail(error)))
            }
        }
    }

    if let ledgerPath = try? context.path("ledger", environment: "OURO_LEDGER_ROOT") {
        do {
            let ledger = try RemoteResumeLedgerFactory.make(
                ledgerRootURL: URL(fileURLWithPath: ledgerPath, isDirectory: true),
                herdrRootURL: RemoteHerdrRootLocator.locate(environment: context.environment),
                registry: registry,
                inheritedEnvironment: context.environment
            )
            let inspection = try ledger.inspectHealth()
            let state: RemoteHealthState
            let detail: String
            if !inspection.reconcileRequiredAttemptIDs.isEmpty {
                state = .blocked
                detail = "\(inspection.reconcileRequiredAttemptIDs.count) dead or absent attempt(s) require explicit reconciliation"
            } else if !inspection.unknownAttemptIDs.isEmpty {
                state = .unknown
                detail = "liveness is unavailable for \(inspection.unknownAttemptIDs.count) supervised attempt(s)"
            } else if !inspection.ownedAttemptIDs.isEmpty {
                state = .healthy
                detail = "\(inspection.ownedAttemptIDs.count) exact live supervised child(ren) remain owned"
            } else {
                state = .healthy
                detail = "no outstanding resume attempt"
            }
            checks.append(RemoteHealthCheck(name: "resume-ledger", source: ledgerPath, observedAt: observedAt, state: state, detail: detail))
        } catch {
            checks.append(RemoteHealthCheck(name: "resume-ledger", source: ledgerPath, observedAt: observedAt, state: .corrupt, detail: remoteSafeHealthDetail(error)))
        }
    }

    if let relayState = context.invocation.options["relay-state"] ?? context.environment["OURO_RELAY_STATE"] {
        checks.append(remoteRelayHealth(path: relayState, observedAt: observedAt))
    }
    return checks
}

private func remoteRelayHealth(path: String, observedAt: Date) -> RemoteHealthCheck {
    do {
        let object = try JSONSerialization.jsonObject(with: RemotePrivateFile.read(path: path, maximumBytes: 65_536)) as? [String: Any]
        let state = object?["status"] as? String
        let mapped: RemoteHealthState
        switch state {
        case "healthy", "running": mapped = .healthy
        case "tripped": mapped = .tripped
        case "blocked": mapped = .blocked
        case "degraded": mapped = .degraded
        default: mapped = .unknown
        }
        return RemoteHealthCheck(name: "mobile-relay", source: path, observedAt: observedAt, state: mapped, detail: "relay supervisor state is \(state ?? "unknown")")
    } catch {
        return RemoteHealthCheck(name: "mobile-relay", source: path, observedAt: observedAt, state: .unavailable, detail: "relay supervisor state is unavailable")
    }
}

private func remoteDiagnosticEnvironment(_ environment: [String: String]) -> [String: String] {
    let allowed = Set(["HOME", "USER", "LOGNAME", "SHELL", "PATH", "TMPDIR", "TERM", "LANG"])
    return environment.filter { allowed.contains($0.key) || $0.key.hasPrefix("LC_") }
}

private func remoteSecretValues(_ environment: [String: String]) -> [String] {
    ["COPILOT_GITHUB_TOKEN", "GH_TOKEN", "GITHUB_TOKEN", "HERDR_RELAY_TOKEN"].compactMap { environment[$0] }.filter { !$0.isEmpty }
}

private func remoteSafeHealthDetail(_ error: Error) -> String {
    switch error {
    case let control as RemoteControlError: control.localizedDescription
    default: "dependency error"
    }
}
