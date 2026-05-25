#!/usr/bin/env ruby
# frozen_string_literal: true

require "fileutils"

ROOT = File.expand_path("..", __dir__)
OUT = File.join(ROOT, "docs", "workbench-5000-scenario-matrix.tsv")
SUMMARY = File.join(ROOT, "docs", "workbench-5000-scenario-matrix.md")

TERMINALS = {
  "claude" => "Claude Code terminal",
  "codex" => "OpenAI Codex terminal",
  "copilot" => "GitHub Copilot CLI terminal",
  "generic_tui" => "generic terminal/TUI agent",
  "local_shell" => "local shell"
}.freeze

LIFECYCLES = {
  "configured" => "configured with no prior run",
  "running" => "currently running",
  "waiting_for_input" => "waiting for human input",
  "needs_recovery" => "marked as needing restart recovery",
  "manual_action_needed" => "already marked as needing manual recovery"
}.freeze

TRUST_RESUME = {
  "trusted_auto_session" => { trust: "trusted", auto: true, session: true, label: "trusted, auto-resume enabled, native session metadata present" },
  "trusted_auto_no_session" => { trust: "trusted", auto: true, session: false, label: "trusted, auto-resume enabled, no native session metadata" },
  "trusted_no_auto" => { trust: "trusted", auto: false, session: true, label: "trusted, auto-resume disabled" },
  "untrusted_auto" => { trust: "untrusted", auto: true, session: true, label: "untrusted, auto-resume requested" },
  "untrusted_no_auto" => { trust: "untrusted", auto: false, session: false, label: "untrusted, auto-resume disabled" }
}.freeze

SURFACES = {
  "sidebar_dashboard" => { label: "sidebar visible with dashboard expanded", boss_watch: true, archived: false },
  "sidebar_hidden_dashboard" => { label: "sidebar hidden with dashboard expanded", boss_watch: true, archived: false },
  "boss_pane_collapsed" => { label: "boss pane collapsed so terminal gets more space", boss_watch: false, archived: false },
  "terminal_focus" => { label: "terminal focus mode", boss_watch: true, archived: false },
  "archived_session" => { label: "archived session visible only as archive/history", boss_watch: true, archived: true }
}.freeze

BOSS_BRIDGES = {
  "registered" => "boss Workbench MCP registered",
  "not_registered" => "boss Workbench MCP missing",
  "needs_update" => "boss Workbench MCP points at stale command",
  "agent_missing" => "selected boss agent bundle missing"
}.freeze

EXECUTABLE_HEALTH = {
  "available" => "command executable available",
  "missing" => "command executable missing"
}.freeze

NATIVE_RESUME_TERMINALS = %w[claude codex].freeze
CHECKPOINT_TERMINALS = %w[copilot generic_tui local_shell].freeze

def terminal_agent?(terminal)
  terminal != "local_shell"
end

def recovery_for(terminal:, lifecycle:, trust_resume:, surface:)
  posture = TRUST_RESUME.fetch(trust_resume)
  return ["noAction", "Archived sessions stay preserved and are never restarted automatically."] if SURFACES.fetch(surface).fetch(:archived)
  return ["noAction", "There is no prior run to recover."] if lifecycle == "configured"
  return ["manualActionNeeded", "The latest run already requires manual recovery."] if lifecycle == "manual_action_needed"
  return ["noAction", "The latest run is #{LIFECYCLES.fetch(lifecycle)}, so restart recovery is not queued."] unless lifecycle == "needs_recovery"
  return ["manualActionNeeded", "Untrusted sessions must not be resumed or respawned automatically."] if posture.fetch(:trust) == "untrusted"
  return ["noAction", "Auto-resume is disabled, so the session remains waiting for explicit operator action."] unless posture.fetch(:auto)

  if NATIVE_RESUME_TERMINALS.include?(terminal)
    if posture.fetch(:session)
      ["autoResume", "#{TERMINALS.fetch(terminal)} should use native resume metadata."]
    else
      ["autoResume", "#{TERMINALS.fetch(terminal)} should use the latest-session native fallback."]
    end
  elsif CHECKPOINT_TERMINALS.include?(terminal)
    ["respawn", "#{TERMINALS.fetch(terminal)} should reopen inside the persistent terminal backend with checkpoint context."]
  else
    raise "unhandled terminal #{terminal}"
  end
end

def readiness_for(terminal:, lifecycle:, trust_resume:, surface:, boss_bridge:, executable_health:, recovery:)
  posture = TRUST_RESUME.fetch(trust_resume)
  archived = SURFACES.fetch(surface).fetch(:archived)
  blockers = []
  warnings = []

  blockers << "boss bridge is #{boss_bridge}" unless boss_bridge == "registered"
  blockers << "executable is missing" if executable_health == "missing" && !archived

  if terminal_agent? terminal
    if archived
      warnings << "no active terminal agents remain after archive filtering"
    else
      blockers << "terminal agent is untrusted" if posture.fetch(:trust) == "untrusted"
      blockers << "terminal agent auto-resume is disabled" unless posture.fetch(:auto)
    end
  else
    warnings << "only a local shell is active, so no boss-managed agent terminal exists" unless archived
    warnings << "no active terminal agents remain after archive filtering" if archived
  end

  blockers << "manual recovery is present" if recovery == "manualActionNeeded" && !archived
  warnings << "restart recovery action is queued" if %w[autoResume respawn].include?(recovery)
  warnings << "boss watch is paused" unless SURFACES.fetch(surface).fetch(:boss_watch)

  return ["blocked", "Block human-free operation: #{blockers.uniq.join('; ')}."] unless blockers.empty?
  return ["attention", "Usable with watch points: #{warnings.uniq.join('; ')}."] unless warnings.empty?

  ["ready", "Boss, terminal, executable, watch, and recovery posture are all clear."]
end

def operator_outcome(terminal:, lifecycle:, trust_resume:, surface:, recovery:, readiness:, readiness_detail:)
  terminal_label = TERMINALS.fetch(terminal)
  lifecycle_label = LIFECYCLES.fetch(lifecycle)
  surface_label = SURFACES.fetch(surface).fetch(:label)
  posture_label = TRUST_RESUME.fetch(trust_resume).fetch(:label)

  case readiness
  when "blocked"
    "Operator sees #{terminal_label} as #{lifecycle_label} on #{surface_label}; posture is #{posture_label}. Workbench blocks hands-off autonomy and surfaces: #{readiness_detail}"
  when "attention"
    "Operator can keep working with #{terminal_label} as #{lifecycle_label} on #{surface_label}; posture is #{posture_label}. Workbench surfaces: #{readiness_detail}"
  else
    "Operator sees #{terminal_label} as #{lifecycle_label} on #{surface_label}; posture is #{posture_label}. Controls stay available and no human gate is invented."
  end
end

def boss_outcome(terminal:, recovery:, readiness:)
  case readiness
  when "blocked"
    "Selected Ouro boss reports the blocker, avoids unsafe terminal control, and asks only for the missing prerequisite."
  when "attention"
    if %w[autoResume respawn].include?(recovery)
      "Selected Ouro boss can explain the queued #{recovery} recovery path and keep observing until it settles."
    else
      "Selected Ouro boss can answer status questions and keep moving only where the next action is clear."
    end
  else
    "Selected Ouro boss can inspect, summarize, and control the #{TERMINALS.fetch(terminal)} session through Workbench MCP."
  end
end

def expected_recovery_prompt?(terminal:, recovery:)
  recovery == "respawn" && %w[copilot generic_tui].include?(terminal)
end

FileUtils.mkdir_p(File.dirname(OUT))

headers = %w[
  case_id
  terminal
  lifecycle
  trust_resume_metadata
  surface
  boss_bridge
  executable_health
  expected_recovery
  expected_recovery_prompt
  expected_readiness
  optimal_operator_outcome
  optimal_boss_outcome
]

rows = []
case_number = 0
TERMINALS.each_key do |terminal|
  LIFECYCLES.each_key do |lifecycle|
    TRUST_RESUME.each_key do |trust_resume|
      SURFACES.each_key do |surface|
        BOSS_BRIDGES.each_key do |boss_bridge|
          EXECUTABLE_HEALTH.each_key do |executable_health|
            case_number += 1
            recovery, = recovery_for(
              terminal: terminal,
              lifecycle: lifecycle,
              trust_resume: trust_resume,
              surface: surface
            )
            readiness, readiness_detail = readiness_for(
              terminal: terminal,
              lifecycle: lifecycle,
              trust_resume: trust_resume,
              surface: surface,
              boss_bridge: boss_bridge,
              executable_health: executable_health,
              recovery: recovery
            )
            rows << [
              format("WB-%04d", case_number),
              terminal,
              lifecycle,
              trust_resume,
              surface,
              boss_bridge,
              executable_health,
              recovery,
              expected_recovery_prompt?(terminal: terminal, recovery: recovery).to_s,
              readiness,
              operator_outcome(
                terminal: terminal,
                lifecycle: lifecycle,
                trust_resume: trust_resume,
                surface: surface,
                recovery: recovery,
                readiness: readiness,
                readiness_detail: readiness_detail
              ),
              boss_outcome(
                terminal: terminal,
                recovery: recovery,
                readiness: readiness
              )
            ]
          end
        end
      end
    end
  end
end

raise "expected 5000 rows, got #{rows.length}" unless rows.length == 5000

File.write(OUT, ([headers] + rows).map { |row| row.join("\t") }.join("\n") + "\n")

summary = <<~MARKDOWN
  # Workbench 5000 Scenario Matrix

  This is the durable 5000-case product matrix for Ouro Workbench. The canonical
  case list lives in `docs/workbench-5000-scenario-matrix.tsv` so the test suite
  can parse it without markdown-table ambiguity.

  Dimensions:

  - 5 terminal identities: Claude Code, OpenAI Codex, GitHub Copilot CLI, generic
    terminal/TUI agent, local shell.
  - 5 lifecycle states: configured, running, waiting for input, needs recovery,
    manual action needed.
  - 5 trust/resume/metadata postures.
  - 5 UI/organization surfaces.
  - 4 boss bridge states.
  - 2 executable-health states.

  Product invariant under test: every row has an optimal operator outcome, an
  optimal boss outcome, an expected recovery action, and an expected autonomy
  readiness state. `WorkbenchScenarioMatrixTests` parses all 5000 rows and runs
  them through the production recovery and readiness code.

  Generated by:

  ```sh
  scripts/generate-workbench-5000-matrix.rb
  ```
MARKDOWN

File.write(SUMMARY, summary)
puts "Wrote #{rows.length} scenarios to #{OUT}"
