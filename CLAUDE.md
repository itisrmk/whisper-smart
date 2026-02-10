# CLAUDE.md

## Project
VisperflowClone — macOS menu-bar push-to-talk dictation app.

## Objectives
- Hold hotkey to record
- Release to transcribe
- Paste into focused app
- Keep UX minimal, fast, and reliable

## Workflow Rules
1. Plan mode first for non-trivial changes.
2. Implement in small, verifiable slices.
3. Run compile checks after each slice.
4. Never remove existing functionality without explicit reason.
5. Keep module boundaries clear:
   - app/Core for engine/pipeline
   - app/UI for presentation
   - app/App for bootstrapping

## Coding Rules
- Swift 5.9+
- Prefer protocol-driven boundaries
- MainActor for UI-touching code
- No secrets in code/logs
- Add TODOs only when paired with actionable context

## Verification
- `swiftc -typecheck` for all Swift files in repo
- Smoke check state machine flow by direct invocation where possible
- Ensure no compile errors before handoff

## Current Milestone
Ship an end-to-end local prototype:
hotkey hold -> audio capture -> stub STT -> text insertion
