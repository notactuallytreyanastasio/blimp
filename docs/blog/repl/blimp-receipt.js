// BlimpReceipt - turn a Blimp view host's runtime state feed into a receipt.
//
//   var rec = new BlimpReceipt.Recorder({ sender: postToConsole, seconds: 10, mode: 'notable' });
//   rec.start();             // capture begins with the next feed
//   rec.feed(state);         // same state the canvas and inspector get, after every render
//   rec.remaining();         // seconds left in the window
//   // after `seconds`, one markdown receipt goes to sender(md) and capture stops.
//
// Frames follow the native feeder (scripts/trace_receipt.py): one per
// top-level send (from the page), with the nested actor-to-actor sends
// collapsed by count and the state fields that changed underneath. The
// `:view` render cascade is dropped. Mode 'notable' also drops gravity
// ticks that only moved the falling piece down.

(function (root, factory) {
  if (typeof module === 'object' && module.exports) module.exports = factory();
  else root.BlimpReceipt = factory();
})(typeof self !== 'undefined' ? self : this, function () {
  'use strict';

  var COLS = 56;

  function shortRef(ref) {
    if (!ref) return 'page';
    var m = /^ref<(.+):(\d+)>$/.exec(ref);
    return m ? m[1].replace(/^.*\./, '') + '#' + m[2] : ref;
  }

  // ASCII only: the thermal printer speaks CP437/Windows-1252, not arrows.
  function clip(s) { return s.length <= COLS ? s : s.slice(0, COLS - 3) + '...'; }

  function call(msg, args) { return ':' + msg + (args && args.length ? '(' + args.join(', ') + ')' : ''); }

  // Group a feed's messages into frames; each top-level send starts one,
  // the `:view` cascade is skipped.
  function splitFrames(messages) {
    var frames = [], cur = null, seen = null;
    (messages || []).forEach(function (m) {
      if (!m.from) {
        if (m.message === 'view') { cur = null; return; }
        cur = { head: m, sends: [], diffs: [] };
        seen = {};
        frames.push(cur);
        return;
      }
      if (!cur) return;
      var key = m.from + '>' + m.target + ':' + m.message;
      if (seen[key]) { seen[key].count++; return; }
      seen[key] = { from: m.from, to: m.target, message: m.message, args: m.args || [], reply: m.reply === undefined ? null : m.reply, count: 1 };
      cur.sends.push(seen[key]);
    });
    return frames;
  }

  function stateDiffs(before, after) {
    var prev = {};
    (before || []).forEach(function (a) { prev[a.ref] = a; });
    var out = [];
    (after || []).forEach(function (a) {
      var old = prev[a.ref] ? prev[a.ref].state || {} : {};
      Object.keys(a.state || {}).forEach(function (k) {
        if (old[k] !== a.state[k]) out.push({ actor: a.ref, type: a.type, field: k, from: old[k], to: a.state[k] });
      });
    });
    return out;
  }

  // A gravity tick that only moved the piece down is not worth paper.
  function isNotable(frame) {
    if (frame.head.message !== 'tick') return true;
    return frame.diffs.some(function (d) { return !(/Piece$/.test(d.type) && d.field === 'y'); });
  }

  function headingText(frame) {
    return clip(shortRef(frame.head.target) + ' ' + call(frame.head.message, frame.head.args));
  }

  // The lines under a heading: sends, state changes, reply.
  function bodyLines(frame) {
    var lines = [];
    frame.sends.forEach(function (s) {
      var arrow = ' -> ' + (s.from === s.to ? 'self' : shortRef(s.to)) + ' ';
      var tail = (s.reply !== null ? ' => ' + s.reply : '') + (s.count > 1 ? ' x' + s.count : '');
      lines.push(clip('  ' + shortRef(s.from) + arrow + call(s.message, s.args) + tail));
    });
    frame.diffs.forEach(function (d) {
      lines.push(clip('  * ' + shortRef(d.actor) + '.' + d.field + ' ' + (d.from === undefined ? '' : d.from + ' ') + '-> ' + d.to));
    });
    lines.push(clip('  => ' + (frame.head.reply === null ? 'queued' : frame.head.reply)));
    return lines;
  }

  function frameLines(frame) {
    return ['## ' + headingText(frame), '', '```'].concat(bodyLines(frame), ['```', '']);
  }

  function render(frames, title, when, maxLines) {
    maxLines = maxLines || 120;
    when = when || new Date().toTimeString().slice(0, 8);
    var out = ['# ' + (title || 'BLIMP TRACE'), '', when, ''];
    var used = 0, shown = 0;
    for (var i = 0; i < frames.length; i++) {
      var lines = frameLines(frames[i]);
      if (used + lines.length > maxLines - 1) break;
      out = out.concat(lines);
      used += lines.length;
      shown++;
    }
    if (shown < frames.length) out.push('_' + (frames.length - shown) + ' more frames not shown_');
    return out.join('\n').replace(/\s+$/, '') + '\n';
  }

  function Recorder(opts) {
    opts = opts || {};
    this.sender = opts.sender || function () {};
    this.seconds = opts.seconds || 10;
    this.mode = opts.mode || 'notable';
    this.clock = opts.clock || function () { return Date.now(); };
    this.title = opts.title || 'BLIMP TRACE';
    this.maxLines = opts.maxLines || 120;
    this.onChange = opts.onChange || function () {};
    this.active = false;
    this.frames = [];
    this.framer = null;
    this.startedAt = 0;
  }

  Recorder.prototype.start = function () {
    this.active = true;
    this.frames = [];
    this.framer = new Framer(this.mode);
    this.startedAt = this.clock();
    this.onChange(this);
  };

  Recorder.prototype.remaining = function () {
    if (!this.active) return 0;
    return Math.max(0, this.seconds - Math.floor((this.clock() - this.startedAt) / 1000));
  };

  Recorder.prototype.feed = function (state) {
    if (!this.active || !state) return;
    this.frames = this.frames.concat(this.framer.feed(state));
    if (this.clock() - this.startedAt >= this.seconds * 1000) this.stop();
    else this.onChange(this);
  };

  Recorder.prototype.stop = function () {
    this.active = false;
    var frames = this.frames;
    this.frames = [];
    if (frames.length) this.sender(render(frames, this.title, null, this.maxLines), frames.length);
    this.onChange(this);
  };

  // Frames from one feed, honouring the mode. Shared by Recorder and LivePrinter.
  function Framer(mode) { this.mode = mode || 'notable'; this.prev = null; }
  Framer.prototype.feed = function (state) {
    if (!state) return [];
    if (this.prev === null) { this.prev = state.actors || []; return []; }
    var frames = splitFrames(state.messages);
    var diffs = stateDiffs(this.prev, state.actors);
    this.prev = state.actors || [];
    if (frames.length) frames[0].diffs = diffs;
    var mode = this.mode;
    return frames.filter(function (f) { return mode === 'everything' || isNotable(f); });
  };

  // -- live streaming: raw ESC/POS, continuous paper --------------------------
  var ESC = '\x1b';
  var INIT = ESC + '@', FONT_B = ESC + 'M\x01', BOLD_ON = ESC + 'E\x01', BOLD_OFF = ESC + 'E\x00';

  // Live printing over a WebSocket to the console's /api/live/ws. The
  // upgrade counts as one print; after that every frame goes straight to
  // the paper and the server feeds and cuts when the socket closes.
  // `socket` is a factory returning a WebSocket-like object (send, close,
  // readyState, onopen/onclose/onerror); tests pass a fake.
  function LivePrinter(opts) {
    opts = opts || {};
    this.socketFactory = opts.socket || function () { throw new Error('no socket factory'); };
    this.title = opts.title || 'BLIMP TRACE live';
    this.mode = opts.mode || 'notable';
    this.maxLinesPerChunk = opts.maxLinesPerChunk || 60;
    this.onChange = opts.onChange || function () {};
    this.active = false;
    this.status = 'idle';     // idle | connecting | live | closed | error
    this.error = null;
    this.pending = [];
    this.framer = null;
    this.sock = null;
    this.sentLines = 0;
  }

  LivePrinter.prototype.start = function () {
    var self = this;
    this.active = true;
    this.pending = [];
    this.framer = new Framer(this.mode);
    this.sentLines = 0;
    this.error = null;
    this.status = 'connecting';
    var sock = this.socketFactory();
    this.sock = sock;
    sock.onopen = function () {
      if (self.sock !== sock) return;
      self.status = 'live';
      var when = new Date().toTimeString().slice(0, 8);
      sock.send(INIT + FONT_B + BOLD_ON + self.title + BOLD_OFF + '\n' + when + '\n\n');
      self._flush();
      self.onChange(self);
    };
    sock.onerror = function (e) {
      if (self.sock !== sock) return;
      self.error = (e && e.message) || 'socket error';
      self.status = 'error';
      self.onChange(self);
    };
    sock.onclose = function () {
      if (self.sock !== sock) return;
      self.active = false;
      self.status = self.status === 'error' ? 'error' : 'closed';
      self.sock = null;
      self.onChange(self);
    };
    if (sock.readyState === 1) sock.onopen();
    this.onChange(this);
  };

  LivePrinter.prototype.feed = function (state) {
    if (!this.active) return;
    var self = this;
    this.framer.feed(state).forEach(function (f) {
      self.pending.push(BOLD_ON + headingText(f) + BOLD_OFF);
      self.pending = self.pending.concat(bodyLines(f), ['']);
    });
    this._flush();
    this.onChange(this);
  };

  // Paper is finite: a burst keeps only its newest lines and says so.
  LivePrinter.prototype._takePending = function () {
    var lines = this.pending;
    this.pending = [];
    if (lines.length > this.maxLinesPerChunk) {
      var skipped = lines.length - this.maxLinesPerChunk;
      lines = ['... ' + skipped + ' lines skipped ...'].concat(lines.slice(skipped));
    }
    return lines;
  };

  LivePrinter.prototype._flush = function () {
    if (!this.sock || this.sock.readyState !== 1 || !this.pending.length) return false;
    var lines = this._takePending();
    this.sentLines += lines.length;
    this.sock.send(lines.join('\n') + '\n');
    return true;
  };

  // Close the socket; the console feeds and cuts on its side.
  LivePrinter.prototype.stop = function () {
    if (!this.active) return;
    this._flush();
    this.active = false;
    var sock = this.sock;
    this.sock = null;
    this.status = 'closed';
    if (sock) sock.close();
    this.onChange(this);
  };

  // WebSocket factory for the console: ws://host/api/live/ws?backend=usb
  function liveSocket(url, backend) {
    var qs = Object.keys(backend).map(function (k) { return encodeURIComponent(k) + '=' + encodeURIComponent(backend[k]); }).join('&');
    return function () { return new WebSocket(url + (qs ? '?' + qs : '')); };
  }

  // Raw bytes to /api/print/raw; backend goes in the query string.
  function postRaw(url, backend) {
    var qs = Object.keys(backend).map(function (k) { return encodeURIComponent(k) + '=' + encodeURIComponent(backend[k]); }).join('&');
    return function (bytes) {
      return fetch(url + (qs ? '?' + qs : ''), { method: 'POST', mode: 'no-cors', headers: { 'content-type': 'text/plain' }, body: bytes });
    };
  }

  // POST to the nerves_receipts console without CORS: text/plain keeps it a
  // simple request (no preflight); the opaque response is fine, the console
  // prints or rate-limits on its own.
  function postToConsole(url, backend) {
    return function (markdown) {
      var body = { markdown: markdown, backend: backend.backend || 'usb' };
      if (backend.path) body.path = backend.path;
      if (backend.host) body.host = backend.host;
      if (backend.port) body.port = backend.port;
      return fetch(url, { method: 'POST', mode: 'no-cors', headers: { 'content-type': 'text/plain' }, body: JSON.stringify(body) });
    };
  }

  return { Recorder: Recorder, LivePrinter: LivePrinter, Framer: Framer, liveSocket: liveSocket, postRaw: postRaw, splitFrames: splitFrames, stateDiffs: stateDiffs, isNotable: isNotable, render: render, postToConsole: postToConsole, shortRef: shortRef, COLS: COLS };
});
