#!/usr/bin/env bash
# Records one fixture episode. Thin wrapper over tools/record_fixture.nim,
# which needs no listener and no player processes: every seat plays its
# scripted baseline in-process, the same mix the certification fixture seats.
#
#   tools/record_fixture.sh tests/fixtures/cert-seed42.replay 42 grid4x4
set -euo pipefail
cd "$(dirname "$0")/.."
OUT="${1:?usage: record_fixture.sh <out.replay> [seed] [variant]}"
SEED="${2:-42}"
VARIANT="${3:-grid4x4}"
mkdir -p "$(dirname "$OUT")"
nim c -r --hints:off -d:release --path:src \
  -o:/tmp/signals-record-fixture tools/record_fixture.nim "$OUT" "$SEED" "$VARIANT"
ls -la "$OUT"
