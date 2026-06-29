#!/usr/bin/env bash
#
# Shared release policy for Workbench CI, local preflight, shell-refresh PRs,
# and the merge-time auto-release decision.
set -euo pipefail

ROOT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd)"
cd "$ROOT_DIR"
eval "$("$ROOT_DIR/scripts/read-workbench-release.sh")"

repo_default="$WORKBENCH_REPOSITORY"

fail() {
  printf 'Release policy failed: %s\n' "$*" >&2
  exit 1
}

usage() {
  cat >&2 <<'USAGE'
Usage:
  scripts/release-policy.sh freshness [--mode auto|pr|main] [--base-ref REF] [--repo OWNER/REPO]
  scripts/release-policy.sh release-exists --version X.Y.Z [--repo OWNER/REPO]
  scripts/release-policy.sh selftest-pr-base
  scripts/release-policy.sh selftest-package-guards
  scripts/release-policy.sh selftest-shell-dependency-watch
  scripts/release-policy.sh selftest-paths
USAGE
  exit 64
}

current_version() {
  tr -d '[:space:]' < VERSION
}

json_get() {
  local field="$1"
  python3 -c '
import json
import sys

field = sys.argv[1]
try:
    value = json.load(sys.stdin)
except json.JSONDecodeError:
    sys.exit(1)

for part in field.split("."):
    if isinstance(value, dict):
        value = value.get(part)
    else:
        value = None
    if value is None:
        break

if isinstance(value, bool):
    print("true" if value else "false")
elif value is not None:
    print(value)
' "$field"
}

strip_v() {
  printf '%s' "${1#v}"
}

semver_compare() {
  python3 - "$1" "$2" <<'PY'
import re
import sys

def parse(raw):
    raw = raw.removeprefix("v")
    raw = raw.split("+", 1)[0]
    core, sep, prerelease = raw.partition("-")
    if not re.fullmatch(r"\d+\.\d+\.\d+", core):
        raise SystemExit(2)
    parsed = tuple(int(part) for part in core.split("."))
    identifiers = []
    if sep:
        if not prerelease:
            raise SystemExit(2)
        for item in prerelease.split("."):
            if not item or not re.fullmatch(r"[0-9A-Za-z-]+", item):
                raise SystemExit(2)
            if item.isdigit():
                if len(item) > 1 and item.startswith("0"):
                    raise SystemExit(2)
                identifiers.append((0, int(item)))
            else:
                identifiers.append((1, item))
    return parsed, identifiers

left = parse(sys.argv[1])
right = parse(sys.argv[2])
if left[0] != right[0]:
    print((left[0] > right[0]) - (left[0] < right[0]))
    raise SystemExit(0)
left_ids = left[1]
right_ids = right[1]
if not left_ids and right_ids:
    print(1)
    raise SystemExit(0)
if left_ids and not right_ids:
    print(-1)
    raise SystemExit(0)
for left_item, right_item in zip(left_ids, right_ids):
    if left_item == right_item:
        continue
    if left_item[0] != right_item[0]:
        print(-1 if left_item[0] < right_item[0] else 1)
    else:
        print((left_item[1] > right_item[1]) - (left_item[1] < right_item[1]))
    raise SystemExit(0)
print((len(left_ids) > len(right_ids)) - (len(left_ids) < len(right_ids)))
PY
}

semver_gt() {
  [[ "$(semver_compare "$1" "$2")" == "1" ]]
}

semver_lt() {
  [[ "$(semver_compare "$1" "$2")" == "-1" ]]
}

release_list_json() {
  local repo="$1"
  gh release list --repo "$repo" --exclude-drafts --limit 100 --json tagName,isPrerelease,isLatest
}

latest_release_tag() {
  python3 -c '
import json
import sys

for release in json.load(sys.stdin):
    tag = release.get("tagName", "")
    if tag:
        print(tag)
        sys.exit(0)
sys.exit(3)
'
}

release_list_has_tag() {
  local tag="$1"
  python3 -c '
import json
import sys

tag = sys.argv[1]
for release in json.load(sys.stdin):
    if release.get("tagName") == tag:
        sys.exit(0)
sys.exit(1)
' "$tag"
}

release_view_json() {
  local repo="$1"
  local tag="$2"
  gh release view "$tag" --repo "$repo" --json tagName,targetCommitish,url,isPrerelease
}

latest_release_json() {
  local repo="$1"
  local list_json tag
  list_json="$(release_list_json "$repo")" || return $?
  tag="$(printf '%s' "$list_json" | latest_release_tag)" || return $?
  release_view_json "$repo" "$tag"
}

release_json_for_version() {
  local repo="$1"
  local version="$2"
  release_view_json "$repo" "v${version}"
}

resolve_commit() {
  git rev-parse --verify --quiet "$1" 2>/dev/null \
    || git rev-parse --verify --quiet "$1^{commit}" 2>/dev/null \
    || printf '%s\n' "$1"
}

release_relevant_path() {
  case "$1" in
    # Scenario-verifier and test fixtures are CI proof surfaces, not app inputs.
    Sources/OuroWorkbenchScenarioVerifier/*) return 1 ;;
    Tests/*|docs/*|worker/*|README.md) return 1 ;;

    # Shipped app, package resolution, public installer, and release scripts.
    Package.swift|Package.resolved|VERSION) return 0 ;;
    Sources/OuroWorkbenchApp/*|Sources/OuroWorkbenchAppViews/*) return 0 ;;
    Sources/OuroWorkbenchCore/*|Sources/OuroWorkbenchMCP/*|Sources/OuroWorkbenchShellAdapter/*) return 0 ;;
    web/*) return 0 ;;
    scripts/*) return 0 ;;
    .github/workflows/release.yml|.github/workflows/auto-release.yml|.github/workflows/shell-dependency-watch.yml) return 0 ;;
    *) return 1 ;;
  esac
}

filter_release_relevant() {
  local path
  while IFS= read -r path; do
    [[ -n "$path" ]] || continue
    if release_relevant_path "$path"; then
      printf '%s\n' "$path"
    fi
  done
}

resolve_pr_base_ref() {
  local base_ref="$1"
  local candidate="$base_ref"
  local fetch_branch=""

  case "$base_ref" in
    origin/*)
      candidate="$base_ref"
      fetch_branch="${base_ref#origin/}"
      ;;
    refs/remotes/origin/*)
      candidate="$base_ref"
      fetch_branch="${base_ref#refs/remotes/origin/}"
      ;;
    refs/heads/*)
      fetch_branch="${base_ref#refs/heads/}"
      candidate="origin/$fetch_branch"
      ;;
    refs/*)
      candidate="$base_ref"
      ;;
    *)
      if [[ "$base_ref" =~ ^[0-9a-fA-F]{7,40}$ ]]; then
        candidate="$base_ref"
      else
        fetch_branch="$base_ref"
        candidate="origin/$fetch_branch"
      fi
      ;;
  esac

  if [[ -n "$fetch_branch" ]]; then
    git fetch --no-tags origin "$fetch_branch" >/dev/null 2>&1 || true
  fi

  if git rev-parse --verify --quiet "$candidate^{commit}" >/dev/null; then
    printf '%s\n' "$candidate"
    return 0
  fi
  if [[ "$candidate" != "$base_ref" ]] && git rev-parse --verify --quiet "$base_ref^{commit}" >/dev/null; then
    printf '%s\n' "$base_ref"
    return 0
  fi

  echo "error: could not resolve PR base ref '$base_ref' (tried '$candidate')" >&2
  return 1
}

changed_files_for_pr() {
  local base_ref="$1"
  local resolved_base committed
  if ! resolved_base="$(resolve_pr_base_ref "$base_ref")"; then
    return 1
  fi
  if ! git merge-base "$resolved_base" HEAD >/dev/null 2>&1; then
    echo "error: could not compute merge base between '$resolved_base' and HEAD" >&2
    return 1
  fi
  if ! committed="$(git diff --name-only "$resolved_base"...HEAD)"; then
    echo "error: could not diff PR base '$resolved_base' against HEAD" >&2
    return 1
  fi
  {
    printf '%s\n' "$committed"
    git diff --name-only
    git diff --cached --name-only
  } | sort -u
}

changed_files_since() {
  local base="$1"
  {
    git diff --name-only "$base"...HEAD 2>/dev/null || git diff --name-only "$base" HEAD
    git diff --name-only
    git diff --cached --name-only
  } | sort -u
}

freshness_mode() {
  local mode="auto"
  local base_ref="${GITHUB_BASE_REF:-main}"
  local repo="${GITHUB_REPOSITORY:-$repo_default}"

  while [[ $# -gt 0 ]]; do
    case "$1" in
      --mode) mode="${2:-}"; shift 2 ;;
      --base-ref) base_ref="${2:-}"; shift 2 ;;
      --repo) repo="${2:-}"; shift 2 ;;
      *) usage ;;
    esac
  done

  [[ "$mode" =~ ^(auto|pr|main)$ ]] || usage
  [[ -n "$base_ref" ]] || fail "--base-ref must not be empty"

  if [[ "$mode" == "auto" ]]; then
    case "${GITHUB_EVENT_NAME:-}" in
      pull_request|pull_request_target) mode="pr" ;;
      push) mode="main" ;;
      *) mode="pr" ;;
    esac
  fi

  local version
  version="$(current_version)"

  local latest_json latest_status latest_tag latest_version
  set +e
  latest_json="$(latest_release_json "$repo")"
  latest_status=$?
  set -e
  if [[ "$latest_status" != "0" ]]; then
    if [[ "$latest_status" != "3" ]]; then
      fail "could not read latest release for $repo"
    fi
    printf 'release freshness: no published releases found for %s; allowing %s\n' "$repo" "$version"
    return 0
  fi
  latest_tag="$(printf '%s' "$latest_json" | json_get tagName)"
  latest_version="$(strip_v "$latest_tag")"

  if semver_lt "$version" "$latest_version"; then
    fail "source version $version is older than latest published release $latest_tag"
  fi

  if [[ "$mode" == "pr" ]]; then
    local changed relevant
    if ! changed="$(changed_files_for_pr "$base_ref")"; then
      exit 1
    fi
    relevant="$(printf '%s\n' "$changed" | filter_release_relevant || true)"
    if [[ -z "$relevant" ]]; then
      printf 'release freshness: no app/release-affecting paths changed\n'
      return 0
    fi
    if semver_gt "$version" "$latest_version"; then
      printf 'release freshness: %s is newer than latest release %s\n' "$version" "$latest_tag"
      return 0
    fi
    printf '%s\n' "$relevant" >&2
    fail "app/release-affecting changes require a version greater than latest published release $latest_tag"
  fi

  local release_list current_json
  release_list="$(release_list_json "$repo")" || fail "could not list releases for $repo"
  if ! printf '%s' "$release_list" | release_list_has_tag "v${version}"; then
    printf 'release freshness: v%s does not exist yet; release workflow may publish it\n' "$version"
    return 0
  fi
  current_json="$(release_json_for_version "$repo" "$version")" || fail "could not read release v$version for $repo"

  local target target_sha head_sha changed relevant
  target="$(printf '%s' "$current_json" | json_get targetCommitish)"
  target_sha="$(resolve_commit "$target")"
  head_sha="$(git rev-parse HEAD)"
  if [[ "$target_sha" == "$head_sha" ]]; then
    printf 'release freshness: v%s already points at this commit\n' "$version"
    return 0
  fi

  changed="$(changed_files_since "$target_sha")"
  relevant="$(printf '%s\n' "$changed" | filter_release_relevant || true)"
  if [[ -z "$relevant" ]]; then
    printf 'release freshness: v%s exists at %s, but no app/release-affecting paths changed\n' "$version" "$target_sha"
    return 0
  fi

  printf '%s\n' "$relevant" >&2
  fail "v$version already exists at $target_sha; app/release-affecting main changes need a new version"
}

release_exists_mode() {
  local repo="${GITHUB_REPOSITORY:-$repo_default}"
  local version=""

  while [[ $# -gt 0 ]]; do
    case "$1" in
      --repo) repo="${2:-}"; shift 2 ;;
      --version) version="${2:-}"; shift 2 ;;
      *) usage ;;
    esac
  done

  [[ -n "$version" ]] || fail "--version is required"

  local release_list
  release_list="$(release_list_json "$repo")" || fail "could not list releases for $repo"
  if printf '%s' "$release_list" | release_list_has_tag "v${version}"; then
    printf 'true\n'
  else
    printf 'false\n'
  fi
}

selftest_pr_base_mode() {
  mkdir -p .build

  local ref
  for ref in main origin/main refs/heads/main refs/remotes/origin/main; do
    changed_files_for_pr "$ref" >/dev/null \
      || fail "PR base selftest failed to resolve '$ref'"
  done

  local missing="origin/__ouro-workbench-missing-pr-base"
  if changed_files_for_pr "$missing" >/dev/null 2>.build/workbench-release-policy-selftest.err; then
    fail "PR base selftest unexpectedly resolved missing ref '$missing'"
  fi

  printf 'release policy PR base selftest ok\n'
}

selftest_paths_mode() {
  local must_gate=(
    Sources/OuroWorkbenchApp/main.swift
    Sources/OuroWorkbenchAppViews/WorkbenchViews.swift
    Sources/OuroWorkbenchCore/WorkbenchRelease.swift
    Sources/OuroWorkbenchMCP/OuroWorkbenchMCPMain.swift
    Sources/OuroWorkbenchShellAdapter/WorkbenchShellPresentation.swift
    web/workbench-install.sh
    Package.swift
    Package.resolved
    VERSION
    scripts/package-app.sh
    scripts/preflight.sh
    scripts/check-shell-boundary.sh
    scripts/shell-boundary-allowlist.txt
    scripts/verify-published-release.sh
    scripts/release-policy.sh
    .github/workflows/release.yml
    .github/workflows/auto-release.yml
  )
  local must_skip=(
    Sources/OuroWorkbenchScenarioVerifier/main.swift
    Tests/OuroWorkbenchCoreTests/ReleaseUpdateTests.swift
    docs/workbench-5000-scenario-matrix.md
    worker/tasks/2026-06-26-u5-honest-coverage-gate/b8-records.md
    README.md
  )
  local path
  for path in "${must_gate[@]}"; do
    release_relevant_path "$path" || fail "paths selftest: '$path' should gate a release but doesn't"
  done
  for path in "${must_skip[@]}"; do
    ! release_relevant_path "$path" || fail "paths selftest: '$path' should NOT gate a release but does"
  done
  printf 'release policy paths selftest ok\n'
}

selftest_package_guards_mode() {
  python3 <<'PY'
from pathlib import Path

ci = Path(".github/workflows/ci.yml").read_text(encoding="utf-8")
preflight = Path("scripts/preflight.sh").read_text(encoding="utf-8")
auto_release = Path(".github/workflows/auto-release.yml").read_text(encoding="utf-8")
release = Path(".github/workflows/release.yml").read_text(encoding="utf-8")

required_ci = [
    "fetch-depth: 0",
    "scripts/release-policy.sh freshness",
    "scripts/release-policy.sh selftest-pr-base",
    "scripts/release-policy.sh selftest-package-guards",
    "scripts/release-policy.sh selftest-shell-dependency-watch",
    "scripts/release-policy.sh selftest-paths",
    "scripts/check-swift-tests.sh",
]
for needle in required_ci:
    if needle not in ci:
        raise SystemExit(f"ci.yml must contain {needle!r}")
ci_lines = {line.strip() for line in ci.splitlines()}
for line in ("run: scripts/check-shell-boundary.sh --selftest", "run: scripts/check-shell-boundary.sh"):
    if line not in ci_lines:
        raise SystemExit(f"ci.yml must contain an exact {line!r} step")

required_preflight = [
    "scripts/preflight.sh --selftest",
    "scripts/release-policy.sh freshness --mode pr",
    "scripts/release-policy.sh selftest-pr-base",
    "scripts/release-policy.sh selftest-package-guards",
    "scripts/release-policy.sh selftest-shell-dependency-watch",
    "scripts/release-policy.sh selftest-paths",
    "scripts/check-shell-dependency.sh",
    "scripts/check-swift-tests.sh",
]
for needle in required_preflight:
    if needle not in preflight:
        raise SystemExit(f"preflight.sh must contain {needle!r}")
coverage = Path("scripts/check-coverage.sh").read_text(encoding="utf-8")
swift_tests = Path("scripts/check-swift-tests.sh").read_text(encoding="utf-8")
for script_name, script_body in {
    "scripts/check-coverage.sh": coverage,
    "scripts/check-swift-tests.sh": swift_tests,
}.items():
    if "scripts/check-test-log-noise.sh" not in script_body:
        raise SystemExit(f"{script_name} must call scripts/check-test-log-noise.sh")
preflight_lines = {line.strip() for line in preflight.splitlines()}
for line in ("scripts/check-shell-boundary.sh --selftest", "scripts/check-shell-boundary.sh"):
    if line not in preflight_lines:
        raise SystemExit(f"preflight.sh must contain an exact {line!r} call")

required_auto = [
    "scripts/release-policy.sh release-exists",
    "scripts/release-policy.sh freshness --mode main",
]
for needle in required_auto:
    if needle not in auto_release:
        raise SystemExit(f"auto-release.yml must contain {needle!r}")
if "grep -E '^(Sources/" in auto_release:
    raise SystemExit("auto-release.yml must not keep a separate inline release-affecting path grep")

if "scripts/release-policy.sh freshness --mode main" not in release:
    raise SystemExit("release.yml must verify release freshness in main mode")
release_lines = [line.strip() for line in release.splitlines()]
required_release_preflight = [
    ("- name: Run release preflight - policy and tooling", "run: scripts/preflight.sh --only release-policy"),
    ("- name: Run release preflight - generated scenario matrix", "run: scripts/preflight.sh --only generated-scenario-matrix"),
    ("- name: Run release preflight - Swift tests", "run: scripts/preflight.sh --only swift-tests"),
    ("- name: Run release preflight - UI probes", "run: scripts/preflight.sh --only ui-probes"),
    ("- name: Run release preflight - native scenario verifier", "run: scripts/preflight.sh --only required-scenario-verifier"),
    ("- name: Run release preflight - app bundle", "run: scripts/preflight.sh --only app-bundle"),
    ("- name: Run release preflight - app artifact", "run: scripts/preflight.sh --only app-artifact"),
    ("- name: Run release preflight - install rollback", "run: scripts/preflight.sh --only install-rollback"),
]
cursor = 0
for step_name, run_line in required_release_preflight:
    try:
        step_index = release_lines.index(step_name, cursor)
    except ValueError:
        raise SystemExit(f"release.yml must contain ordered step {step_name!r}")
    try:
        run_index = release_lines.index(run_line, step_index + 1)
    except ValueError:
        raise SystemExit(f"release.yml must run {run_line!r} inside {step_name!r}")
    next_step_index = next(
        (index for index in range(step_index + 1, len(release_lines)) if release_lines[index].startswith("- name: ")),
        len(release_lines),
    )
    if run_index >= next_step_index:
        raise SystemExit(f"release.yml must run {run_line!r} before the next workflow step")
    cursor = run_index + 1
try:
    generate_notes_index = release_lines.index("- name: Generate release notes", cursor)
    publish_index = release_lines.index("- name: Publish GitHub Release", generate_notes_index + 1)
except ValueError:
    raise SystemExit("release.yml must generate release notes and publish only after every release preflight gate")
if publish_index <= cursor:
    raise SystemExit("release.yml must finish every release preflight gate before publishing")
PY
  printf 'release package guard selftest ok\n'
}

selftest_shell_dependency_watch_mode() {
  scripts/selftest-shell-dependency-watch.sh
  python3 <<'PY'
from pathlib import Path

workflow = Path(".github/workflows/shell-dependency-watch.yml").read_text(encoding="utf-8")
needles = [
    "./scripts/release-policy.sh freshness --mode pr --base-ref origin/main",
    "./scripts/release-policy.sh selftest-package-guards",
    "./scripts/release-policy.sh selftest-paths",
    "./scripts/release-policy.sh selftest-shell-dependency-watch",
]
for needle in needles:
    if needle not in workflow:
        raise SystemExit(f"shell-dependency-watch.yml must contain {needle!r}")
PY
  printf 'release shell dependency watch selftest ok\n'
}

cmd="${1:-}"
[[ -n "$cmd" ]] || usage
shift

case "$cmd" in
  freshness) freshness_mode "$@" ;;
  release-exists) release_exists_mode "$@" ;;
  selftest-pr-base) selftest_pr_base_mode "$@" ;;
  selftest-package-guards) selftest_package_guards_mode "$@" ;;
  selftest-shell-dependency-watch) selftest_shell_dependency_watch_mode "$@" ;;
  selftest-paths) selftest_paths_mode "$@" ;;
  *) usage ;;
esac
