# Ghostty Claude Workbench — Next Tasks

Last updated: 2026-07-21

## Session 2 update (2026-07-20)

Landed since the baseline below, all verified by `swiftc -typecheck` (whole module
except the one GhosttyKit file) + standalone runtime harnesses against real
`~/.claude` data. Full Xcode app build/test now passes after accepting Xcode license and installing the Metal Toolchain.

- **Metadata scrape live**: sidebar now shows real titles (custom-title/ai-title/
  last-prompt), cwd, message counts — not UUID prefixes.
- **Running-state overlay**: green dots from `~/.claude/sessions/*.json` + `kill(pid,0)`.
  Dedups a repeated sessionId by newest `startedAt` (stale crashed-PID file can't
  win over the live one).
- **Repo/worktree aggregation (P3 done)**: `WorkbenchGitService` + pure
  `WorkbenchWorktreeGrouping` → sidebar groups by repo → worktree → session, with
  subdir collapse, branch/dirty chips, linked-worktree nesting, two-clones-of-one-
  origin kept separate. Replaced the lossy `-`→`/` project-name formatter.
- **Lock hardening (M5)**: `WorkbenchSessionLock.isStale` + `reconcileLocks` self-heal
  a lock whose process is gone (45s boot grace) — a crash no longer locks a session
  forever, independent of the helper. **Locks are now per-session** (`snapshot.locks`
  map, migration-safe Codable) — resuming session B no longer clobbers A's lock.
- **Helper/lifecycle gated off**: `WorkbenchFeature.isLifecycleHelperEnabled` (default
  false). No idle UDS socket on launch; launches don't wrap the (unbundled) helper.
  Code preserved for when the helper is bundled + validated. See P1 below.
- **Bug fixed**: `WorkbenchGitService.run` sent git stderr to `/dev/null` (an unread
  Pipe would deadlock if git wrote >64KB to stderr).
- **Ghostty integration verified** against real source: `TerminalController.newTab(_:
  from:withBaseConfig:) -> TerminalController?`, `.window`, and `SurfaceConfiguration`
  (`workingDirectory`/`command`/`environmentVariables`/`waitAfterCommand`) all match.
- Tests: 29 in `WorkbenchTests.swift` (per-session locks, migration, dedup-newest,
  grouping, isStale boundary, originName edges, scrape, subagent filtering).

**Known limitations left (not bugs to fix blind):** PID-reuse could still show a
crashed session as running if its `sessions/*.json` lingers AND the PID is reused
(a real fix needs sysctl start-time verification — deferred, can't runtime-test here);
`messageCount` counts tool-result records but isn't displayed anywhere yet.

Still Xcode-gated (do after a green app build): inspector mount, New/Continue/
Worktree/Rename session-op buttons, favorite/needs-review filters, and P0/P4/P5 below.

## Current decision (2026-07-21)

Given the current implementation, P0 build/test hardening is complete. The next work should focus on dogfood validation of the current sidebar/session grouping before expanding feature surface further.

Execution order from here:

1. Dogfood current sidebar/session grouping against real Claude Code sessions.
2. Finish P2 locked-session UX and registry stale cleanup after dogfood.
3. Keep lifecycle helper gated off until bundled and end-to-end UDS events are validated.
4. Then do P4 streaming indexer and P5 UI actions.

## Current baseline

Implemented in this branch:

- Main Ghostty terminal window is wrapped with `WorkbenchTerminalRootView` at `macos/Sources/Features/Terminal/TerminalController.swift`.
- Workbench source lives under `macos/Sources/Workbench/`.
- Unit-test scaffolding lives under `macos/Tests/Workbench/WorkbenchTests.swift`.
- Current capabilities:
  - Feature flag + reactive sidebar visibility.
  - Sidebar session list grouped by repo/worktree using transient git metadata.
  - Filesystem Claude session indexer for `~/.claude/projects`.
  - Metadata scrape for limited JSONL fields: title, last prompt, cwd, message count.
  - Read-only running-state overlay from `~/.claude/sessions/*.json` with PID liveness checks.
  - JSON local store for Workbench-owned metadata.
  - Command builder for new/resume/fork/continue/worktree.
  - Per-session advisory store-backed locks with stale-lock reconciliation.

## Validation status

Lightweight validation passes on this machine:

```sh
swiftc -parse \
  macos/Sources/Workbench/App/WorkbenchFeature.swift \
  macos/Sources/Workbench/App/WorkbenchViewModel.swift \
  macos/Sources/Workbench/Model/WorkbenchModels.swift \
  macos/Sources/Workbench/Services/WorkbenchGitService.swift \
  macos/Sources/Workbench/Services/WorkbenchHelperResolver.swift \
  macos/Sources/Workbench/Services/WorkbenchLauncherService.swift \
  macos/Sources/Workbench/Services/WorkbenchLifecycleEventService.swift \
  macos/Sources/Workbench/Services/WorkbenchLockService.swift \
  macos/Sources/Workbench/Services/WorkbenchRunningStateService.swift \
  macos/Sources/Workbench/Services/WorkbenchSessionIndexService.swift \
  macos/Sources/Workbench/Services/WorkbenchSurfaceRegistry.swift \
  macos/Sources/Workbench/Store/WorkbenchStore.swift \
  macos/Sources/Workbench/UI/WorkbenchSidebarView.swift \
  macos/Sources/Workbench/UI/WorkbenchInspectorView.swift \
  macos/Sources/Workbench/UI/WorkbenchTerminalRootView.swift \
  macos/Tests/Workbench/WorkbenchTests.swift

swiftc -module-cache-path /tmp/ghostty-swift-module-cache-current -typecheck \
  macos/Sources/Workbench/App/WorkbenchFeature.swift \
  macos/Sources/Workbench/App/WorkbenchViewModel.swift \
  macos/Sources/Workbench/Model/WorkbenchModels.swift \
  macos/Sources/Workbench/Services/WorkbenchGitService.swift \
  macos/Sources/Workbench/Services/WorkbenchHelperResolver.swift \
  macos/Sources/Workbench/Services/WorkbenchLauncherService.swift \
  macos/Sources/Workbench/Services/WorkbenchLifecycleEventService.swift \
  macos/Sources/Workbench/Services/WorkbenchLockService.swift \
  macos/Sources/Workbench/Services/WorkbenchRunningStateService.swift \
  macos/Sources/Workbench/Services/WorkbenchSessionIndexService.swift \
  macos/Sources/Workbench/Services/WorkbenchSurfaceRegistry.swift \
  macos/Sources/Workbench/Store/WorkbenchStore.swift \
  macos/Sources/Workbench/UI/WorkbenchSidebarView.swift \
  macos/Sources/Workbench/UI/WorkbenchInspectorView.swift
```

Full macOS app build/test is currently blocked locally because full Xcode is not installed/selected. Once Xcode is available:

```sh
sudo xcode-select -s /Applications/Xcode.app
nix develop --command zig build -Demit-macos-app=false
nix develop --command nu macos/build.nu --scheme Ghostty --configuration Debug --action build
nix develop --command nu macos/build.nu --scheme Ghostty --configuration Debug --action test
```

## Dogfood status (2026-07-21)

Automated dogfood checks completed:

- `open -n macos/build/Debug/Ghostty.app` launches `com.mitchellh.ghostty.debug`.
- Debug app process is visible to System Events and has windows.
- Built dylib contains Workbench UI strings (`Claude Workbench`, `Workbench ready`, `Session Already Running`).
- `com.mitchellh.ghostty.debug` defaults: `Workbench.Enabled` unset (defaults true), `Workbench.SidebarVisible = 1`.
- Recent logs showed no Workbench crash/fatal/error output.

Manual visual checks still needed because screenshot/accessibility tree extraction is unreliable from this execution environment:

1. Confirm the left sidebar is visible in the Debug app window.
2. Confirm repo/worktree grouping looks correct for real Claude sessions.
3. Click a session and verify `claude --resume` opens in a new Ghostty tab.
4. Click a running session and verify focus-existing or Fork/Cancel alert behavior.
5. Confirm QuickTerminal is not wrapped by Workbench.

## P0 — Make the current MVP buildable and safe

Status: complete.

Completed:

- Accepted Xcode license externally and installed Metal Toolchain.
- `nix develop --command zig build -Demit-macos-app=false` generated `macos/GhosttyKit.xcframework`.
- `nix develop --command nu macos/build.nu --scheme Ghostty --configuration Debug --action build` passes.
- `nix develop --command nu macos/build.nu --scheme Ghostty --configuration Debug --action test` passes.
- Fixed app build issue in `WorkbenchTerminalRootView` by wrapping conditional root in `Group` before applying `.alert`.
- Fixed tests: optional unwrap, async XCTAssert autoclosure issue, transcript path standardization.

1. **Run full Xcode build and fix compile errors**
   - Command: `nix develop --command nu macos/build.nu --scheme Ghostty --configuration Debug --action build`
   - Pay special attention to `#if os(macOS)` around Workbench UI files because `macos/Sources` is a synchronized source group shared by targets.

2. **Run Workbench tests through Xcode**
   - Command: `nix develop --command nu macos/build.nu --scheme Ghostty --configuration Debug --action test`
   - Confirm `macos/Tests/Workbench/WorkbenchTests.swift` is picked up by the synchronized `Tests` group.

3. **Decide default feature flag state**
   - Current default: enabled.
   - Safer dogfood default: enabled in debug, disabled in release.
   - Suggested implementation: derive default from build config if an existing build-mode API is available in Swift.

4. **Manual dogfood checklist**
   - Launch normal terminal with sidebar visible.
   - Hide sidebar and show it again via reveal overlay.
   - Confirm QuickTerminal is not wrapped.
   - Click a session and verify it opens a new tab with `claude --resume <id>`.
   - Confirm feature disabled causes no `~/.claude` scan on model construction.

## P1 — M4 launcher lifecycle

Progress:

- Prototype Swift helper exists at `macos/WorkbenchHelper/ghostty-workbench-launcher.swift` and compiles/runs locally.
- It is intentionally outside `macos/Sources` so it is not auto-compiled into the app target.
- `WorkbenchHelperResolver` resolves override, bundled, and `/tmp/ghostty-workbench-launcher` development helper paths.
- `WorkbenchTerminalRootView` now passes the optional helper path into `WorkbenchLaunchRequest`.
- Helper has best-effort newline-delimited JSON lifecycle event emission when `--socket` is provided; end-to-end UDS listener validation is still pending.
- `WorkbenchLifecycleEventService` defines the event model, decoder, store-backed handler, and UDS accept-loop listener; `WorkbenchViewModel` owns listener lifetime only when `WorkbenchFeature.isLifecycleHelperEnabled` is enabled.

1. **Add `ghostty-workbench-launcher` helper**
   - Minimal helper should accept:
     - `--launch-id <uuid>`
     - `--session-id <id>` optional
     - `--socket <path>` optional future field
     - `--cwd <path>` optional future field
     - `-- <command> [args...]`
   - First version implemented: `chdir`, run via `/usr/bin/env`, wait, and preserve exit code.
   - Lifecycle event emission code exists for `started` / `exited` events.
   - Event decoder and store-backed handler exist.
   - App-side Unix-domain socket accept loop exists and is owned by `WorkbenchViewModel` when the feature is enabled.
   - `WorkbenchTerminalRootView` passes the listener socket path to helper launches.
   - Next: validate end-to-end lifecycle events in a full macOS dev environment.

2. **Bundle helper into the macOS app**
   - Add build/copy integration only after deciding whether helper is Swift, C, or Zig.
   - Keep helper small and independent of Ghostty internals.

3. **Use helper from `WorkbenchLauncherService`**
   - Helper wrapping support exists through `WorkbenchLaunchRequest.helperExecutable`.
   - Helper path resolution exists through `WorkbenchHelperResolver`.
   - Preserve display command as the plain `claude` invocation.
   - Keep shell quoting covered by tests.

4. **Persist launches**
   - On launch, write `WorkbenchLaunchRecord`.
   - When helper lifecycle is available, update pid/exitCode/exitedAt.

## P2 — M5 duplicate-session safety

Progress:

- Resume launches now call `WorkbenchViewModel.prepareLaunchRequest(...)` before opening a tab.
- `WorkbenchSurfaceRegistry` tracks session/launch to window mappings at window level for MVP focus-existing behavior.
- Resume is blocked if the session is already marked running or has an existing lock.
- Resume acquires a store-backed lock and marks the session `.launching` before opening the Ghostty tab.
- Lifecycle `exited` events release matching locks.

1. **Wire lock service into launch path**
   - Done for resume mode.
   - Fork/new/continue/worktree still bypass duplicate checks intentionally.
   - If already running, current behavior attempts `focusExisting(sessionId:)` via the registry.
   - If no window is found, a minimal duplicate-running alert offers Fork Session or Cancel.
   - If locked, current behavior is status message only.
   - Next: improve locked-session UX with an alert/sheet.

2. **Track surface/session mapping**
   - Initial window-level registry exists in `WorkbenchSurfaceRegistry`.
   - New Workbench-launched tabs register `sessionId` + `launchId` + `NSWindow`.
   - Running sessions first attempt `focusExisting(sessionId:)`; if no window is found, a minimal duplicate-running alert offers Fork Session or Cancel.
   - Next: replace window-level mapping with concrete surface UUID if/when exposed.
   - Next: update registry on tab close/focus for better stale cleanup.

3. **Duplicate sheet UX**
   - Minimal running-session alert exists: Fork Session / Cancel.
   - Focus Existing happens before the alert when registry has a window.
   - Next: add locked-session alert.
   - Later: add advanced/destructive Open Anyway.

## P3 — M6 git/worktree metadata

Status: mostly done.

Implemented:

- `WorkbenchGitService` computes git toplevel, common git dir repo key, branch, dirty count, origin-derived `org/repo`, and linked-worktree detection.
- `WorkbenchWorktreeGrouping` groups sessions by repo/worktree and keeps separate clones distinct.
- Sidebar now groups by worktree and shows branch/dirty/running chips.
- Git facts remain transient and are recomputed on refresh, not persisted as Workbench-owned data.

Remaining follow-ups:

1. Validate grouping visually in the full macOS app.
2. Add caching/expiry if refresh becomes slow on large session sets.
3. Add tests for git command failure paths once Xcode test execution is available.

## P4 — Indexing hardening

1. **Avoid full transcript reads for large JSONL**
   - Current implementation reads each transcript into memory.
   - Replace with streaming `FileHandle` line iteration or a bounded prefix/tail scan.

2. **Make JSONL scrape types configurable or isolated**
   - Current recognized types: `custom-title`, `ai-title`, `last-prompt`, `user`, `assistant`.
   - Keep scrape failure non-fatal.

3. **Agent SDK sidecar spike**
   - Add optional sidecar reader behind a feature flag.
   - Use SDK for `listSessions()`/`getSessionMessages()` if available.
   - Keep filesystem fallback as Tier 2.

## P5 — UI polish

1. **Inspector integration**
   - Currently `WorkbenchInspectorView` exists but is not mounted in the main root.
   - Decide whether it should be a right pane, bottom drawer, or popover.

2. **Sidebar actions**
   - Add explicit buttons for New Session, Continue Latest, Worktree Session.
   - Add rename UI for `localTitle`.

3. **Settings entry**
   - Avoid editing `MainMenu.xib` until the core compiles.
   - Later add View > Toggle Claude Workbench Sidebar.

## Known local environment blockers

- `xcodebuild` is installed but unusable because `xcode-select` points to Command Line Tools only.
- `zig`, `nu`, and `swiftlint` are not on normal PATH.
- Nix may provide missing tools, but full app validation still needs full Xcode.
