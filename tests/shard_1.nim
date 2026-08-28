## CI shard 1 of 4. The shards are balanced by measured suite runtime so the
## four binaries finish together; `tests/tests.nim` imports all four, so every
## shard member is also part of the full local run.
{.warning[UnusedImport]: off.}
import
  test_signals_sim
{.warning[UnusedImport]: on.}
