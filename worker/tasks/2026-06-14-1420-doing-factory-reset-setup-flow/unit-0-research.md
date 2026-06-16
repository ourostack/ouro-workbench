# Unit 0 Research

Timestamp: 2026-06-14 15:15

Branch: `worker/factory-reset-setup-flow`

Git state before implementation:

```text
## worker/factory-reset-setup-flow
```

Last commit before implementation:

```text
e593d9d 2026-06-14 15:15 docs(doing): mark factory reset plan ready
```

Target source files checked:

- `Sources/OuroWorkbenchApp/OuroWorkbenchApp.swift`
- `Sources/OuroWorkbenchCore/WorkbenchFactoryReset.swift`
- `Sources/OuroWorkbenchCore/WorkbenchBootstrapper.swift`
- `Sources/OuroWorkbenchCore/Onboarding.swift`

Target test files checked:

- `Tests/OuroWorkbenchCoreTests/WorkbenchFactoryResetTests.swift`
- `Tests/OuroWorkbenchCoreTests/WorkbenchBootstrapperTests.swift`
- `Tests/OuroWorkbenchCoreTests/OnboardingTests.swift`

New files expected by the doing plan:

- `Sources/OuroWorkbenchCore/WorkbenchLaunchDiagnostics.swift`
- `Sources/OuroWorkbenchCore/WorkbenchSurfacePolicy.swift`
- `Sources/OuroWorkbenchCore/WorkbenchOnboardingNarrative.swift`
- `Tests/OuroWorkbenchCoreTests/WorkbenchLaunchDiagnosticsTests.swift`
- `Tests/OuroWorkbenchCoreTests/WorkbenchSurfacePolicyTests.swift`
- `Tests/OuroWorkbenchCoreTests/OnboardingNarrativeTests.swift`

Skill source check:

```text
diff -q ~/.agents/skills/work-planner/SKILL.md subagents/work-planner.md
=> subagents/work-planner.md missing; installed skill is active source.

diff -q ~/.agents/skills/work-doer/SKILL.md subagents/work-doer.md
=> subagents/work-doer.md missing; installed skill is active source.
```

Implementation decision:

No human-only blocker is present. The user explicitly delegated judgement for the duration of this work, the planning and doing reviewer gates converged, and the remaining choices are covered by the spec, audit backlog, and doing doc.
