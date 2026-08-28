## The game entrypoint. Forked from the starter's `src/ctf.nim`, INCLUDING the
## seed randomisation before `config.update` so every seed-derived draw follows
## the final seed — here that is the whole demand stream, which is a pure hash
## of `(seed, gate, tick)`.

import
  std/[json, os, sysrand],
  bitworld/runtime,
  signals/sim,
  signals/server

const LegacyFixedSeed = 0xA6019
  ## The compiled-in default seed, which doubles as the "nobody chose a seed"
  ## sentinel: a config carrying it (or no seed at all) gets a fresh random
  ## seed, because with a public fixed seed the arrival stream would be
  ## pre-computable by a controller.

proc seedPinned(configJson: string): bool =
  ## True when the runtime config explicitly pins a seed other than the
  ## sentinel (fixture recordings, the certification fixture, forensic re-runs).
  if configJson.len == 0:
    return false
  try:
    let node = parseJson(configJson)
    node.kind == JObject and node.hasKey("seed") and
      node["seed"].getInt != LegacyFixedSeed
  except CatchableError:
    false                       ## config.update reports the real parse error.

proc randomSeed(): int =
  ## A crypto-random 31-bit seed from the OS.
  var buf: array[4, byte]
  if not urandom(buf):
    raise newException(SignalsError, "OS entropy source unavailable")
  (int(buf[0]) shl 24 or int(buf[1]) shl 16 or
    int(buf[2]) shl 8 or int(buf[3])) and 0x7FFF_FFFF

proc stripUnpinnedSeed(configJson: string): string =
  ## Drops the sentinel seed from an unpinned config so it cannot clobber the
  ## randomized seed injected before `config.update`.
  if configJson.len == 0:
    return configJson
  try:
    let node = parseJson(configJson)
    if node.kind == JObject and node.hasKey("seed"):
      node.delete("seed")
    $node
  except CatchableError:
    configJson

proc echoStartupConfig(config: GameConfig, runtimeConfig: RuntimeConfig) =
  ## Prints the effective startup config. Tokens are never printed.
  echo "sumo-traffic-signals config: host=", runtimeConfig.host,
    " port=", runtimeConfig.port,
    " seed=", config.seed,
    " variant=", config.variant,
    " num_agents=", config.numAgents,
    " minPlayers=", config.minPlayers,
    " turnTicks=", config.turnTicks,
    " maxTicks=", config.maxTicks,
    " turns=", config.turnsPerEpisode(),
    " par=", config.parThroughput,
    " wallClockBudgetSeconds=", config.wallClockBudgetSeconds,
    " fastMode=", config.fastMode,
    " showPlayerLabels=", config.showPlayerLabels

when isMainModule:
  let
    runtimeConfig = readRuntimeConfig()
    localReplayPath =
      if runtimeConfig.replayUri.len > 0:
        getTempDir() / ("signals-replay-" & $getCurrentProcessId() & ".replay")
      else:
        ""

  var config = defaultGameConfig()
  if seedPinned(runtimeConfig.config):
    config.update(runtimeConfig.config)
  else:
    ## Randomize BEFORE parsing: `config.update` resolves everything
    ## seed-derived, so the randomized seed must already be in place.
    config.seed = randomSeed()
    config.update(stripUnpinnedSeed(runtimeConfig.config))
    echo "seed not pinned; randomized"
  config.echoStartupConfig(runtimeConfig)

  echo "starting sumo-traffic-signals on ",
    runtimeConfig.host, ":", runtimeConfig.port
  runServerLoop(
    runtimeConfig.host,
    runtimeConfig.port,
    config,
    localReplayPath,
    (if runtimeConfig.replayMode: runtimeConfig.replay else: ""),
    runtimeConfig
  )
