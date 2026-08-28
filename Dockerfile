# Build Docker. ONE image, TWO entrypoints: /bin/sumo-traffic-signals (the game
# server) and /bin/sumo-traffic-signals-player (the thin seat registrar). The
# whole policy set is env-switched inside this same image (PLAYER_PROMPT vs
# PLAYER_SCRIPTED=greedy|fixedcycle), which is what keeps a champion and a
# scripted filler byte-identical apart from their environment.
FROM debian:bookworm-slim AS build

RUN apt-get update && \
  apt-get install -y --no-install-recommends \
    build-essential \
    ca-certificates \
    curl \
    git && \
  rm -rf /var/lib/apt/lists/*

RUN if [ "$(dpkg --print-architecture)" = "amd64" ]; then \
    curl -fsSL \
      -o /usr/local/bin/nimby \
https://github.com/treeform/nimby/releases/download/0.1.26/nimby-Linux-X64; \
  elif [ "$(dpkg --print-architecture)" = "arm64" ]; then \
    curl -fsSL \
      -o /usr/local/bin/nimby \
https://github.com/treeform/nimby/releases/download/0.1.26/nimby-Linux-ARM64; \
  else \
    echo "unsupported arch: $(dpkg --print-architecture)" && exit 1; \
  fi && \
  chmod +x /usr/local/bin/nimby && \
  nimby use 2.2.4

ENV PATH="/root/.nimby/nim/bin:$PATH"

WORKDIR /workspace/signals
COPY nimby.lock .
RUN nimby --global sync nimby.lock

COPY . .
ARG NimFlags="-d:release -d:useMalloc --opt:speed --stackTrace:on"
ARG NimCommand="c"
ARG NimMain="src/sumo_traffic_signals.nim"
RUN nim $NimCommand \
  $NimFlags \
  --nimcache:/tmp/signals-nimcache \
  --out:sumo-traffic-signals \
  $NimMain && \
  nim c \
  $NimFlags \
  --nimcache:/tmp/signals-player-nimcache \
  --out:sumo-traffic-signals-player \
  src/sumo_traffic_signals_player.nim

# Run Docker.
FROM debian:bookworm-slim

RUN apt-get update && \
  apt-get install -y --no-install-recommends ca-certificates libcurl4 && \
  rm -rf /var/lib/apt/lists/*

WORKDIR /workspace/signals
COPY --from=build /workspace/signals/sumo-traffic-signals /bin/sumo-traffic-signals
COPY --from=build /workspace/signals/sumo-traffic-signals-player /bin/sumo-traffic-signals-player
COPY --from=build /workspace/signals/*.json ./
COPY --from=build /workspace/signals/data ./data
COPY --from=build /workspace/signals/client ./client

CMD ["/bin/sumo-traffic-signals"]
