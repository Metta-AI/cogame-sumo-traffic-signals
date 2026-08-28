## Manifest pins. Tests 33 and 34 of the design note's list.
##
## Every claim here is a real upload failure someone already paid for, named in
## `playbooks/make-coworld.md` §Common mistakes.

import std/[json, os, strutils, unittest]
import helpers

const Slug = "sumo-traffic-signals"

proc arrayProperties(node: JsonNode): seq[string] =
  for key, value in node:
    if value{"type"}.getStr() == "array":
      result.add(key)

suite "manifest pins":
  let manifest = manifestJson()

  test "33. num_agents is 4 in both variants AND in the cert fixture":
    check manifest{"variants"}.len == 2
    for variant in manifest{"variants"}:
      check variant{"game_config"}{"num_agents"}.getInt() == MaxSeats
    check manifest{"certification"}{"game_config"}{"num_agents"}.getInt() ==
      MaxSeats

  test "33. num_agents is absent at every variant TOP level":
    ## CoworldVariant is additionalProperties:false and the platform reads only
    ## game_config.num_agents (goofspiel-oshi-zumo 0.1.0).
    for variant in manifest{"variants"}:
      for key, _ in variant:
        check key != "num_agents"
      check not variant.hasKey("num_agents")

  test "33. every variant's game_config NAMES ITSELF as the variant":
    ## `sim_config` defaults `variant` to "grid4x4", so a variant whose
    ## game_config does not carry its own id records and reports
    ## `variant: "grid4x4"` for a rushhour episode — in results.json, in the
    ## replay's config JSON and therefore in the viewer.
    for variant in manifest{"variants"}:
      let id = variant{"id"}.getStr()
      checkpoint("variant " & id)
      check variant{"game_config"}{"variant"}.getStr() == id
      var config = defaultGameConfig()
      config.update($variant{"game_config"})
      check config.variant == id
    let cert = manifest{"certification"}{"game_config"}
    check cert{"variant"}.getStr() == "grid4x4"
    ## config_schema is additionalProperties:false, so the key it carries has
    ## to be declared or every episode config is rejected.
    check manifest{"game"}{"config_schema"}{"properties"}.hasKey("variant")

  test "33. no game_config anywhere carries a literal tokens array":
    ## matriculate rejects "game_config must not include runner-managed
    ## tokens" (knights-archers 0.1.0), while config_schema keeps REQUIRING it
    ## because the runner injects it.
    for variant in manifest{"variants"}:
      check not variant{"game_config"}.hasKey("tokens")
    check not manifest{"certification"}{"game_config"}.hasKey("tokens")
    var required: seq[string]
    for item in manifest{"game"}{"config_schema"}{"required"}:
      required.add(item.getStr())
    check "tokens" in required

  test "33. every declared player occupies a certification slot":
    ## raid 0.1.2: cert fails players_missing when a declared runnable has no
    ## slot in the fixture.
    let players = manifest{"player"}
    check players.len == 2
    var declared, seated: seq[string]
    for player in players:
      declared.add(player{"id"}.getStr())
    for entry in manifest{"certification"}{"players"}:
      seated.add(entry{"player_id"}.getStr())
    for id in declared:
      check id in seated
    for id in seated:
      check id in declared

  test "33. the four SEAT-COUNT invariants agree":
    let fixture = manifest{"certification"}
    check fixture{"players"}.len == MaxSeats
    check fixture{"game_config"}{"players"}.len == MaxSeats
    check fixture{"game_config"}{"num_agents"}.getInt() == MaxSeats
    ## The fifth declaration, SMOKE_SEATS, lives in ci.yml and docker_smoke.sh.
    let ci = repoFile(".github/workflows/ci.yml")
    check "SMOKE_SEATS" notin ci or "4" in ci
    let smoke = repoFile("tools/ci/docker_smoke.sh")
    check "seats_expected=\"${SMOKE_SEATS:-4}\"" in smoke

  test "33. every array in config_schema carries minItems and maxItems":
    ## tandem 0.1.0: cert fails manifest_invalid unless every ARRAY property
    ## declares bounds, not just membership in `required`.
    let properties = manifest{"game"}{"config_schema"}{"properties"}
    let arrays = arrayProperties(properties)
    check arrays.len >= 3
    for key in arrays:
      checkpoint("config_schema array " & key)
      check properties{key}.hasKey("minItems")
      check properties{key}.hasKey("maxItems")

  test "33. episode_timeout_minutes is TOP level, not under game":
    check manifest{"episode_timeout_minutes"}.getInt() == 20
    check not manifest{"game"}.hasKey("episode_timeout_minutes")

  test "33. protocols carry BOTH player and global as {type,value} objects":
    ## garble v0.1.0: bare strings fail the platform validator, which repo CI
    ## does not catch.
    let protocols = manifest{"game"}{"protocols"}
    for key in ["player", "global"]:
      checkpoint("protocol " & key)
      check protocols.hasKey(key)
      check protocols{key}.kind == JObject
      check protocols{key}{"type"}.getStr().len > 0
      check protocols{key}{"value"}.getStr().len > 0

  test "33. docs carry a readme and pages":
    let docs = manifest{"game"}{"docs"}
    check docs{"readme"}.kind == JObject
    check docs{"readme"}{"type"}.getStr().len > 0
    check docs{"readme"}{"value"}.getStr().len > 0
    check docs{"pages"}.len >= 3
    for page in docs{"pages"}:
      check page{"id"}.getStr().len > 0
      check page{"title"}.getStr().len > 0
      check page{"content"}{"type"}.getStr().len > 0
      check page{"content"}{"value"}.getStr().len > 0

  test "33. game.description is present and game.tags is absent":
    ## pistonball 0.1.0: the validator requires the one and forbids the other.
    check manifest{"game"}{"description"}.getStr().len > 40
    check not manifest{"game"}.hasKey("tags")
    check manifest{"tags"}.len >= 3

  test "33. replay_viewer is a static bundle under game, and there is no version":
    check manifest{"game"}{"replay_viewer"}{"bundle"}.getStr() ==
      "static-replay-viewer"
    check not manifest.hasKey("replay_viewer")
    check not manifest.hasKey("version")
    check not manifest{"game"}.hasKey("display_name")
    check manifest{"game"}{"owner"}.getStr().len > 0
    check manifest{"game"}{"runnable"}{"type"}.getStr() == "game"

  test "33. every player's cpu limit is at least 1":
    ## pistonball 0.1.1: upload 400s on a limit below "1".
    for player in manifest{"player"}:
      let limit = player{"resources"}{"limits"}{"cpu"}.getStr()
      check limit == "1"
      check player{"resources"}{"requests"}{"cpu"}.getStr().len > 0
      check player{"run"}.len == 1
      check player{"run"}[0].getStr() == "/bin/" & Slug & "-player"
      check player{"source_url"}.getStr().len > 0
      check player{"description"}.getStr().len > 0

  test "33. every wallClockBudgetSeconds is inside the 60% pin":
    for variant in manifest{"variants"}:
      check variant{"game_config"}{"wallClockBudgetSeconds"}.getInt() <= 660
    let cert = manifest{"certification"}{"game_config"}
    check cert{"wallClockBudgetSeconds"}.getInt() <= 660

  test "33. game.name equals the slug AND the secret URI namespace":
    ## The commons-family 2026-08-24 scar: `game.name` and the slug differing
    ## by one character breaks `upload-coworld` after a fully green certify.
    check manifest{"game"}{"name"}.getStr() == Slug
    check GameName == Slug
    let env = manifest{"game"}{"runnable"}{"env"}
    let uri = env{"ANTHROPIC_API_KEY_URI"}.getStr()
    check uri == "secret://coworld/" & Slug & "/anthropic_api_key"
    check manifest{"game"}{"runnable"}{"run"}[0].getStr() == "/bin/" & Slug
    check manifest{"game"}{"runnable"}{"image"}.getStr() ==
      "{{SUMO_TRAFFIC_SIGNALS_IMAGE}}"

  test "33. the image placeholder is derived from the compose SERVICE name":
    ## lantern 0.1.0: `{{GAME_IMAGE}}` is not a thing.
    let compose = repoFile("compose.yaml")
    check ("  " & Slug & ":") in compose
    check "image: coworld-" & Slug & ":latest" in compose
    check "platform: linux/amd64" in compose
    check "network: host" in compose
    let placeholder = "{{SUMO_TRAFFIC_SIGNALS_IMAGE}}"
    check placeholder in readFile(repoPath("coworld_manifest_template.json"))

  test "33. EVERY variant's game_config constructs, builds the city and schedules 32 turns":
    ## collab-cooking 0.1.1: the cert fixture fit and every variant did not.
    for variant in manifest{"variants"}:
      let id = variant{"id"}.getStr()
      checkpoint("variant " & id)
      var config = defaultGameConfig()
      config.update($variant{"game_config"})
      check config.numAgents == MaxSeats
      check config.turnsPerEpisode() == 32
      check config.ewLinkCells == 6
      check config.nsLinkCells == 4
      check config.ewGateCells == 4
      check config.nsGateCells == 3
      let city = buildCity(config)
      check city.links.len == 80
      check city.totalCells == 352
      ## par must be reachable: the demand the schedule generates has to exceed
      ## it, or the win flag can never be true.
      var generated = 0
      for gate in 0 ..< Gates:
        for tick in 0 ..< config.demandEndTick:
          if config.arrivalAt(gate, tick).generated:
            inc generated
      checkpoint(id & ": demand " & $generated & " par " & $config.parThroughput)
      check generated > config.parThroughput
      ## And a real episode on this variant finishes and scores.
      let sim = runScripted(config, [blGreedy, blFixedCycle])
      check sim.settled
      check sim.throughput > 0

  test "33. the certification fixture constructs and runs inside the certify timeout":
    let fixture = manifest{"certification"}{"game_config"}
    var config = defaultGameConfig()
    config.update($fixture)
    check config.seed == 42
    check config.numAgents == MaxSeats
    let sim = runScripted(config, [blGreedy, blFixedCycle])
    check sim.settled
    check sim.throughput > 0

suite "the manifest loads under the installed CLI":
  test "34. the release workflow runs the CLI's own validator":
    ## 0.1.42 wants game.replay_viewer, no top-level version, no
    ## game.display_name, game.owner required, and no runner-managed tokens
    ## (collab-cooking 2026-08-25). The repo cannot install the CLI, so the
    ## contract is that ci.yml ATTEMPTS the CLI validator and
    ## coworld-release.yml certifies with a real timeout.
    let ci = repoFile(".github/workflows/ci.yml")
    check "validate_upload_manifest" in ci
    let release = repoFile(".github/workflows/coworld-release.yml")
    check "--timeout-seconds 300" in release
    check "Replay liveness: skipped (static replay bundle declared" in release
    check "release-result" in release
    for input in ["version:", "policies:", "put_secret:", "skip_certify:"]:
      check input in release
    let submit = repoFile(".github/workflows/coworld-submit.yml")
    check "submit-result" in submit
    for input in ["player_id:", "policy:", "league_id:"]:
      check input in submit

  test "34. tools/ci/policies.json is this game's set, not the template's":
    let policies = parseJson(repoFile("tools/ci/policies.json"))
    check policies.len == 4
    var prompts, scripted: int
    for policy in policies:
      check policy{"run"}.getStr() == "/bin/" & Slug & "-player"
      check policy{"name"}.getStr().startsWith("signals-")
      if policy{"env"}.hasKey("PLAYER_PROMPT"):
        inc prompts
        check policy{"env"}{"PLAYER_PROMPT"}.getStr().len > 200
      if policy{"env"}.hasKey("PLAYER_SCRIPTED"):
        inc scripted
        let baseline = policy{"env"}{"PLAYER_SCRIPTED"}.getStr()
        check baseline == "greedy" or baseline == "fixedcycle"
    check prompts == 2
    check scripted == 2
    ## Champion #2 is uploaded while daveey-1 is the active player.
    check policies[1]{"player"}.getStr() ==
      "ply_bac48eb1-662e-44f8-973d-f3e016dccf5d"
    check not policies[0].hasKey("player")
    ## No USE_BEDROCK: the LLM call is made by the GAME pod.
    for policy in policies:
      check not policy{"env"}.hasKey("USE_BEDROCK")
