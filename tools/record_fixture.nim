## Records one fixture episode with no server and no sockets: every seat plays
## its scripted baseline, which is exactly what `tools/ci/docker_smoke.sh`'s
## certification fixture does. Replaces the starter's `record_fixture.sh`
## bot-herding dance, which needs a listener and sixteen player processes this
## game has no use for.
##
##   nim c -r --path:src tools/record_fixture.nim tests/fixtures/<name>.replay <seed>

import
  std/[os, strutils],
  bitworld/runtime,
  signals/[server, sim, roster]

when isMainModule:
  if paramCount() < 1:
    quit("usage: record_fixture <out.replay> [seed] [variant]", 1)
  let
    outPath = paramStr(1)
    seed = (if paramCount() >= 2: parseInt(paramStr(2)) else: 42)
    variant = (if paramCount() >= 3: paramStr(3) else: "grid4x4")
  var config = defaultGameConfig()
  config.seed = seed
  config.variant = variant
  config.update("{\"seed\":" & $seed & ",\"variant\":\"" & variant & "\"}")
  var runtimeConfig = RuntimeConfig()
  let sim = runEpisode(config, runtimeConfig, outPath)
  echo describeState(sim)
  echo sim.cityResultsJson()
  echo "wrote ", outPath, " (", getFileSize(outPath), " bytes)"
