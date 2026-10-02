// BlimpInspector - a ledger of every message the runtime logged, per actor,
// plus a small DOM panel: live ticker and a detail view for one actor.
//
//   var ledger = new BlimpInspector.Ledger({ historyCap: 60, tickerCap: 80 });
//   ledger.feed(blimp.getState());        // after every eval, same state the canvas gets
//   ledger.actor('ref<Tetris.Game:9>');   // {ref, type, state, sent, received, history}
//   ledger.ticker();                      // chronological entries, capped
//
//   var panel = new BlimpInspector.Panel(ledger, { tickerEl, detailEl, onSelect });
//   panel.feed(state); panel.select(ref);
//
// Entries: {seq, from, to, message, args, reply, self}. from is null for a
// send made by the page or REPL. Per-actor history rows add dir ('in',
// 'out' or 'self') and peer (the other actor, or null for the page).

(function (root, factory) {
  if (typeof module === 'object' && module.exports) module.exports = factory();
  else root.BlimpInspector = factory();
})(typeof self !== 'undefined' ? self : this, function () {
  'use strict';

  function Ledger(opts) {
    opts = opts || {};
    this.historyCap = opts.historyCap || 60;
    this.tickerCap = opts.tickerCap || 80;
    this.seq = 0;
    this._actors = {};   // ref -> record
    this._order = [];    // refs in first-seen order
    this._ticker = [];
  }

  Ledger.prototype.feed = function (state) {
    if (!state) return [];
    var self = this;
    var live = {};
    (state.actors || []).forEach(function (a) {
      live[a.ref] = true;
      var rec = self._actors[a.ref];
      if (!rec) {
        rec = { ref: a.ref, type: a.type, state: a.state || {}, sent: 0, received: 0, history: [] };
        self._actors[a.ref] = rec;
        self._order.push(a.ref);
      } else {
        rec.state = a.state || {};
        rec.type = a.type;
      }
    });
    // actors that stopped existing drop out of the listing but keep no ghost
    this._order = this._order.filter(function (ref) {
      if (live[ref]) return true;
      delete self._actors[ref];
      return false;
    });

    var added = [];
    (state.messages || []).forEach(function (m) {
      var to = self._actors[m.target];
      if (!to) return;
      var from = m.from ? self._actors[m.from] : null;
      var entry = {
        seq: ++self.seq,
        from: m.from || null,
        to: m.target,
        message: m.message,
        args: m.args || [],
        reply: m.reply === undefined ? null : m.reply,
        self: !!m.from && m.from === m.target
      };
      added.push(entry);
      self._ticker.push(entry);
      to.received++;
      if (from) from.sent++;
      if (entry.self) {
        self._push(to, Object.assign({ dir: 'self', peer: m.target }, entry));
      } else {
        self._push(to, Object.assign({ dir: 'in', peer: m.from || null }, entry));
        if (from) self._push(from, Object.assign({ dir: 'out', peer: m.target }, entry));
      }
    });
    if (this._ticker.length > this.tickerCap) this._ticker.splice(0, this._ticker.length - this.tickerCap);
    return added;
  };

  Ledger.prototype._push = function (rec, row) {
    rec.history.push(row);
    if (rec.history.length > this.historyCap) rec.history.splice(0, rec.history.length - this.historyCap);
  };

  Ledger.prototype.actor = function (ref) { return this._actors[ref]; };
  Ledger.prototype.actors = function () { var a = this._actors; return this._order.map(function (r) { return a[r]; }); };
  Ledger.prototype.ticker = function () { return this._ticker.slice(); };

  // -- DOM panel ----------------------------------------------------------

  function shortRef(ref) {
    if (!ref) return 'page';
    var m = /^ref<(.+):(\d+)>$/.exec(ref);
    return m ? m[1].replace(/^.*\./, '') + '#' + m[2] : ref;
  }

  function fmtCall(e) {
    return ':' + e.message + (e.args.length ? '(' + e.args.join(', ') + ')' : '');
  }

  function el(tag, cls, text) {
    var e = document.createElement(tag);
    if (cls) e.className = cls;
    if (text !== undefined) e.textContent = text;
    return e;
  }

  function Panel(ledger, opts) {
    this.ledger = ledger;
    this.opts = opts || {};
    this.tickerEl = this.opts.tickerEl;
    this.detailEl = this.opts.detailEl;
    this.selected = null;
    this.tickerRows = this.opts.tickerRows || 40;
    this.historyRows = this.opts.historyRows || 30;
    var self = this;
    this._onClick = function (ev) {
      var t = ev.target.closest('[data-ref]');
      if (t) self.select(t.getAttribute('data-ref'));
    };
    if (this.tickerEl) this.tickerEl.addEventListener('click', this._onClick);
    if (this.detailEl) this.detailEl.addEventListener('click', this._onClick);
  }

  Panel.prototype.feed = function (state) {
    var added = this.ledger.feed(state);
    if (this.selected && !this.ledger.actor(this.selected)) this.selected = null;
    this.render();
    return added;
  };

  Panel.prototype.select = function (ref) {
    this.selected = ref;
    if (this.opts.onSelect) this.opts.onSelect(ref);
    this.render();
  };

  Panel.prototype.render = function () {
    if (this.tickerEl) this._renderTicker();
    if (this.detailEl) this._renderDetail();
  };

  Panel.prototype._refLink = function (ref) {
    var a = el('span', 'bi-ref' + (ref === this.selected ? ' bi-selected' : ''), shortRef(ref));
    if (ref) a.setAttribute('data-ref', ref);
    return a;
  };

  Panel.prototype._renderTicker = function () {
    var rows = this.ledger.ticker().slice(-this.tickerRows).reverse();
    var list = el('ol', 'bi-ticker');
    var self = this;
    rows.forEach(function (e) {
      var li = el('li', 'bi-row' + (e.self ? ' bi-self' : '') + ((self.selected && (e.to === self.selected || e.from === self.selected)) ? ' bi-hit' : ''));
      li.appendChild(el('span', 'bi-seq', '#' + e.seq));
      li.appendChild(self._refLink(e.from));
      li.appendChild(el('span', 'bi-arrow', e.self ? ' ↺ ' : ' → '));
      li.appendChild(self._refLink(e.to));
      li.appendChild(el('span', 'bi-msg', ' ' + fmtCall(e)));
      if (e.reply !== null) li.appendChild(el('span', 'bi-reply', ' ⇒ ' + e.reply));
      list.appendChild(li);
    });
    this.tickerEl.innerHTML = '';
    this.tickerEl.appendChild(list);
  };

  Panel.prototype._renderDetail = function () {
    var root = el('div', 'bi-detail');
    var self = this;
    var chips = el('div', 'bi-actors');
    this.ledger.actors().forEach(function (a) {
      var c = el('button', 'bi-chip' + (a.ref === self.selected ? ' bi-selected' : ''), shortRef(a.ref));
      c.setAttribute('data-ref', a.ref);
      c.type = 'button';
      chips.appendChild(c);
    });
    root.appendChild(chips);

    var rec = this.selected ? this.ledger.actor(this.selected) : null;
    if (!rec) {
      root.appendChild(el('p', 'bi-hint', 'click an actor above or on the canvas'));
    } else {
      var head = el('div', 'bi-head');
      head.appendChild(el('span', 'bi-type', rec.type));
      head.appendChild(el('span', 'bi-id', ' ' + rec.ref));
      root.appendChild(head);
      var counts = el('div', 'bi-counts', 'received ' + rec.received + '  ·  sent ' + rec.sent);
      root.appendChild(counts);

      var st = el('table', 'bi-state');
      var keys = Object.keys(rec.state);
      if (!keys.length) {
        var tr0 = el('tr'); tr0.appendChild(el('td', 'bi-hint', 'no state')); st.appendChild(tr0);
      }
      keys.forEach(function (k) {
        var tr = el('tr');
        tr.appendChild(el('th', null, k));
        tr.appendChild(el('td', null, String(rec.state[k])));
        st.appendChild(tr);
      });
      root.appendChild(st);

      var hist = el('ol', 'bi-history');
      rec.history.slice(-this.historyRows).reverse().forEach(function (h) {
        var li = el('li', 'bi-row bi-' + h.dir);
        li.appendChild(el('span', 'bi-seq', '#' + h.seq));
        li.appendChild(el('span', 'bi-dir', h.dir === 'in' ? ' ← ' : h.dir === 'out' ? ' → ' : ' ↺ '));
        li.appendChild(self._refLink(h.peer));
        li.appendChild(el('span', 'bi-msg', ' ' + fmtCall(h)));
        if (h.reply !== null) li.appendChild(el('span', 'bi-reply', ' ⇒ ' + h.reply));
        hist.appendChild(li);
      });
      root.appendChild(hist);
    }
    this.detailEl.innerHTML = '';
    this.detailEl.appendChild(root);
  };

  return { Ledger: Ledger, Panel: Panel, shortRef: shortRef, fmtCall: fmtCall };
});
