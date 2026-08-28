#!/usr/bin/env python3
"""Fork client/replay_broadcast.html from coworld-ctf's page into this game's.

The page is the STARTER'S PAGE PLUS AN APPENDED GAME BLOCK — never a rewrite
that reuses its ids (the cogame-gridlock 2026-08-23 finding). This script is
the record of every edit made to the inherited region, so a reviewer can diff
the starter's file against ours and see exactly these changes and no others:

  * the elements design SS-Viewer lists as REMOVED (#viewpanel and its zoom
    bar + minimap, #fpv and all its children, #povBadge, the ctf scorebug
    internals, the .ec-heart glyphs, the beat CSS for kinds this game never
    emits, and the perk/handicap badges) go, markup, CSS and wiring together;
  * the splice hook `window.PaintballChrome` becomes `window.SignalsChrome`
    with the same `install(PB_CTX)` / `frame(s, ctx, jumped)` /
    `event(e, s, ctx)` signatures, and PB_MODE becomes SIG_MODE latching on
    the frame's `city` field;
  * the scorebug plates' CONTENTS, the event routing and the endcard's stat
    columns are retargeted;
  * the chrome label re-mappings of design SS-Viewer are applied one by one;
  * everything else is byte-for-byte the starter's.

Run:  python3 tools/fork_broadcast_page.py <starter page> <sig block> <out>
"""
from __future__ import annotations

import re
import sys


def cut_between(text: str, start_marker: str, end_marker: str, label: str) -> str:
    """Delete from the line containing start_marker up to (excluding) the line
    containing end_marker."""
    lines = text.split("\n")
    start = end = -1
    for i, line in enumerate(lines):
        if start < 0 and start_marker in line:
            start = i
        elif start >= 0 and end_marker in line:
            end = i
            break
    if start < 0 or end < 0:
        raise SystemExit(f"fork_broadcast_page: could not locate {label}")
    del lines[start:end]
    return "\n".join(lines)


def replace_once(text: str, old: str, new: str, label: str) -> str:
    if text.count(old) != 1:
        raise SystemExit(
            f"fork_broadcast_page: {label} matched {text.count(old)} times, want 1"
        )
    return text.replace(old, new)


def replace_all(text: str, old: str, new: str, label: str) -> str:
    if old not in text:
        raise SystemExit(f"fork_broadcast_page: {label} not found")
    return text.replace(old, new)


def main() -> None:
    src, block_path, out = sys.argv[1:4]
    page = open(src, encoding="utf-8").read()
    block = open(block_path, encoding="utf-8").read()

    # ---------------------------------------------------------------- CSS ---
    page = cut_between(
        page,
        "/* POV eye badge shown when a slot is inspected (fog-honesty lens) */",
        "/* ---------- 5. TRANSPORT ---------- */",
        "the #povBadge / #fpv / #viewpanel CSS block",
    )
    page = cut_between(
        page,
        "/* Opt-OUT of the #viewpanel overlay (zoom bar + minimap) by param only:",
        "</style>",
        "the ?viewpanel=0 CSS opt-out",
    )
    # The ctf scorebug internals and the endcard heart glyphs.
    for selector in (
        ".hillchip",
        ".hcap",
        ".flagicon",
        ".lives-num",
        ".lives-label",
        ".squad-pip",
        ".pb-tags",
        ".squad",
        ".ec-heart",
        ".beat-marker.kill",
        ".beat-marker.steal",
        ".beat-marker.return",
        ".beat-marker.capture",
        ".beat-marker.gamestart",
        ".beat-marker.hillflip",
        ".beat-marker.tagout",
        ".beat-marker.gameover",
        ".perk",
        ".ec-badge",
    ):
        page = re.sub(
            r"(?m)^" + re.escape(selector) + r"[^{\n]*\{[^}]*\}\n", "", page
        )
        page = re.sub(
            r"(?m)^[^\n{}]*" + re.escape(selector) + r"[^{\n]*\{[^}]*\}\n", "", page
        )

    # ------------------------------------------------------------- markup ---
    page = cut_between(
        page,
        "<!-- View controls: zoom the board with buttons/slider/keys/pinch",
        '<div id="mmwarn">',
        "the #viewpanel markup",
    )
    page = cut_between(
        page,
        '<div id="povBadge">',
        '<div id="bannerlane"></div>',
        "the #povBadge and #fpv markup",
    )
    page = replace_once(
        page,
        """    <!-- Plates are generated per active team (2-4) by ensureScorebug(): one
         per side for classic red/blue, two stacked per side for 3-4 teams.
         Each plate holds a flag icon, one inline NAME · Lives · count row
         (mirrored on the right so names flank the clock), and the squad pip
         strip (one pip per player: alive / down / eliminated; clickable →
         POV lens). -->""",
        """    <!-- Plates are generated per controller (four, always) by
         ensureScorebug(): two per side, so both names flank the clock. Each
         plate holds the controller's avatar, one inline NAME · Served · count
         row, and a sub-line with its waiting figure and its fallback glyph.
         The seat's REAL policy name is spectator-side only; the board itself
         draws aliases, because showPlayerLabels is false. -->""",
        "the scorebug markup comment",
    )

    # --------------------------------------------------------- label re-map --
    page = replace_once(
        page,
        '<div id="mmwarn">Replay hash mismatch — showing recorded inputs</div>',
        '<div id="mmwarn">Replay hash mismatch — showing recorded orders</div>',
        "the #mmwarn caption",
    )
    page = replace_once(
        page,
        '<div class="caption" id="clock-caption">In the locker room</div>',
        '<div class="caption" id="clock-caption">Signals dark</div>',
        "the #clock-caption placeholder",
    )
    page = replace_all(
        page,
        '<span class="momentum-label">LIVES LEAD</span>',
        '<span class="momentum-label">THROUGHPUT</span>',
        "the momentum label",
    )
    page = replace_all(
        page,
        "Spoilers: kills / flag story / winner on the timeline ahead of the playhead (o)",
        "Spoilers: green waves / spillbacks / gridlock on the timeline ahead of the playhead (o)",
        "the spoilers button title",
    )
    page = replace_once(
        page,
        "Filling hoppers with fresh paint&hellip;",
        "Booting the signal controllers&hellip;",
        "the locker-room caption placeholder",
    )
    # The rotating prep-talk lines under the loading scene are paintbot's
    # crew getting their paint pods ready; here it is a control room booting.
    page = replace_once(
        page,
        """    var lines = [
      'Filling hoppers with fresh paint…',
      'Pump check: one, two. One, two…',
      'Polishing visors to a mirror shine…',
      'Shaking the paint pods awake…',
      'Squats. Even robots warm up…',
      'Topping off the CO₂…',
      'Chalking up the wheels…',
      'Reviewing the game plan…'
    ];""",
        """    var lines = [
      'Booting the signal controllers…',
      'Loop detectors reporting in…',
      'Amber timings: two ticks, all four ways…',
      'Sixteen intersections, one number…',
      'Radio check: Alpha, Beta, Gamma, Delta…',
      'Clearing the overnight queues…',
      'Waking the gate counters…',
      'Reviewing the overnight offsets…'
    ];""",
        "the locker-room prep-talk lines",
    )
    # Two starter CSS class names carry paintbot's vocabulary into markup this
    # fork still uses: the plate flip animation and the accented feed row.
    page = replace_all(page, "flagflip", "plateflip", "the plate flip keyframes")
    page = replace_all(page, "flagkill", "radiorow", "the accented feed row")
    page = replace_once(
        page,
        "  var markBeat = C.markBeat, killMarkerTeam = C.killMarkerTeam, "
        "renderBeatMarkers = C.renderBeatMarkers;\n",
        "  var markBeat = C.markBeat, renderBeatMarkers = C.renderBeatMarkers;\n",
        "the beat alias line",
    )

    # ------------------------------------------------------- JS: removals ---
    page = replace_once(
        page,
        """  // ?viewpanel=0 hides the #viewpanel overlay (zoom bar + minimap). This is an
  // explicit opt-OUT only — the default (param absent) is unchanged for every
  // existing embed, so the League Replayer still shows zoom + minimap. See the
  // #271/#272 lesson: hiding the panel for ALL embeds broke the Replayer shell.
  // Billboards (Lobby hero) and thumbnail capture append &viewpanel=0.
  try {
    if (new URLSearchParams(location.search).get('viewpanel') === '0')
      document.body.setAttribute('data-noviewpanel', '1');
  } catch (e) {}

""",
        "",
        "the view-panel opt-out wiring",
    )
    page = cut_between(
        page,
        "// The server ships the static minimap wall silhouette ONCE (RLE of a coarse",
        "// ---------- scorebug ----------",
        "the fpv tactical-map ingest",
    )
    page = replace_once(page, "    ingestFpMap(s);\n", "", "the ingestFpMap call")
    page = replace_once(page, "    renderPov(s);\n", "", "the renderPov call")
    page = replace_once(page, "    ingestCapHearts(s);\n", "", "the ingestCapHearts call")
    page = cut_between(
        page,
        "// ---------- pov + mismatch ----------",
        "function renderMismatch(s) {",
        "the pov / first-person / tactical-map pipeline",
    )
    page = cut_between(
        page,
        "  var minimapBox = $('minimap');",
        "  canvas.addEventListener('dblclick', function (ev) {",
        "the zoom bar and minimap wiring",
    )
    # The core still reports its transform, and the page still owns the
    # touch-action rule that decides whether a one-finger drag belongs to the
    # page or the board. Everything else the view panel fed is gone with it.
    page = replace_once(
        page,
        "  canvas.addEventListener('dblclick', function (ev) {",
        """  // The zoom bar and the board inset are DROPPED in this fork: the board is a
  // fixed 34 x 26 cell city with no off-frame area, so there is nothing to
  // locate and nothing to zoom toward. What survives is the one rule the
  // panel did not own — whether a one-finger drag belongs to the page.
  function syncViewUi(t) {
    syncTouchAction(t || core.getTransform());
  }

  canvas.addEventListener('dblclick', function (ev) {""",
        "the surviving view-UI hook",
    )
    page = cut_between(
        page,
        "  function applyEvent(e, s) {",
        "// (teamOf / esc live in the shared chrome",
        "the paintbot event routing",
    )
    page = cut_between(
        page,
        "//  End-card (§5/§8) — the END SEGMENT: verdict, win condition and match",
        "//  Transport wiring — DOM controls emit the legacy chat chars +",
        "the paintbot endcard",
    )
    page = cut_between(
        page,
        "  var squadMaxLives = 1;",
        "  // Rebuild the scorebug plates when the active team set changes",
        "the squad pip strip",
    )
    page = cut_between(
        page,
        "  function updateFlag(id, team, tstate, s) {",
        "  function shortName(n) {",
        "the flag icon wiring",
    )
    page = replace_once(
        page,
        "  $('povBadge').addEventListener('click', function () { send('v:-1'); });\n",
        "",
        "the #povBadge click wiring",
    )
    page = replace_once(
        page, "  var setHandicap = C.setHandicap;\n", "", "the setHandicap alias"
    )
    # The armed cog pose belonged to the first-person billboards, which are
    # gone; this fork ships only the `_front` masters (design SS-Sim module,
    # "Kept, by path"), so the `_front_gun` requests were twelve 404s on every
    # page load.
    page = replace_once(
        page,
        """  var COG_ART = {}, COG_ART_GUN = {};
  ['red', 'blue', 'green', 'yellow'].forEach(function (team) {
    COG_ART[team] = new Image();
    COG_ART[team].src = COG_BASE + '/soldier_' + team + '_front.png';
    COG_ART_GUN[team] = new Image();
    COG_ART_GUN[team].src = COG_BASE + '/soldier_' + team + '_front_gun.png';
  });""",
        """  var COG_ART = {};
  ['red', 'blue', 'green', 'yellow'].forEach(function (team) {
    COG_ART[team] = new Image();
    COG_ART[team].src = COG_BASE + '/soldier_' + team + '_front.png';
  });""",
        "the armed cog pose",
    )
    page = replace_once(
        page,
        """  function cogArtFor(team, armed) {
    var gun = COG_ART_GUN[team], plain = COG_ART[team];
    if (armed && cogArtReady(gun)) return gun;
    if (cogArtReady(plain)) return plain;
    return cogArtReady(gun) ? gun : null;
  }""",
        """  function cogArtFor(team, armed) {
    var plain = COG_ART[team];
    return cogArtReady(plain) ? plain : null;
  }""",
        "the armed cog pose picker",
    )

    # ------------------------------------------------- JS: the splice hook ---
    page = replace_all(page, "window.PaintballChrome", "window.SignalsChrome",
                       "the splice hook")
    page = replace_all(page, "PB_MODE", "SIG_MODE", "the mode flag")
    page = replace_once(
        page,
        "if (!SIG_MODE && s.regime !== undefined) SIG_MODE = true;",
        "if (!SIG_MODE && s.city !== undefined) SIG_MODE = true;",
        "the mode latch",
    )
    page = replace_all(page, "window.CtfStaticReplay", "window.SignalsStaticReplay",
                       "the static-replay adapter")

    # ---------------------------------------------- JS: the new renderers ---
    page = replace_once(
        page,
        "  function renderMismatch(s) {\n",
        """  function renderMismatch(s) {
    var el = $('mmwarn');
    if (s.mm >= 0) {
      el.textContent = 'Replay hash mismatch at tick ' + s.mm +
        ' — showing recorded orders';
    }
""",
        "the mismatch caption",
    )
    page = replace_once(
        page,
        "// (teamOf / esc live in the shared chrome",
        """  // Every event goes through the appended game block, which draws LABELLED,
  // CLICKABLE buttons on the scrubber (cityBeat) instead of chrome_common's
  // unlabelled div markers. When the block handles a kind it returns true.
  function applyEvent(e, s) {
    if (SIG_MODE && window.SignalsChrome &&
        window.SignalsChrome.event(e, s, PB_CTX)) {
      beatPulse();
      return;
    }
  }

  // (teamOf / esc live in the shared chrome""",
        "the signals event routing",
    )
    page = replace_once(
        page,
        "  // ============================================================\n"
        "  //  Transport wiring — DOM controls emit the legacy chat chars +",
        SIGNALS_ENDCARD
        + "  // ============================================================\n"
        "  //  Transport wiring — DOM controls emit the legacy chat chars +",
        "the signals endcard",
    )

    # ------------------------------------------- JS: the scorebug plates ----
    page = cut_between(
        page,
        "  // Rebuild the scorebug plates when the active team set changes",
        "  function shortName(n) {",
        "the paintbot scorebug",
    )
    page = replace_once(
        page,
        "  function shortName(n) {",
        SIGNALS_SCOREBUG + "  function shortName(n) {",
        "the signals scorebug",
    )

    # ------------------------------------------------- the appended block ---
    page = replace_once(
        page,
        page[page.index("<!-- ============================================================\n"
                        "     PAINTBALL additions"):],
        block.lstrip("\n"),
        "the appended game block",
    )

    open(out, "w", encoding="utf-8").write(page)
    print(f"forked {src} -> {out} ({len(page)} bytes)")


SIGNALS_SCOREBUG = """  // ---------- scorebug plates (CONTENTS retargeted; the plate, the sides and
  //            the clock column are the inherited ones) ----------
  // Four controllers, two plates a side, so both names flank the clock. The
  // seat's REAL policy name rides the SPECTATOR side only.
  var COG_ALIAS = ['ALPHA', 'BETA', 'GAMMA', 'DELTA'];
  var COG_QUAD = ['NW', 'NE', 'SW', 'SE'];
  var sbTeams = null;
  function slotOfTeam(team) {
    return ['red', 'blue', 'green', 'yellow'].indexOf(team);
  }
  function ensureScorebug(teams) {
    var key = teams.join(',') + (SIG_MODE ? '|sig' : '');
    if (sbTeams === key) return;
    sbTeams = key;
    var sides = [$('plates-l'), $('plates-r')];
    sides[0].innerHTML = '';
    sides[1].innerHTML = '';
    sides[0].classList.toggle('row', teams.length > 2);
    sides[1].classList.toggle('row', teams.length > 2);
    teams.forEach(function (team, i) {
      var slot = slotOfTeam(team);
      var plate = document.createElement('div');
      plate.className = 'plate ' + team + ' ' + (i % 2 === 0 ? 'side-l' : 'side-r');
      plate.setAttribute('data-team', team);
      plate.innerHTML =
        '<div class="plate-av" id="av-' + team + '"></div>' +
        '<div class="team-id">' +
        '<div class="lives-line">' +
        '<span class="team-name plate-name" id="name-' + team + '">' +
        (COG_ALIAS[slot] || team.toUpperCase()) + '</span>' +
        '<span class="quad-tag" id="quad-' + team + '">' +
        (COG_QUAD[slot] || '') + '</span>' +
        '<span class="served-label">Served</span>' +
        '<span class="served-num" id="served-' + team + '">—</span>' +
        '</div>' +
        '<div class="sig-sub">' +
        '<span class="wait-num" id="wait-' + team + '"></span>' +
        '<span class="fb-glyph" id="fb-' + team + '"></span>' +
        '</div>' +
        '</div>';
      sides[i % 2].appendChild(plate);
      var av = plate.querySelector('.plate-av');
      if (av && COG_ART[team] && COG_ART[team].src) {
        av.style.backgroundImage = 'url("' + COG_ART[team].src + '")';
      }
    });
  }

  function renderScorebug(s) {
    var teams = activeTeams(s);
    ensureScorebug(teams);
    var tr = s.teams || {};
    var bestWait = Infinity;
    teams.forEach(function (team) {
      var t = tr[team];
      if (t) bestWait = Math.min(bestWait, t.wait || 0);
    });
    teams.forEach(function (team) {
      var slot = slotOfTeam(team);
      var t = tr[team] || {};
      setName('name-' + team, teamName(s, team, COG_ALIAS[slot] || team.toUpperCase()));
      $('served-' + team).textContent = tr[team] ? (t.served || 0) : '—';
      $('wait-' + team).textContent = tr[team] ? (t.wait || 0) + ' car-s waiting' : '';
      $('fb-' + team).textContent = (t.fb || 0) > 0 ? '\\u21af' : '';
      var plate = document.querySelector('.plate[data-team="' + team + '"]');
      if (plate) {
        plate.classList.toggle(
          'leader', tr[team] && (t.wait || 0) <= bestWait && s.ph === 'playing');
      }
    });
  }

"""


SIGNALS_ENDCARD = """  // ============================================================
  //  End-card — the END SEGMENT: how the city did, held on screen for ~10 s
  //  before a looping restart. It stops at var(--band) (the inherited rule)
  //  and every seek dismisses it (the inherited path).
  // ============================================================
  var ecTeamsKey = null;
  function ensureEndcardTeams(teams) {
    var key = teams.join(',');
    if (ecTeamsKey === key) return;
    ecTeamsKey = key;
    var host = $('ec-teams');
    host.innerHTML = '';
    teams.forEach(function (team) {
      var wrap = document.createElement('div');
      wrap.className = 'ec-team ' + team;
      wrap.id = 'ec-' + team;
      host.appendChild(wrap);
    });
  }

  function renderEndcard(s) {
    var o = s.over;
    if (!o) return;
    var teams = activeTeams(s);
    ensureEndcardTeams(teams);
    $('ec-headline').textContent =
      (o.through || 0) + '/' + (o.demand || 0) + ' CARS THROUGH \u00b7 PAR ' +
      (o.par || 0) + (o.met ? ' MET' : ' MISSED');
    $('ec-headline').classList.toggle('red', (o.gridlocks || 0) > 0);
    $('ec-wincond').textContent = endcardRule(o);
    $('ec-how').innerHTML =
      '<div class="ec-thead"><span>Controller</span><span>Served</span>' +
      '<span>Waiting</span><span>Waves</span><span>Spillbacks</span></div>' +
      teams.map(function (team) {
        var t = (o.teams && o.teams[team]) || {};
        return '<div class="ec-row ' + team + '">' +
          '<span class="ec-tname">' + esc(rosterName(s, slotOfTeam(team)) || team.toUpperCase()) + '</span>' +
          '<span>' + (t.served || 0) + '</span>' +
          '<span>' + (t.wait || 0) + '</span>' +
          '<span>' + (o.waves || 0) + '</span>' +
          '<span>' + (o.spills || 0) + '</span>' +
          '</div>';
      }).join('') +
      '<div class="ec-summary">' + (o.waves || 0) + ' green waves, ' +
      (o.spills || 0) + ' spillbacks, ' + (o.gridlocks || 0) + ' gridlock, ' +
      (o.waiting || 0) + ' car-seconds lost, ' + (o.rejected || 0) +
      ' turned away</div>' +
      '<div class="ec-score">CITY SCORE ' + (o.score || 0) + '</div>';
    $('endcard').classList.add('on');
  }

  function endcardRule(o) {
    switch (o.endRule) {
      case 'cleared': return 'CITY CLEARED';
      case 'gridlock': return 'GRIDLOCK STALL';
      case 'wallClock': return 'WALL-CLOCK STOP';
      case 'fault': return 'FAULT — NO RESULT';
      default: return 'FULL PERIOD';
    }
  }

"""


if __name__ == "__main__":
    main()
