// Offline smoke for the forked broadcast page: loads the REAL page in jsdom
// with the real chrome_common.js and broadcast_core.js, hands it a synthetic
// chrome frame through the page's own `onText` seam, and fails if anything
// throws.
//
// Why this exists: `tools/ci/viewer_smoke.mjs` needs the wasm bundle and a
// real replay, so it only runs in the wasm-viewer job, after a Docker build.
// This one runs in the `test` job in seconds and catches the failure mode that
// costs the most: a forked chrome that reaches for an element the fork
// deleted, throws on its FIRST frame, and latches static_replay.js into
// `failed` — which the load test then reports only as a timeout.
//
//   node tools/ci/page_smoke.mjs client/replay_broadcast.html
//
// jsdom has no canvas, so getContext is shimmed. Nothing about the BOARD is
// tested here (that is the wasm viewer's job); this is the CHROME's contract
// with the frame JSON.

import { readFileSync } from 'node:fs';
import { createRequire } from 'node:module';

// jsdom is resolved through require so JSDOM_MODULE can point at an installed
// copy when node_modules is elsewhere (CI installs it into $RUNNER_TEMP).
const require = createRequire(import.meta.url);
const { JSDOM } = require(process.env.JSDOM_MODULE || 'jsdom');

const pagePath = process.argv[2] || 'client/replay_broadcast.html';
const raw = readFileSync(pagePath, 'utf8');
const chromeCommon = readFileSync('client/chrome_common.js', 'utf8');
const wire = `window.SIGNALS_WIRE={speeds:[1,2,4,8,16],fps:24,chromeSpriteId:4090,` +
  `cellPx:16,boardCellsW:34,boardCellsH:26,framesPerTick:2,seats:4,maxSayRunes:120};` +
  `window.CTF_WIRE=window.SIGNALS_WIRE;`;

// The static bundle's script order: wire constants, shared chrome, the replay
// adapter, then the page IIFE. Here the adapter is a stub that captures the
// page's own callbacks.
const html = raw
  .replace('<!-- WIRE_CONSTANTS -->', `<script>${wire}</script>`)
  .replace('<!-- CHROME_COMMON -->', `<script>${chromeCommon}</script>`)
  .replace('<!-- BROADCAST_CORE -->', '<script>window.__ADAPTER__()</script>');

const dom = new JSDOM(html, {
  runScripts: 'dangerously',
  pretendToBeVisual: true,
  url: 'https://example.test/client/replay?replay=x',
  beforeParse(window) {
    window.__ADAPTER__ = () => {
      const stubTransform = {
        scale: 1, offsetX: 0, offsetY: 0, nativeW: 544, nativeH: 416,
        zoom: 1, minZoom: 1, maxZoom: 12, fitScale: 1,
        focusX: 0, focusY: 0, visW: 544, visH: 416
      };
      window.SignalsStaticReplay = {
        createCore(config) {
          window.__CFG__ = config;
          return {
            // start() fires the two callbacks the real core fires, because a
            // forked page that lost the definition of something they call
            // throws HERE and nowhere else: the wasm-viewer job saw
            // "syncViewUi is not defined" from exactly this seam.
            start() {
              if (config.onFirstFrame) config.onFirstFrame();
              if (config.onTransform) config.onTransform(stubTransform);
            },
            stop() {},
            sendCommand(text) { (window.__SENT__ ||= []).push(text); },
            clickMap() {},
            zoomAt() {}, setZoom() {}, panBy() {}, panByMap() {}, panTo() {},
            resetView() {},
            attachMinimap() {},
            getTransform: () => stubTransform,
            setViewportFit() {},
            setViewportSize() {},
            getPaceStats: () => ({ enabled: false, queued: 0, presented: 0, interval: 42, draws: 1 })
          };
        }
      };
      window.ResizeObserver = class { observe() {} unobserve() {} disconnect() {} };
      const ctx2d = new Proxy({}, {
        get: (_t, key) => {
          if (key === 'canvas') return { width: 1, height: 1 };
          if (key === 'measureText') return () => ({ width: 10 });
          if (key === 'createRadialGradient' || key === 'createLinearGradient') {
            return () => ({ addColorStop() {} });
          }
          if (key === 'createImageData' || key === 'getImageData') {
            return () => ({ data: new Uint8ClampedArray(4) });
          }
          return () => {};
        },
        set: () => true
      });
      window.HTMLCanvasElement.prototype.getContext = () => ctx2d;
      window.HTMLCanvasElement.prototype.transferControlToOffscreen = undefined;
      window.__ERRORS__ = [];
      window.addEventListener('error', (event) => {
        window.__ERRORS__.push(String(event.error || event.message));
      });
    }
  }
});

const { window } = dom;
const errors = window.__ERRORS__ || [];
const config = window.__CFG__;
if (!config || typeof config.onText !== 'function') {
  console.error('FAIL: the page never created its core (no onText seam)');
  process.exit(1);
}

function frame(overrides = {}) {
  const teams = {};
  const colours = ['red', 'blue', 'green', 'yellow'];
  const names = ['daveey', 'daveey-1', 'Baseline (1)', 'Baseline (2)'];
  const roster = [];
  colours.forEach((colour, slot) => {
    teams[colour] = {
      lives: 40 + slot, policies: [names[slot]],
      alias: ['Alpha', 'Beta', 'Gamma', 'Delta'][slot],
      quad: ['NW', 'NE', 'SW', 'SE'][slot],
      served: 40 + slot, wait: 700 + slot * 30, changes: 30 + slot,
      fb: slot === 1 ? 1 : 0, llm: slot < 2 ? 30 : 0,
      kind: slot < 2 ? 'llm' : 'scripted', dead: false
    };
    roster.push({
      s: slot, name: names[slot], alias: teams[colour].alias, team: colour,
      quad: teams[colour].quad, pol: names[slot], kind: teams[colour].kind,
      signals: ['A1', 'A2', 'B1', 'B2'], served: 40 + slot,
      wait: 700 + slot * 30, changes: 30 + slot, fb: teams[colour].fb,
      dead: false
    });
  });
  const tally = [];
  for (const label of ['A', 'B', 'C', 'D', '1', '2', '3', '4']) {
    tally.push({
      label, axis: label >= 'A' ? 'row' : 'col',
      pips: ['NSG', 'EWG', 'CLR', 'NSL'], waves: 2
    });
  }
  return Object.assign({
    t: 120, mt: 256, ph: 'playing', lob: 0, pl: true, sp: 1, mx: 256, st: 0,
    lp: false, sk: false, ff: false, en: true, mm: -1, bs: 1, pov: -1,
    teams, roster, events: [],
    city: { rows: 4, cols: 4, cell: 16, w: 34, h: 26 },
    turn: 15, turns: 32, turnTicks: 8, through: 161, par: 260, demand: 205,
    rejected: 4, waiting: 3120, waves: 3, spills: 12, gridlocks: 1,
    gridlockTicks: 22, starves: 1, deferred: 40, travel: 8000, stops: 500,
    spill: ['C2>C3', 'B3>C3'], ring: ['B3>C3', 'C3>C2', 'C2>B2', 'B2>B3'],
    ringTicks: 22, tally,
    lulls: [[40, 90]],
    citybeats: [
      { t: 30, k: 'wave', slot: -1, label: 'green wave — click to jump here' },
      { t: 60, k: 'spillback', slot: 0, label: 'a block filled up' },
      { t: 90, k: 'gridlock', slot: -1, label: 'gridlock ring' },
      { t: 100, k: 'fallback', slot: 1, label: 'a controller missed the call' },
      { t: 240, k: 'end', slot: -1, label: 'the city settles' }
    ],
    lead: {
      teams: ['red', 'blue', 'green', 'yellow'],
      pts: [[0, 0, 0, 0, 0], [120, 161, 4, 161, 4], [240, 372, 14, 372, 14]]
    }
  }, overrides);
}

const events = [
  { k: 'turn', n: 15 },
  { k: 'order', slot: 2, at: 'C2', verb: 'wave', phase: 'EWG', delay: 6, t: 120 },
  { k: 'order', slot: 2, at: 'C1', verb: 'hold', phase: 'NSG', delay: 0, t: 120 },
  { k: 'say', slot: 2, text: 'eastbound wave on row C: C1 at +0, C2 at +6, Delta take C3 at +12', t: 120 },
  { k: 'phasechange', at: 'C2', slot: 2, from: 'NSG', to: 'EWG', t: 121 },
  { k: 'starve', at: 'A2', slot: 0, approach: 'E', t: 122 },
  { k: 'spillback', link: 'C2>C3', at: 'C3', slot: 3, t: 123 },
  { k: 'spillclear', link: 'C2>C3', ticks: 12, t: 124 },
  { k: 'gridlock', links: ['B3>C3', 'C3>C2'], ats: ['C3', 'C2'], t: 125 },
  { k: 'gridlockclear', links: ['B3>C3'], ticks: 22, t: 126 },
  { k: 'wave', corridor: 'C', dir: 'eastbound', ats: ['C1', 'C2', 'C3', 'C4'], vehicles: 5, t: 127 },
  { k: 'exit', gate: 'eC4', travel: 40, stops: 2, total: 175, t: 128 },
  { k: 'gatejam', gate: 'nA3', at: 'A3', slot: 1, t: 129 },
  { k: 'gateclear', gate: 'nA3', ticks: 10, t: 130 },
  { k: 'fallback', slot: 1, cause: 'timeout', t: 131 },
  { k: 'end', reason: 'complete', endRule: 'cleared', throughput: 372, par: 260, demand: 386 }
];

function push(state) {
  config.onText(JSON.stringify(state));
}

let feedAfterEvents = 0;
try {
  push(frame({ ph: 'lobby', lob: 12, t: 0 }));
  push(frame());
  push(frame({ events }));
  // A seek CLEARS the feed by design, so the feed is counted here — before the
  // jump — rather than at the end.
  feedAfterEvents = window.document.querySelectorAll('#killfeed .feed-row').length;
  push(frame({ t: 200, events: [] }));
  // A game-over frame must hydrate the endcard even when reached by a seek.
  push(frame({
    t: 241, ph: 'gameover', events: [],
    over: {
      winner: '', draw: false, timeLimit: false,
      teams: {
        red: { lives: 214, served: 214, wait: 742, changes: 38, score: 371985000 },
        blue: { lives: 231, served: 231, wait: 861, changes: 41, score: 371984990 },
        green: { lives: 208, served: 208, wait: 799, changes: 36, score: 371985000 },
        yellow: { lives: 226, served: 226, wait: 740, changes: 39, score: 371985000 }
      },
      reason: 'complete', endRule: 'cleared', through: 372, par: 260,
      demand: 386, rejected: 14, waiting: 3142, waves: 11, spills: 26,
      gridlocks: 1, score: 371985000, met: true
    },
    hold: 7
  }));
} catch (error) {
  console.error('FAIL: the page threw on a frame:', error && error.stack || error);
  process.exit(1);
}

if (errors.length) {
  console.error('FAIL: window errors during the frames:\n' + errors.join('\n'));
  process.exit(1);
}

const doc = window.document;
const checks = [
  ['scorebug plates', doc.querySelectorAll('#scorebug .plate').length === 4],
  ['pressure rail rows', doc.querySelectorAll('#sigpressure .pr-row').length === 4],
  ['corridor tally bars', doc.querySelectorAll('#sigtally .tl-bar').length === 8],
  ['scrubber beats are buttons',
    doc.querySelectorAll('#scrub button.beat-marker').length >= 5],
  ['feed rows', feedAfterEvents > 0],
  ['endcard is on', doc.getElementById('endcard').classList.contains('on')],
  ['endcard header is retargeted',
    doc.getElementById('ec-how').innerHTML.includes('Controller') &&
    doc.getElementById('ec-how').innerHTML.includes('Spillbacks')],
  ['clock shows throughput',
    doc.getElementById('clock-time').textContent.includes('THROUGH')],
  ['spillback chip lit', doc.getElementById('chip-spill').classList.contains('on')],
  ['gridlock chip lit', doc.getElementById('chip-ring').classList.contains('on')]
];
let bad = 0;
for (const [what, ok] of checks) {
  if (!ok) { console.error(`FAIL: ${what}`); bad++; }
}
if (bad) process.exit(1);

console.log(JSON.stringify({
  ok: true,
  plates: doc.querySelectorAll('#scorebug .plate').length,
  beats: doc.querySelectorAll('#scrub button.beat-marker').length,
  feed: feedAfterEvents,
  sent: window.__SENT__ || []
}));
