# tests/fixtures

Committed replay fixtures live here. `tests/test_signals_replay.nim`'s
GameVersion sweep walks every `*.replay` in this directory and asserts it
carries the CURRENT `GameVersion`, so a fixture recorded against an older rule
set fails the build rather than loading and re-simulating wrong.

Record one with:

```bash
tools/record_fixture.sh tests/fixtures/cert-seed42.replay 42 grid4x4
```

The sweep is never vacuous: it also records a fresh replay in a temp directory
and sweeps that, and it corrupts the version byte of the fresh one to prove the
codec REFUSES a mismatched version rather than tolerating it.
