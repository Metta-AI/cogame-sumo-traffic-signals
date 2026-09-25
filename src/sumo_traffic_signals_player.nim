## Scripted, Claude prompt, and Jev policies over the same private seat view.
## The game receives metadata and ordinary actions, never model credentials.

import std/[json, monotimes, options, os, strutils, times]
import bitworld/spriteprotocol
import whisky
import signals/[sim_types, llm, model_pacing,
  player_policy, prompt_policy, jev_policy]

const
  ConnectAttempts = 240
  ConnectRetryMs = 500
  RegistrationResends = 10
  ResendEveryFrames = 24
  ReconnectAttempts = 6

proc registrationBlob(kind, scripted, policy: string): string =
  blobFromSpriteChat($(%*{
    "type": "register", "protocol": PlayerProtocolId,
    "kind": kind, "scripted": scripted,
    "policy": policy.truncateRunes(MaxPolicyLabelRunes)
  }))

proc readyBlob(): string =
  result = newString(1)
  result[0] = char(0x85)

when isMainModule:
  let url = getEnv("COWORLD_PLAYER_WS_URL", getEnv("COGAMES_ENGINE_WS_URL"))
  if url.len == 0:
    quit("COWORLD_PLAYER_WS_URL is not set", 1)
  let
    prompt = getEnv("PLAYER_PROMPT").strip().truncateRunes(MaxPromptRunes)
    scripted = getEnv("PLAYER_SCRIPTED", "greedy").strip()
    jev = getEnv("PLAYER_JEV") == "1"
    kind = if jev: "jev" elif prompt.len > 0: "prompt" else: "scripted"
    label = block:
      let explicit = getEnv("PLAYER_POLICY_LABEL").strip()
      if explicit.len > 0: explicit
      elif jev: "jev"
      elif prompt.len > 0: "prompt"
      else: scripted
  var pacer = newModelPacer()
  let promptClient = if kind == "prompt": newLlmClient() else: nil
  echo "signals player: kind=", kind, " baseline=", scripted,
    " label=", label

  proc dial(attempts: int): WebSocket =
    for attempt in 0 ..< attempts:
      try:
        return newWebSocket(url)
      except CatchableError as error:
        if attempt == 0:
          echo "signals player: game not listening yet (", error.msg,
            "); retrying"
        sleep(ConnectRetryMs)
    nil

  var socket = dial(ConnectAttempts)
  if socket == nil:
    quit("signals player: game never accepted a connection", 1)
  echo "signals player: connected"

  var reconnects = 0
  while true:
    var sessionFrames = 0
    try:
      socket.send(registrationBlob(kind, scripted, label), BinaryMessage)
      var resends = 0
      while true:
        let received = socket.receiveMessage()
        if received.isNone:
          continue
        let packet = received.get()
        if packet.kind == TextMessage:
          let request = parseJson(packet.data)
          if request{"type"}.getStr() == "decision":
            doAssert request["protocol"].getStr() == PlayerProtocolId
            let
              started = getMonoTime()
              view = request["observation"]
              budgetMs = request["deadline_ms"].getInt()
            var
              source = "scripted"
              cause = ""
              action: JsonNode
            case kind
            of "jev":
              if jevConfigured():
                action = chooseJevAction(view, pacer, budgetMs)
                source = "llm"
              else:
                action = scriptedAction(view, scripted)
                source = "fallback"
                cause = "no_credentials"
            of "prompt":
              if promptClient.disabled:
                action = scriptedAction(view, scripted)
                source = "fallback"
                cause = "no_credentials"
              else:
                action = choosePromptAction(promptClient, pacer, view,
                  prompt, budgetMs)
                source = "llm"
            else:
              action = scriptedAction(view, scripted)
            socket.send(blobFromSpriteChat($(%*{
              "type": "action", "protocol": PlayerProtocolId,
              "turn": request["turn"], "action": action,
              "source": source, "cause": cause,
              "latency_ms": (getMonoTime() - started).inMilliseconds.int
            })), BinaryMessage)
          continue
        inc sessionFrames
        if resends < RegistrationResends and
            sessionFrames mod ResendEveryFrames == 1:
          inc resends
          socket.send(registrationBlob(kind, scripted, label), BinaryMessage)
        socket.send(readyBlob(), BinaryMessage)
    except CatchableError as error:
      echo "signals player: socket closed (", error.msg, ")"
    if sessionFrames == 0 or reconnects >= ReconnectAttempts:
      break
    inc reconnects
    socket = dial(ReconnectAttempts)
    if socket == nil:
      echo "signals player: game is no longer listening, exiting cleanly"
      break
    echo "signals player: reconnected, re-registering"
  quit(0)
