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
//   key("*", :msg)              -> every key: :msg("a"), :msg("Enter"), ...
//   key("ArrowUp", :down, :up) -> the same with "up":"up": a held key, sent
//                                 once when it goes down and once when it
//                                 comes up; auto-repeat is not sent
// After every render the effects are reconciled: intervals keyed by
// `ms|sends` are started or cleared to match the tree, and document keydown
// and keyup listeners map KeyboardEvent.key to messages from the latest tree.
//
// A render patches the page it rendered last rather than rebuilding it: an
// element whose node did not change is the same element afterwards. A game
// renders thirty times a second, and a button that was replaced between
// mousedown and mouseup never got its click.
//
// draw(w, h, ops) is a canvas painted from a display list, one shape per
// line (see viewDraw in builtins.zig); the canvas is kept and repainted.
//
// el(tag, attrs, children...) is a real element with the page's own classes
// and attributes: {"tag":"el","attrs":{"@tag":{"text":"div"},"class":...}}.
// Six attrs are instructions, not HTML (see viewEl): click (+ with),
// input, change, submit and swipe each send the actor a message. An el
// whose id changes is a new element: a CSS animation keyed to it starts
// again, as it did when LiveView replaced the node.
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

  var SVGNS = 'http://www.w3.org/2000/svg';
  var SVG_TAGS = { svg: 1, g: 1, path: 1, circle: 1, rect: 1, line: 1, polyline: 1, polygon: 1, text: 1, tspan: 1,
    defs: 1, linearGradient: 1, radialGradient: 1, stop: 1, ellipse: 1, title: 0 };
  var EL_EVENTS = { click: 1, 'with': 1, input: 1, change: 1, submit: 1, swipe: 1, select: 1, selection: 1,
    debounce: 1, shortcut: 1, shortcut_keys: 1, paste_image: 1, inner_html: 1 };

  // Blimp strings count bytes (UTF-8); a field's selection counts UTF-16
  // units. These turn one into the other.
  function utf8Len(s) {
    var n = 0;
    for (var i = 0; i < s.length; i++) {
      var c = s.charCodeAt(i);
      if (c < 0x80) n += 1;
      else if (c < 0x800) n += 2;
      else if (c >= 0xd800 && c <= 0xdbff) { n += 4; i++; }
      else n += 3;
    }
    return n;
  }
  function toBytes(s, i) { return utf8Len(s.slice(0, i)); }
  function fromBytes(s, b) {
    var n = 0;
    for (var i = 0; i < s.length; i++) {
      if (n >= b) return i;
      var c = s.charCodeAt(i);
      if (c < 0x80) n += 1;
      else if (c < 0x800) n += 2;
      else if (c >= 0xd800 && c <= 0xdbff) { n += 4; i++; }
      else n += 3;
    }
    return s.length;
  }

  // What the host does with the attrs that are not HTML, after the
  // element's attributes are set (render and patch alike).
  function applyInstructions(el, attrs, old) {
    if (attrs.inner_html !== undefined && (!old || JSON.stringify(old.inner_html) !== JSON.stringify(attrs.inner_html))) {
      el.innerHTML = String(attrVal(attrs.inner_html));
    }
    if (attrs.selection !== undefined && (!old || JSON.stringify(old.selection) !== JSON.stringify(attrs.selection))) {
      var parts = String(attrVal(attrs.selection)).split(',');
      var v = el.value || '';
      if (el.setSelectionRange) {
        el.focus && el.focus();
        el.setSelectionRange(fromBytes(v, +parts[0] || 0), fromBytes(v, +parts[1] || 0));
      }
    }
  }
  var URL_ATTRS = { href: 1, src: 1, action: 1, formaction: 1, 'xlink:href': 1, poster: 1 };

  // A Blimp string literal holding `s`.
  function literal(s) {
    return '"' + String(s).replace(/\\/g, '\\\\').replace(/"/g, '\\"').replace(/\n/g, '\\n').replace(/#\{/g, '\\#{') + '"';
  }

  // Set el's attributes to `attrs`, touching only what differs from `old`.
  function setAttrs(el, attrs, old) {
    Object.keys(attrs).forEach(function (k) {
      if (k.charAt(0) === '@' || EL_EVENTS[k]) return;
      if (old && JSON.stringify(old[k]) === JSON.stringify(attrs[k])) return;
      if (/^on/i.test(k)) throw new Error('el: an on* attribute (' + k + ') is not allowed');
      var v = attrVal(attrs[k]);
      if (v === false || v === null || v === undefined) { el.removeAttribute(k); if (k === 'checked') el.checked = false; return; }
      if (v === true) { el.setAttribute(k, ''); if (k === 'checked') el.checked = true; return; }
      v = String(v);
      if (URL_ATTRS[k] && /^[\u0000-\u0020]*javascript:/i.test(v)) throw new Error('el: a javascript: URL in ' + k);
      el.setAttribute(k, v);
      // the property, not the attribute, is what a field shows once typed in
      if (k === 'value' && 'value' in el) el.value = v;
    });
    if (old) Object.keys(old).forEach(function (k) {
      if (k.charAt(0) === '@' || EL_EVENTS[k] || attrs.hasOwnProperty(k)) return;
      el.removeAttribute(k);
    });
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
    this.keys = {};     // KeyboardEvent.key -> {down, up}
    this._held = {};    // KeyboardEvent.key -> true while a held key is down
    this._root = null;  // the element render() put in the container
    this._sending = false;
    var self = this;
    this._onKeydown = function (e) { self._handleKey(e); };
    this._onKeyup = function (e) { self._handleKeyUp(e); };
    this._onBlur = function () { self._releaseAll(); };
  }

  // -- public -------------------------------------------------------------

  BlimpView.prototype.mount = function (source, actorVar) {
    if (this.mounted) this.unmount();
    this.actorVar = actorVar;
    this.error = null;
    this.mounted = true;
    document.addEventListener('keydown', this._onKeydown);
    document.addEventListener('keyup', this._onKeyup);
    if (typeof window !== 'undefined' && window.addEventListener) window.addEventListener('blur', this._onBlur);
    var r = this.blimp.eval(source);
    if (!r.ok) return this._fail(r.error);
    if (!r.view) return this._fail('mount: the last expression of the source did not produce a view (expected `' + actorVar + ' <- :view`)');
    this.render(r.view);
    return r;
  };

  // send('set_size', '8') is `actor <- :set_size(8)`: args are Blimp source.
  BlimpView.prototype.send = function (msg, args) {
    if (!this.mounted || this.error) return false;
    if (this._sending) return false;
    this._sending = true;
    try {
      if (this.opts.onSend) this.opts.onSend(msg, args);
      if (this.opts.send) return this._sendDirect(msg, args);
      var r1 = this.blimp.eval(this.actorVar + ' <- :' + msg + (args !== undefined ? '(' + args + ')' : ''));
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

  // { send: true }: the message and the view both go through blimp.send, so
  // a game that runs for an hour does not keep an hour of evals. Opt-in,
  // because a page that shows the message log (getState) needs eval's.
  BlimpView.prototype._sendDirect = function (msg, args) {
    var r1 = this.blimp.send(this.actorVar, msg, args);
    if (!r1.ok) { this._fail(r1.error); return false; }
    var r2 = this.blimp.send(this.actorVar, 'view');
    if (!r2.ok) { this._fail(r2.error); return false; }
    if (!r2.value || !r2.value.tag) { this._fail(this.actorVar + ' <- :view did not return a view'); return false; }
    this.render(r2.value);
    return true;
  };

  // Number of intervals currently running (pages and tests can poll this).
  BlimpView.prototype.timerCount = function () {
    return Object.keys(this.timers).length;
  };

  BlimpView.prototype.unmount = function () {
    this._stopTimers();
    document.removeEventListener('keydown', this._onKeydown);
    document.removeEventListener('keyup', this._onKeyup);
    if (typeof window !== 'undefined' && window.removeEventListener) window.removeEventListener('blur', this._onBlur);
    this.keys = {};
    this._held = {};
    this.mounted = false;
    this.view = null;
    this._root = null;
    if (this.container) this.container.innerHTML = '';
  };

  // Render a view tree and reconcile its effects.
  // send() calls this; tests can call it directly with hand-written JSON.
  BlimpView.prototype.render = function (view) {
    var old = this.view;
    try {
      if (this._root && old) {
        var next = this._patch(this._root, old, view);
        if (next !== this._root) this.container.replaceChild(next, this._root);
        this._root = next;
      } else {
        this._root = this.renderView(view);
        this.container.innerHTML = '';
        this.container.appendChild(this._root);
      }
    } catch (e) {
      this._root = null;
      return this._fail(e.message || String(e));
    }
    this.view = view;
    var fx = { timers: {}, keys: {}, fetches: {}, query: null };
    this._collectEffects(view, fx);
    this._reconcileTimers(fx.timers);
    this._reconcileFetches(fx.fetches);
    if (fx.query !== null && typeof location !== 'undefined' && typeof history !== 'undefined') {
      var want = fx.query === '' ? location.pathname : '?' + fx.query;
      if (location.search !== (fx.query === '' ? '' : '?' + fx.query)) history.replaceState(null, '', want);
    }
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
      case 'draw':
        el = mk('canvas', 'blimp-draw');
        paint(el, attrs);
        return el;
      case 'el':
        var etag = attrVal(attrs['@tag']);
        // inside an <svg> everything is SVG, as an HTML parser has it: a
        // <title> there is a tooltip, not the document's title
        var svg = SVG_TAGS[etag] || this._inSvg;
        el = svg ? document.createElementNS(SVGNS, etag) : document.createElement(etag);
        setAttrs(el, attrs, null);
        this._listen(el, attrs);
        var outer = this._inSvg;
        this._inSvg = !!svg;
        try {
          if (attrs.inner_html === undefined) children.forEach(function (c) { el.appendChild(self.renderView(c)); });
        } finally {
          this._inSvg = outer;
        }
        applyInstructions(el, attrs, null);
        if (etag === 'select' && attrs.value !== undefined) el.value = String(attrVal(attrs.value));
        return el;
      case 'button':
        el = mk('button', 'blimp-button');
        el.type = 'button';
        // read at click time, so a patch can change what it sends
        el._blimpSends = attrs.sends !== undefined ? attrVal(attrs.sends) : undefined;
        el.addEventListener('click', function () { if (el._blimpSends !== undefined) self.send(el._blimpSends); });
        break;
      case 'timer':
      case 'key':
      case 'fetch':
      case 'location_query':
        // effects render nothing; they are picked up by _collectEffects
        return document.createTextNode('');
      default: el = document.createElement('div');
    }
    children.forEach(function (c) { el.appendChild(self.renderView(c)); });
    return el;
  };

  // -- el events --------------------------------------------------------------

  // The listeners read el._blimpOn when they fire, so a patch that changes
  // what an element sends needs no new listener.
  BlimpView.prototype._listen = function (el, attrs) {
    var self = this;
    el._blimpOn = {};
    Object.keys(EL_EVENTS).forEach(function (k) { if (attrs[k] !== undefined) el._blimpOn[k] = attrVal(attrs[k]); });
    if (el._blimpOn.click) el.addEventListener('click', function (e) {
      var on = el._blimpOn;
      if (!on.click) return;
      e.preventDefault();
      // the innermost element with a click is the one clicked, as with
      // LiveView's phx-click: a Close button inside a clickable backdrop
      // closes it once, not twice
      if (e.stopPropagation) e.stopPropagation();
      self.send(on.click, on['with']);
    });
    if (el._blimpOn.input) el.addEventListener('input', function () {
      if (!el._blimpOn.input) return;
      var ms = +el._blimpOn.debounce || 0;
      if (!ms) return self.send(el._blimpOn.input, literal(el.value));
      clearTimeout(el._blimpDebounce);
      el._blimpDebounce = setTimeout(function () {
        if (el._blimpOn.input) self.send(el._blimpOn.input, literal(el.value));
      }, ms);
    });
    if (el._blimpOn.select) {
      var lastSel = null;
      var report = function () {
        if (!el._blimpOn.select || el.selectionStart === undefined) return;
        var v = el.value || '';
        var sel = toBytes(v, el.selectionStart) + ', ' + toBytes(v, el.selectionEnd);
        if (sel === lastSel) return;
        lastSel = sel;
        self.send(el._blimpOn.select, sel);
      };
      ['select', 'keyup', 'mouseup', 'input', 'focus'].forEach(function (t) { el.addEventListener(t, report); });
    }
    if (el._blimpOn.shortcut) el.addEventListener('keydown', function (e) {
      if (!(e.ctrlKey || e.metaKey) || e.altKey || !el._blimpOn.shortcut) return;
      var k = String(e.key || '').toLowerCase();
      if (k.length !== 1 || String(el._blimpOn.shortcut_keys || '').indexOf(k) < 0) return;
      e.preventDefault();
      self.send(el._blimpOn.shortcut, literal(k));
    });
    if (el._blimpOn.paste_image) {
      var take = function (file) {
        var r = new FileReader();
        r.onload = function () { if (el._blimpOn.paste_image) self.send(el._blimpOn.paste_image, literal(r.result)); };
        r.readAsDataURL(file);
      };
      var firstImage = function (list) {
        for (var i = 0; list && i < list.length; i++) {
          var f = list[i].getAsFile ? (list[i].type.indexOf('image') === 0 ? list[i].getAsFile() : null) : list[i];
          if (f && String(f.type).indexOf('image') === 0) return f;
        }
        return null;
      };
      el.addEventListener('paste', function (e) {
        var f = firstImage(e.clipboardData && e.clipboardData.items);
        if (f) { e.preventDefault(); take(f); }
      });
      el.addEventListener('dragover', function (e) { e.preventDefault(); });
      el.addEventListener('drop', function (e) {
        var f = firstImage(e.dataTransfer && e.dataTransfer.files);
        if (f) { e.preventDefault(); take(f); }
      });
    }
    if (el._blimpOn.change) el.addEventListener('change', function () {
      if (!el._blimpOn.change) return;
      self.send(el._blimpOn.change, el.type === 'checkbox' ? String(el.checked) : literal(el.value));
    });
    if (el._blimpOn.swipe) {
      var sx = 0, sy = 0, done = false;
      el.addEventListener('touchstart', function (e) {
        sx = e.touches[0].clientX; sy = e.touches[0].clientY; done = false;
      }, { passive: true });
      el.addEventListener('touchmove', function (e) {
        if (done || !el._blimpOn.swipe) return;
        var dx = e.touches[0].clientX - sx, dy = e.touches[0].clientY - sy;
        if (Math.max(Math.abs(dx), Math.abs(dy)) < 12) return;
        e.preventDefault();
        done = true;
        var dir = Math.abs(dx) > Math.abs(dy) ? (dx > 0 ? 'right' : 'left') : (dy > 0 ? 'down' : 'up');
        self.send(el._blimpOn.swipe, ':' + dir);
      }, { passive: false });
    }
    if (el._blimpOn.submit) el.addEventListener('submit', function (e) {
      e.preventDefault();
      var fields = {};
      Array.prototype.forEach.call(el.elements || [], function (f) {
        if (!f.name) return;
        fields[f.name] = f.type === 'checkbox' ? f.checked : f.value;
      });
      if (el._blimpOn.submit) self.send(el._blimpOn.submit, literal(JSON.stringify(fields)));
    });
  };

  // -- patching ---------------------------------------------------------------

  // A new element for `b` in the place of `el`, in el's namespace.
  BlimpView.prototype._rebuild = function (el, b) {
    var outer = this._inSvg;
    this._inSvg = el.namespaceURI === SVGNS;
    try { return this.renderView(b); } finally { this._inSvg = outer; }
  };

  // Make `el`, which shows node `a`, show node `b`; answer the element that
  // does (el itself, unless it had to be replaced).
  BlimpView.prototype._patch = function (el, a, b) {
    if (a === b) return el;
    var aText = !!a && a.text !== undefined, bText = !!b && b.text !== undefined;
    if (aText && bText) {
      if (a.text !== b.text) el.nodeValue = b.text;
      return el;
    }
    if (!a || !b || aText || bText || a.tag !== b.tag) return this.renderView(b);
    var ac = a.children || [], bc = b.children || [];
    var sameAttrs = JSON.stringify(a.attrs || {}) === JSON.stringify(b.attrs || {});
    if (b.tag === 'draw') {
      if (!sameAttrs) paint(el, b.attrs || {});
      return el;
    }
    if (b.tag === 'el') {
      if (attrVal(a.attrs['@tag']) !== attrVal(b.attrs['@tag'])) return this.renderView(b);
      if (JSON.stringify(a.attrs.id) !== JSON.stringify(b.attrs.id)) return this.renderView(b);
      if (!sameAttrs) {
        setAttrs(el, b.attrs, a.attrs);
        var had = el._blimpOn || {};
        var want = {};
        Object.keys(EL_EVENTS).forEach(function (k) { if (b.attrs[k] !== undefined) want[k] = attrVal(b.attrs[k]); });
        // a kind of event it had no listener for needs a new element
        var passive = { 'with': 1, selection: 1, debounce: 1, shortcut_keys: 1, inner_html: 1 };
        if (Object.keys(want).some(function (k) { return !passive[k] && !had[k]; })) return this.renderView(b);
        el._blimpOn = want;
        applyInstructions(el, b.attrs, a.attrs);
      }
      if (b.attrs.inner_html !== undefined) return el;
      if (ac.length !== bc.length) return this._rebuild(el, b);
      var nodes = el.childNodes;
      var outerNs = this._inSvg;
      this._inSvg = el.namespaceURI === SVGNS;
      try {
        for (var j = 0; j < bc.length; j++) {
          var c = nodes[j];
          var n = this._patch(c, ac[j], bc[j]);
          if (n !== c) el.replaceChild(n, c);
        }
      } finally {
        this._inSvg = outerNs;
      }
      return el;
    }
    if (!sameAttrs) {
      if (b.tag === 'button') el._blimpSends = b.attrs && b.attrs.sends !== undefined ? attrVal(b.attrs.sends) : undefined;
      else if (b.tag === 'link') el.href = attrVal((b.attrs || {}).href);
      else if (b.tag !== 'timer' && b.tag !== 'key' && b.tag !== 'heading') return this.renderView(b);
      else if (b.tag === 'heading' && attrVal((a.attrs || {}).level) !== attrVal((b.attrs || {}).level)) return this.renderView(b);
    }
    // a list wraps each child in an <li>, and an effect node is a text node
    if (b.tag === 'list' || b.tag === 'timer' || b.tag === 'key') {
      return b.tag === 'list' && JSON.stringify(ac) !== JSON.stringify(bc) ? this.renderView(b) : el;
    }
    if (ac.length !== bc.length) return this.renderView(b);
    var kids = el.childNodes;
    for (var i = 0; i < bc.length; i++) {
      var child = kids[i];
      var next = this._patch(child, ac[i], bc[i]);
      if (next !== child) el.replaceChild(next, child);
    }
    return el;
  };

  // -- draw -------------------------------------------------------------------

  function num(parts, i, line, n) {
    var v = parseFloat(parts[i]);
    if (isNaN(v)) throw new Error('draw: line ' + n + ' needs a number at field ' + i + ': ' + line);
    return v;
  }

  // A fill: a CSS color, or v:/h: and colors for a gradient over the box.
  function fillFor(ctx, fill, x, y, w, h) {
    if (fill === undefined) throw new Error('draw: a shape without a color');
    var kind = fill.slice(0, 2);
    if (kind !== 'v:' && kind !== 'h:') return fill;
    var colors = fill.slice(2).split(',');
    var g = kind === 'v:' ? ctx.createLinearGradient(x, y, x, y + h) : ctx.createLinearGradient(x, y, x + w, y);
    for (var i = 0; i < colors.length; i++) g.addColorStop(colors.length === 1 ? 0 : i / (colors.length - 1), colors[i]);
    return g;
  }

  function paint(canvas, attrs) {
    var w = attrInt(attrs.width, 0), h = attrInt(attrs.height, 0);
    if (canvas.width !== w) canvas.width = w;
    if (canvas.height !== h) canvas.height = h;
    var ctx = canvas.getContext('2d');
    ctx.setTransform(1, 0, 0, 1, 0, 0);
    ctx.globalAlpha = 1;
    ctx.shadowBlur = 0;
    ctx.clearRect(0, 0, w, h);
    var lines = String(attrVal(attrs.ops) || '').split('\n');
    for (var n = 0; n < lines.length; n++) {
      var line = lines[n];
      if (line === '') continue;
      var p = line.split(' ');
      switch (p[0]) {
        case 'rect':
          var rx = num(p, 1, line, n + 1), ry = num(p, 2, line, n + 1), rw = num(p, 3, line, n + 1), rh = num(p, 4, line, n + 1);
          ctx.fillStyle = fillFor(ctx, p[5], rx, ry, rw, rh);
          ctx.fillRect(rx, ry, rw, rh);
          break;
        case 'circle':
          var cx = num(p, 1, line, n + 1), cy = num(p, 2, line, n + 1), cr = num(p, 3, line, n + 1);
          ctx.fillStyle = fillFor(ctx, p[4], cx - cr, cy - cr, 2 * cr, 2 * cr);
          ctx.beginPath();
          ctx.arc(cx, cy, Math.max(0, cr), 0, 2 * Math.PI);
          ctx.fill();
          break;
        case 'line':
          var x1 = num(p, 1, line, n + 1), y1 = num(p, 2, line, n + 1), x2 = num(p, 3, line, n + 1), y2 = num(p, 4, line, n + 1);
          ctx.strokeStyle = fillFor(ctx, p[5], Math.min(x1, x2), Math.min(y1, y2), Math.abs(x2 - x1), Math.abs(y2 - y1));
          ctx.lineWidth = num(p, 6, line, n + 1);
          ctx.beginPath();
          ctx.moveTo(x1, y1);
          ctx.lineTo(x2, y2);
          ctx.stroke();
          break;
        case 'text':
          var tx = num(p, 1, line, n + 1), ty = num(p, 2, line, n + 1), size = num(p, 3, line, n + 1);
          var words = p.slice(6).join(' ');
          ctx.font = 'bold ' + size + 'px sans-serif';
          ctx.textAlign = p[5] || 'left';
          ctx.textBaseline = 'middle';
          ctx.fillStyle = fillFor(ctx, p[4], tx - size * words.length / 4, ty - size / 2, size * words.length / 2, size);
          ctx.fillText(words, tx, ty);
          break;
        case 'alpha':
          ctx.globalAlpha = Math.max(0, Math.min(1, num(p, 1, line, n + 1)));
          break;
        case 'shadow':
          ctx.shadowBlur = num(p, 1, line, n + 1);
          ctx.shadowColor = p[2] || 'transparent';
          break;
        default:
          throw new Error('draw: line ' + (n + 1) + ' is not a shape draw knows (rect, circle, line, text, alpha, shadow): ' + line);
      }
    }
  }

  // -- effects --------------------------------------------------------------

  BlimpView.prototype._collectEffects = function (node, fx) {
    if (!node || typeof node !== 'object' || node.text !== undefined) return;
    var attrs = node.attrs || {};
    if (node.tag === 'timer') {
      var ms = attrInt(attrs.ms, 0);
      var sends = attrVal(attrs.sends);
      if (ms > 0 && sends) fx.timers[ms + '|' + sends] = { ms: ms, sends: sends };
    } else if (node.tag === 'fetch') {
      var url = attrVal(attrs.url), fsends = attrVal(attrs.sends);
      if (url && fsends) fx.fetches[url + '|' + fsends] = { url: url, sends: fsends };
    } else if (node.tag === 'location_query') {
      fx.query = String(attrVal(attrs.query));
    } else if (node.tag === 'key') {
      var code = attrVal(attrs.code);
      var msg = attrVal(attrs.sends);
      if (code !== undefined && code !== null && msg) fx.keys[String(code)] = { down: msg, up: attrVal(attrs.up) };
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

  // Each fetch in the tree is made once while it stays there; one that
  // leaves the tree is forgotten, so asking again fetches again.
  BlimpView.prototype._reconcileFetches = function (wanted) {
    var self = this;
    this.fetched = this.fetched || {};
    Object.keys(this.fetched).forEach(function (k) { if (!wanted[k]) delete self.fetched[k]; });
    Object.keys(wanted).forEach(function (k) {
      if (self.fetched[k]) return;
      self.fetched[k] = true;
      var f = wanted[k];
      var deliver = function (status, body) {
        if (!self.mounted || self.error || !self.fetched[k]) return;
        // a send in progress (a timer, a click) finishes first
        var go = function () {
          if (self._sending) return setTimeout(go, 0);
          self.send(f.sends, status + ', ' + literal(body));
        };
        go();
      };
      fetch(f.url, { credentials: 'same-origin' })
        .then(function (r) { return r.text().then(function (t) { deliver(r.status, t); }); })
        .catch(function () { deliver(0, ''); });
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
    var spec = this.keys[e.key];
    if (!spec && this.keys['*']) {
      // key("*", :msg): every key, as :msg("a"), :msg("Enter"), ... and
      // not prevented, so the page scrolls and shortcuts work as before
      this.send(this.keys['*'].down, literal(e.key));
      return;
    }
    if (!spec) return;
    e.preventDefault();
    if (spec.up) {
      if (e.repeat || this._held[e.key]) return;
      this._held[e.key] = true;
    }
    this.send(spec.down);
  };

  BlimpView.prototype._handleKeyUp = function (e) {
    if (!this._held[e.key]) return;
    delete this._held[e.key];
    var spec = this.keys[e.key];
    if (!this.mounted || this.error || !spec || !spec.up) return;
    e.preventDefault();
    this.send(spec.up);
  };

  // A window that loses focus never hears its held keys come up.
  BlimpView.prototype._releaseAll = function () {
    var self = this;
    Object.keys(this._held).forEach(function (k) { self._handleKeyUp({ key: k, preventDefault: function () {} }); });
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
