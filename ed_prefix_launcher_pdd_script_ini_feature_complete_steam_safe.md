# Project Plan: Reliable, Steam-Safe Elite Dangerous Launcher

## Purpose
Build and maintain a launcher workflow for Elite Dangerous that prioritizes **reliability, predictability, and recoverability** over speed, UI polish, or extra features.

## Priority Statement
This plan explicitly optimizes for:
1. **Reliability first** (stable behavior across sessions and environments)
2. **Operational clarity** (easy diagnosis through logs and clear states)
3. **Safe fallbacks** (degrade gracefully when optional components fail)

This plan does **not** prioritize launch speed, flashy UX behavior, or non-essential automation.

## Reliability Objectives
- Ensure Steam-safe process behavior so game lifecycle is tracked correctly.
- Ensure tools (especially EDCoPilot) launch consistently with retries and bounded waits.
- Ensure failures are visible and recoverable, not silent.
- Ensure configuration is deterministic with clear precedence.
- Ensure shutdown behavior is predictable in game-only, tools-only, and combined modes.

## Scope
### In scope
- Robust game launch orchestration (Steam command path and MinEd path).
- Tool orchestration with explicit delay/retry behavior.
- Conservative defaults designed to reduce race conditions.
- Logging and troubleshooting guidance.

### Out of scope
- Performance tuning for faster startup at the expense of safety checks.
- Cosmetic/"flashy" launch effects or non-operational UX enhancements.
- Deep fixes for third-party app internals.

## Design Principles
- **Fail safe, not fast**: wait for known-good preconditions before proceeding.
- **Explicit over implicit**: all key behavior controlled by config and documented defaults.
- **Bounded retries**: retry transient failures, but stop with clear logging when limits are reached.
- **Idempotent operations**: repeated runs should converge to stable state.
- **Minimal surprise**: same input/config should yield same outcomes.

## Operational Modes
- **Game + tools**: launch game and orchestrate tools with reliability guards.
- **Game only**: launch game without tool orchestration.
- **Tools only**: run tools with optional attached wait behavior.

## Reliability Controls
- Conservative startup delays where required.
- Health/state checks before and after critical launch steps.
- Retry windows for tool startup.
- Optional environment checks (e.g., runtime bus presence) with reliable fallback path.
- Structured logs for main flow and watcher/tool flow.

## Configuration Strategy
Configuration precedence (highest to lowest):
1. CLI arguments
2. Environment variables
3. INI configuration
4. Safe defaults

Guidance:
- Defaults should favor successful, stable launches across common Linux/Proton setups.
- Optional features remain opt-in unless proven stable by default.

## Verification Plan
For every meaningful change, verify:
1. Game starts and Steam tracks lifecycle correctly.
2. EDCoPilot/tool startup follows delay + retry policy.
3. Tools-only mode does not unintentionally terminate launched tools.
4. Logs clearly show decisions, fallbacks, retries, and terminal outcomes.
5. Failure paths are explicit and non-destructive.

## Rollout and Maintenance
- Introduce changes incrementally.
- Prefer backwards-compatible config changes.
- Add or update troubleshooting notes alongside behavior changes.
- Regressions in reliability block release, even if performance improves.

## Definition of Done
A plan update is complete when:
- It increases or preserves launch reliability.
- It does not introduce ambiguous behavior.
- It includes clear validation criteria.
- It avoids speed/flashiness-oriented scope creep.
