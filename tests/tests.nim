## The whole suite, for a local `nim c -r tests/tests.nim` from the repo ROOT.
## `ci.yml` runs every tests/*.nim file individually instead, twice — once
## debug, once -d:release — so this file is the developer's entry point, not
## CI's.
{.warning[UnusedImport]: off.}
import
  shard_1,
  shard_2,
  shard_3,
  shard_4
{.warning[UnusedImport]: on.}
