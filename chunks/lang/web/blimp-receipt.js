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
  var ESC = '\x1b', GS = '\x1d';
  var INIT = ESC + '@', FONT_B = ESC + 'M\x01', BOLD_ON = ESC + 'E\x01', BOLD_OFF = ESC + 'E\x00';
  var CUT = '\n\n\n' + GS + 'VB\x14';   // GS V 66 20: feed then partial cut

  // The console allows maxPerMinute posts per client; the header and the
  // final cut count too, so chunks go out at most every `every` ms and only
  // when the sliding window has room. tick() should be called about once a
  // second by the host so deferred chunks and the cut still go out.
  function LivePrinter(opts) {
    opts = opts || {};
    this.sender = opts.sender || function () {};
    this.title = opts.title || 'BLIMP TRACE live';
    this.clock = opts.clock || function () { return Date.now(); };
    this.every = opts.every || 12500;
    this.maxPerMinute = opts.maxPerMinute || 5;
    this.maxLinesPerChunk = opts.maxLinesPerChunk || 60;
    this.mode = opts.mode || 'notable';
    this.onChange = opts.onChange || function () {};
    this.active = false;
    this.closing = false;
    this.pending = [];
    this.framer = null;
    this.posts = [];
    this.lastFlush = 0;
    this.sentLines = 0;
  }

  LivePrinter.prototype._hasSlot = function () {
    var now = this.clock();
    this.posts = this.posts.filter(function (t) { return now - t <= 60000; });
    return this.posts.length < this.maxPerMinute;
  };

  LivePrinter.prototype._post = function (bytes) {
    this.posts.push(this.clock());
    this.lastFlush = this.clock();
    this.sender(bytes);
  };

  // Seconds until the next chunk can go out (0 = now).
  LivePrinter.prototype.waitSeconds = function () {
    var now = this.clock();
    var wait = Math.max(0, this.every - (now - this.lastFlush));
    if (!this._hasSlot()) wait = Math.max(wait, this.posts[0] + 60000 - now);
    return Math.ceil(wait / 1000);
  };

  LivePrinter.prototype.start = function () {
    this.active = true;
    this.closing = false;
    this.pending = [];
    this.framer = new Framer(this.mode);
    this.sentLines = 0;
    var when = new Date().toTimeString().slice(0, 8);
    this._post(INIT + FONT_B + BOLD_ON + this.title + BOLD_OFF + '\n' + when + '\n\n');
    this.onChange(this);
  };

  LivePrinter.prototype.feed = function (state) {
    if (!this.active) return;
    var self = this;
    this.framer.feed(state).forEach(function (f) {
      self.pending.push(BOLD_ON + headingText(f) + BOLD_OFF);
      self.pending = self.pending.concat(bodyLines(f), ['']);
    });
    this.tick();
  };

  LivePrinter.prototype.tick = function () {
    if (this.closing) {
      if (this._hasSlot()) {
        var lines = this._takePending();
        this.sentLines += lines.length;
        this.closing = false;
        this._post((lines.length ? lines.join('\n') + '\n' : '') + CUT);
      }
    } else if (this.active && this.pending.length && this.clock() - this.lastFlush >= this.every && this._hasSlot()) {
      this.flush();
    }
    this.onChange(this);
  };

  // Paper is finite: a chunk keeps only its newest lines and says so.
  LivePrinter.prototype._takePending = function () {
    var lines = this.pending;
    this.pending = [];
    if (lines.length > this.maxLinesPerChunk) {
      var skipped = lines.length - this.maxLinesPerChunk;
      lines = ['... ' + skipped + ' lines skipped ...'].concat(lines.slice(skipped));
    }
    return lines;
  };

  LivePrinter.prototype.flush = function () {
    if (!this.pending.length) return false;
    var lines = this._takePending();
    this.sentLines += lines.length;
    this._post(lines.join('\n') + '\n');
    return true;
  };

  LivePrinter.prototype.stop = function () {
    if (!this.active) return;
    this.active = false;
    this.closing = true;
    this.tick();
  };

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

  return { Recorder: Recorder, LivePrinter: LivePrinter, Framer: Framer, postRaw: postRaw, splitFrames: splitFrames, stateDiffs: stateDiffs, isNotable: isNotable, render: render, postToConsole: postToConsole, shortRef: shortRef, COLS: COLS };
});
