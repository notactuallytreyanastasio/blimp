// BlimpView - generic host for a Blimp actor's view in the browser.
//
// Usage:
//   var view = new BlimpView(blimp, containerEl, { onError, onRender, onSend });
//   view.mount(source, 'game');   // source must end with `game <- :view`
//   view.send('tick');            // game <- :tick, then game <- :view, re-render
//   view.unmount();
//
// The view tree is the JSON that blimp.eval returns in `view`.
// Rendering is a port of the dom_playground renderView (same tags, same
// .blimp-* class names) plus two effect nodes that render nothing:
//   timer(ms, :msg)   -> {"tag":"timer","attrs":{"ms":{"text":"500"},"sends":"msg"}}
//   key("ArrowLeft", :msg) -> {"tag":"key","attrs":{"code":{"text":"ArrowLeft"},"sends":"msg"}}
// After every render the effects are reconciled: intervals keyed by
// `ms|sends` are started or cleared to match the tree, and one document
// keydown listener maps KeyboardEvent.key to a message from the latest tree.
//
// Attr values arrive either as primitives or as {text: "..."} (strings and
// ints both serialize that way), so every attr goes through attrVal().

(function (root) {
  'use strict';

  function attrVal(v) {
    if (v && typeof v === 'object' && v.text !== undefined) return v.text;
    return v;
  }

  function attrInt(v, fallback) {
    var n = parseInt(attrVal(v), 10);
    return isNaN(n) ? fallback : n;
  }

  function mk(tag, cls) {
    var e = document.createElement(tag);
    e.className = cls;
    return e;
  }

  function BlimpView(blimp, container, opts) {
    this.blimp = blimp;
    this.container = container;
    this.opts = opts || {};
    this.actorVar = null;
    this.view = null;
    this.error = null;
    this.mounted = false;
    this.timers = {};   // "ms|sends" -> interval id
    this.keys = {};     // KeyboardEvent.key -> message
    this._sending = false;
    var self = this;
    this._onKeydown = function (e) { self._handleKey(e); };
  }

  // -- public -------------------------------------------------------------

  BlimpView.prototype.mount = function (source, actorVar) {
    if (this.mounted) this.unmount();
    this.actorVar = actorVar;
    this.error = null;
    this.mounted = true;
    document.addEventListener('keydown', this._onKeydown);
    var r = this.blimp.eval(source);
    if (!r.ok) return this._fail(r.error);
    if (!r.view) return this._fail('mount: the last expression of the source did not produce a view (expected `' + actorVar + ' <- :view`)');
    this.render(r.view);
    return r;
  };

  BlimpView.prototype.send = function (msg) {
    if (!this.mounted || this.error) return false;
    if (this._sending) return false;
    this._sending = true;
    try {
      if (this.opts.onSend) this.opts.onSend(msg);
      var r1 = this.blimp.eval(this.actorVar + ' <- :' + msg);
      if (!r1.ok) { this._fail(r1.error); return false; }
      var r2 = this.blimp.eval(this.actorVar + ' <- :view');
      if (!r2.ok) { this._fail(r2.error); return false; }
      if (!r2.view) { this._fail(this.actorVar + ' <- :view did not return a view'); return false; }
      this.render(r2.view);
      return true;
    } finally {
      this._sending = false;
    }
  };

  // Number of intervals currently running (pages and tests can poll this).
  BlimpView.prototype.timerCount = function () {
    return Object.keys(this.timers).length;
  };

  BlimpView.prototype.unmount = function () {
    this._stopTimers();
    document.removeEventListener('keydown', this._onKeydown);
    this.keys = {};
    this.mounted = false;
    this.view = null;
    if (this.container) this.container.innerHTML = '';
  };

  // Render a view tree and reconcile its effects.
  // send() calls this; tests can call it directly with hand-written JSON.
  BlimpView.prototype.render = function (view) {
    this.view = view;
    var el = this.renderView(view);
    this.container.innerHTML = '';
    this.container.appendChild(el);
    var fx = { timers: {}, keys: {} };
    this._collectEffects(view, fx);
    this._reconcileTimers(fx.timers);
    this.keys = fx.keys;
    if (this.opts.onRender) this.opts.onRender(view, fx);
  };

  BlimpView.prototype.renderView = function (node) {
    var self = this;
    if (!node) return document.createTextNode('');
    if (node.text !== undefined) return document.createTextNode(node.text);
    var tag = node.tag, attrs = node.attrs || {}, children = node.children || [], el;
    switch (tag) {
      case 'stack': el = mk('div', 'blimp-stack'); break;
      case 'row': el = mk('div', 'blimp-row'); break;
      case 'grid': el = mk('div', 'blimp-grid'); break;
      case 'text': el = mk('span', 'blimp-text'); break;
      case 'heading':
        var lv = Math.max(1, Math.min(6, attrInt(attrs.level, 1)));
        el = document.createElement('h' + lv); break;
      case 'bold': el = mk('strong', 'blimp-bold'); break;
      case 'italic': el = mk('em', 'blimp-italic'); break;
      case 'code': el = mk('code', 'blimp-code'); break;
      case 'code_block': el = mk('pre', 'blimp-code-block'); break;
      case 'blockquote': el = mk('blockquote', 'blimp-blockquote'); break;
      case 'divider': return mk('hr', 'blimp-divider');
      case 'list':
        el = mk('ul', 'blimp-list');
        children.forEach(function (c) { var li = document.createElement('li'); li.appendChild(self.renderView(c)); el.appendChild(li); });
        return el;
      case 'link':
        el = mk('a', 'blimp-link');
        if (attrs.href !== undefined) el.href = attrVal(attrs.href);
        el.target = '_blank';
        break;
      case 'image':
        el = mk('img', 'blimp-image');
        if (attrs.src !== undefined) el.src = attrVal(attrs.src);
        if (attrs.alt !== undefined) el.alt = attrVal(attrs.alt);
        return el;
      case 'video':
        el = mk('video', 'blimp-video');
        if (attrs.src !== undefined) el.src = attrVal(attrs.src);
        el.controls = true;
        return el;
      case 'canvas':
        el = mk('canvas', 'blimp-canvas-el');
        if (attrs.id !== undefined) el.id = attrVal(attrs.id);
        return el;
      case 'button':
        el = mk('button', 'blimp-button');
        el.type = 'button';
        if (attrs.sends !== undefined) {
          (function (msg) { el.addEventListener('click', function () { self.send(msg); }); })(attrVal(attrs.sends));
        }
        break;
      case 'timer':
      case 'key':
        // effects render nothing; they are picked up by _collectEffects
        return document.createTextNode('');
      default: el = document.createElement('div');
    }
    children.forEach(function (c) { el.appendChild(self.renderView(c)); });
    return el;
  };

  // -- effects --------------------------------------------------------------

  BlimpView.prototype._collectEffects = function (node, fx) {
    if (!node || typeof node !== 'object' || node.text !== undefined) return;
    var attrs = node.attrs || {};
    if (node.tag === 'timer') {
      var ms = attrInt(attrs.ms, 0);
      var sends = attrVal(attrs.sends);
      if (ms > 0 && sends) fx.timers[ms + '|' + sends] = { ms: ms, sends: sends };
    } else if (node.tag === 'key') {
      var code = attrVal(attrs.code);
      var msg = attrVal(attrs.sends);
      if (code !== undefined && code !== null && msg) fx.keys[String(code)] = msg;
    }
    var children = node.children || [];
    for (var i = 0; i < children.length; i++) this._collectEffects(children[i], fx);
  };

  BlimpView.prototype._reconcileTimers = function (wanted) {
    var self = this;
    Object.keys(this.timers).forEach(function (k) {
      if (!wanted[k]) { clearInterval(self.timers[k]); delete self.timers[k]; }
    });
    Object.keys(wanted).forEach(function (k) {
      if (self.timers[k]) return;
      var t = wanted[k];
      self.timers[k] = setInterval(function () {
        if (!self.mounted || self.error || self._sending) return;
        if (!self.timers[k]) return;
        self.send(t.sends);
      }, t.ms);
    });
  };

  BlimpView.prototype._stopTimers = function () {
    var self = this;
    Object.keys(this.timers).forEach(function (k) { clearInterval(self.timers[k]); });
    this.timers = {};
  };

  BlimpView.prototype._handleKey = function (e) {
    if (!this.mounted || this.error) return;
    if (e.ctrlKey || e.metaKey || e.altKey || e.shiftKey) return;
    var t = e.target;
    if (t && (t.tagName === 'INPUT' || t.tagName === 'TEXTAREA' || t.isContentEditable)) return;
    var msg = this.keys[e.key];
    if (!msg) return;
    e.preventDefault();
    this.send(msg);
  };

  BlimpView.prototype._fail = function (text) {
    this.error = String(text);
    this._stopTimers();
    this.keys = {};
    var pre = mk('pre', 'blimp-error');
    pre.textContent = this.error;
    if (this.container) { this.container.innerHTML = ''; this.container.appendChild(pre); }
    if (this.opts.onError) this.opts.onError(this.error);
    return { ok: false, error: this.error };
  };

  BlimpView.attrVal = attrVal;

  if (typeof module !== 'undefined' && module.exports) module.exports = BlimpView;
  if (root) root.BlimpView = BlimpView;
})(typeof window !== 'undefined' ? window : null);
