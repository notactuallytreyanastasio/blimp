// Blimp Canvas - generative art from actor state
// Clean rewrite. No accumulated cruft.

class BlimpCanvas {
  constructor(el) {
    this.canvas = el;
    this.ctx = el.getContext('2d');
    this.nodes = [];      // {id, type, state, x, y, hash, scale, flashT}
    this.rays = [];       // {fromId, toId, t0, color, label}
    this.varMap = {};     // variable name -> actor ref string
    this.w = 0;
    this.h = 0;
    this.dpr = 1;

    this._resize();
    window.addEventListener('resize', () => this._resize());

    // ResizeObserver catches cases window resize misses (mobile rotation, flex layout changes)
    if (typeof ResizeObserver !== 'undefined') {
      new ResizeObserver(() => this._resize()).observe(this.canvas.parentElement);
    }

    var self = this;
    requestAnimationFrame(function loop() {
      // Re-check size each frame in case layout shifted
      var r = self.canvas.parentElement.getBoundingClientRect();
      if (Math.abs(r.width - self.w) > 1 || Math.abs(r.height - self.h) > 1) {
        self._resize();
      }
      self._draw();
      requestAnimationFrame(loop);
    });
  }

  _resize() {
    var r = this.canvas.parentElement.getBoundingClientRect();
    this.dpr = window.devicePixelRatio || 1;
    this.w = r.width;
    this.h = r.height;
    this.canvas.width = this.w * this.dpr;
    this.canvas.height = this.h * this.dpr;
    this.canvas.style.width = this.w + 'px';
    this.canvas.style.height = this.h + 'px';
    this._layout();
  }

  // Called after each eval with fresh state + source text
  feed(state, source) {
    if (!state) return;

    // Build var -> ref map
    if (state.vars) {
      for (var v of state.vars) {
        if (v.value && v.value.startsWith('ref<')) {
          this.varMap[v.name] = v.value;
        }
      }
    }

    // Sync value nodes (non-actor variables get squares)
    if (state.vars) {
      for (var v of state.vars) {
        if (v.value && v.value.startsWith('ref<')) continue; // skip actor refs
        if (v.value && v.value.startsWith(':')) continue; // skip actor templates
        if (v.value && v.value.startsWith('fn')) continue; // skip defs and closures
        var vid = 'var:' + v.name;
        var h = this._hash('val|' + v.name + '=' + v.value);
        var existing = this.nodes.find(n => n.id === vid);
        if (existing) {
          var changed = !this._eqArr(existing.hash, h);
          existing.hash = h;
          existing.state = { value: v.value };
          if (changed) existing.flashT = performance.now();
        } else {
          this.nodes.push({
            id: vid, type: v.name, state: { value: v.value },
            shape: 'square',
            x: 0, y: 0, hash: h,
            scale: 0, flashT: 0, birthT: performance.now()
          });
        }
      }
    }

    // Sync actor nodes
    if (state.actors) {
      var ids = {};
      for (var a of state.actors) {
        ids[a.ref] = true;
        var h = this._hash(a.type + '|' + JSON.stringify(a.state));
        var existing = this.nodes.find(n => n.id === a.ref);
        if (existing) {
          var changed = !this._eqArr(existing.hash, h);
          existing.hash = h;
          existing.state = a.state;
          existing.type = a.type;
          if (changed) existing.flashT = performance.now();
        } else {
          this.nodes.push({
            id: a.ref, type: a.type, state: a.state,
            shape: 'hex',
            x: 0, y: 0, hash: h,
            scale: 0,
            flashT: 0,
            birthT: performance.now()
          });
        }
      }
      this.nodes = this.nodes.filter(n => ids[n.id] || n.shape === 'square');
    }

    // Add rays from runtime message log (catches sends inside closures).
    // msg.from is the sending actor when the send happened inside a handler,
    // null for sends from the page or REPL. A burst of sends from one eval is
    // staggered so it reads as a sequence instead of a single flash.
    // The same send repeated in one eval (a board asking itself :blocked?
    // once per cell) collapses into one ray labelled with the count.
    if (state.messages) {
      var t0 = performance.now(), i = 0, seen = {};
      for (var msg of state.messages) {
        if (!this.nodes.find(n => n.id === msg.target)) continue;
        var key = (msg.from || '') + '>' + msg.target + ':' + msg.message;
        if (seen[key]) { seen[key].count++; seen[key].label = ':' + msg.message + ' \u00d7' + seen[key].count; continue; }
        seen[key] = {
          fromId: msg.from || null,
          toId: msg.target,
          t0: t0 + Math.min(i, 40) * 30,
          color: this._strColor(msg.message),
          label: ':' + msg.message,
          count: 1
        };
        this.rays.push(seen[key]);
        i++;
      }
    }

    // Also parse direct sends from source text
    if (source) {
      var re = /(\w+)\s*<-\s*:(\w+)/g, m;
      while ((m = re.exec(source)) !== null) {
        var toRef = this.varMap[m[1]];
        if (toRef && this.nodes.find(n => n.id === toRef)) {
          this.rays.push({
            toId: toRef,
            t0: performance.now(),
            color: this._strColor(m[2]),
            label: ':' + m[2]
          });
        }
      }
    }

    this._layout();
  }

  _layout() {
    var n = this.nodes.length;
    this._hexScale = 1;
    if (n === 0) return;

    // Available area: right 75% of canvas, with padding
    var pad = 40;
    var startX = this.w * 0.22;
    var areaW = this.w - startX - pad;
    var areaH = this.h - pad * 2;

    // Find a grid that fits all nodes without overlap.
    // Try increasing columns until everything fits with decent spacing.
    var bestCols = 1, bestSize = 0;
    for (var tryC = 1; tryC <= n; tryC++) {
      var tryR = Math.ceil(n / tryC);
      var cellW = areaW / tryC;
      var cellH = areaH / tryR;
      var fit = Math.min(cellW, cellH); // max hex diameter that fits
      if (fit > bestSize) {
        bestSize = fit;
        bestCols = tryC;
      }
    }

    var cols = bestCols;
    var rows = Math.ceil(n / cols);
    var cellW = areaW / cols;
    var cellH = areaH / rows;

    // Scale hexagons: 32px radius is "full size" at 80px cell
    this._hexScale = Math.min(1, Math.min(cellW, cellH) / 80);

    // Center the grid
    var gridW = cols * cellW;
    var gridH = rows * cellH;
    var offX = startX + (areaW - gridW) / 2;
    var offY = pad + (areaH - gridH) / 2;

    for (var i = 0; i < n; i++) {
      var col = i % cols;
      var row = Math.floor(i / cols);
      // Stagger odd rows for hex packing feel
      var xOff = (row % 2) * cellW * 0.3;
      this.nodes[i].x = offX + cellW * (col + 0.5) + xOff;
      this.nodes[i].y = offY + cellH * (row + 0.5);
    }
  }

  _draw() {
    var ctx = this.ctx;
    var now = performance.now();
    ctx.setTransform(this.dpr, 0, 0, this.dpr, 0, 0);

    // BG
    ctx.fillStyle = '#0e0e1a';
    ctx.fillRect(0, 0, this.w, this.h);

    // Subtle dots
    ctx.fillStyle = '#161625';
    for (var x = 0; x < this.w; x += 30)
      for (var y = 0; y < this.h; y += 30) {
        ctx.fillRect(x, y, 1, 1);
      }

    var bx = this.w * 0.12, by = this.h * 0.5;

    // REPL blob
    this._drawBlob(bx, by, now);

    // Actor hexagons
    for (var node of this.nodes) {
      var age = (now - node.birthT) / 400;
      node.scale = Math.min(age, 1);
      node.scale = 1 - Math.pow(1 - node.scale, 3); // easeOut
      this._drawHex(node, now);
    }

    // Rays on top of everything. A ray starts at its sending actor when the
    // runtime named one, otherwise at the REPL blob.
    for (var i = this.rays.length - 1; i >= 0; i--) {
      var ray = this.rays[i];
      var t = (now - ray.t0) / 1200;
      if (t > 1) { this.rays.splice(i, 1); continue; }
      if (t < 0) continue;
      var target = this.nodes.find(n => n.id === ray.toId);
      if (!target) { this.rays.splice(i, 1); continue; }
      var source = ray.fromId ? this.nodes.find(n => n.id === ray.fromId) : null;
      if (source && source === target) {
        this._drawSelfRay(target.x, target.y, t, ray.color, ray.label);
      } else if (source) {
        this._drawRay(source.x, source.y, target.x, target.y, t, ray.color, ray.label);
      } else {
        this._drawRay(bx, by, target.x, target.y, t, ray.color, ray.label);
      }
    }
  }

  // An actor sending to itself: a ring that grows out of the node.
  _drawSelfRay(x, y, t, color, label) {
    var ctx = this.ctx;
    var r = (32 * (this._hexScale || 1)) * (1 + t * 0.8);
    ctx.save();
    ctx.globalAlpha = 1 - t;
    ctx.setLineDash([3, 3]);
    ctx.strokeStyle = color;
    ctx.lineWidth = 1.5;
    ctx.beginPath();
    ctx.arc(x, y, r, 0, Math.PI * 2);
    ctx.stroke();
    if (t < 0.5) {
      ctx.setLineDash([]);
      ctx.fillStyle = color;
      ctx.font = '10px monospace';
      ctx.textAlign = 'center';
      ctx.fillText(label, x, y - r - 6);
    }
    ctx.restore();
  }

  _drawBlob(x, y, now) {
    var ctx = this.ctx;
    var t = now / 2000;
    ctx.save();
    ctx.translate(x, y);
    ctx.beginPath();
    for (var i = 0; i <= 40; i++) {
      var a = (i / 40) * Math.PI * 2;
      var w = Math.sin(a * 3 + t) * 4 + Math.cos(a * 5 + t * 1.3) * 3;
      var r = 22 + w;
      i === 0 ? ctx.moveTo(Math.cos(a)*r, Math.sin(a)*r)
               : ctx.lineTo(Math.cos(a)*r, Math.sin(a)*r);
    }
    ctx.closePath();
    var g = ctx.createRadialGradient(0, 0, 0, 0, 0, 30);
    g.addColorStop(0, 'rgba(166,226,46,0.25)');
    g.addColorStop(1, 'rgba(166,226,46,0)');
    ctx.fillStyle = g;
    ctx.fill();
    ctx.strokeStyle = 'rgba(166,226,46,0.4)';
    ctx.lineWidth = 1;
    ctx.stroke();
    ctx.fillStyle = 'rgba(166,226,46,0.5)';
    ctx.font = '9px monospace';
    ctx.textAlign = 'center';
    ctx.fillText('REPL', 0, 38);
    ctx.restore();
  }

  _drawHex(node, now) {
    var ctx = this.ctx;
    var s = node.scale;
    var hs = this._hexScale || 1;
    var r = 32 * s * hs;
    if (r < 1) return;
    var h = node.hash;

    ctx.save();
    ctx.translate(node.x, node.y);

    var isSquare = node.shape === 'square';

    // Build shape path
    var shapePath = () => {
      ctx.beginPath();
      if (isSquare) {
        var s = r * 0.85;
        ctx.rect(-s, -s, s * 2, s * 2);
      } else {
        for (var i = 0; i < 6; i++) {
          var a = Math.PI / 3 * i - Math.PI / 6;
          i === 0 ? ctx.moveTo(Math.cos(a)*r, Math.sin(a)*r)
                   : ctx.lineTo(Math.cos(a)*r, Math.sin(a)*r);
        }
        ctx.closePath();
      }
    };

    // Fill
    shapePath();
    ctx.save();
    ctx.clip();
    this._genFill(ctx, h, r);
    ctx.restore();

    // Border
    shapePath();
    var flash = (now - node.flashT) / 500;
    if (flash >= 0 && flash < 1) {
      ctx.strokeStyle = 'rgba(255,255,255,' + (1 - flash) * 0.9 + ')';
      ctx.lineWidth = 2 + (1 - flash) * 4;
    } else {
      ctx.strokeStyle = this._col(h, 0, 0.6);
      ctx.lineWidth = 1.5;
    }
    ctx.stroke();

    // Label
    ctx.fillStyle = '#556';
    ctx.font = '9px monospace';
    ctx.textAlign = 'center';
    ctx.fillText(node.type, 0, r + 13);

    ctx.restore();
  }

  _genFill(ctx, h, r) {
    if (!h) { ctx.fillStyle = '#1a1a2e'; ctx.fillRect(-r,-r,r*2,r*2); return; }

    var c1 = this._col(h, 0, 1);
    var c2 = this._col(h, 3, 1);

    // Gradient base
    var g = ctx.createLinearGradient(-r, -r, r, r);
    g.addColorStop(0, c1);
    g.addColorStop(1, c2);
    ctx.fillStyle = g;
    ctx.fillRect(-r, -r, r * 2, r * 2);

    // Pattern overlay based on hash byte
    var type = h[6] % 4;
    ctx.globalAlpha = 0.4;

    if (type === 0) {
      // Scattered dots
      for (var i = 0; i < 12; i++) {
        var dx = ((h[(i*2+8)%32] / 255) * 2 - 1) * r * 0.8;
        var dy = ((h[(i*2+9)%32] / 255) * 2 - 1) * r * 0.8;
        var sz = (h[(i+20)%32] / 255) * 4 + 1.5;
        ctx.beginPath();
        ctx.arc(dx, dy, sz, 0, Math.PI * 2);
        ctx.fillStyle = '#fff';
        ctx.fill();
      }
    } else if (type === 1) {
      // Concentric rings
      for (var i = 0; i < 3; i++) {
        var cr = (h[(i+12)%32] / 255) * r * 0.5 + 8;
        var cx = ((h[(i*2+14)%32] / 255) - 0.5) * r * 0.6;
        var cy = ((h[(i*2+15)%32] / 255) - 0.5) * r * 0.6;
        ctx.beginPath();
        ctx.arc(cx, cy, cr, 0, Math.PI * 2);
        ctx.strokeStyle = '#fff';
        ctx.lineWidth = 1.5;
        ctx.stroke();
      }
    } else if (type === 2) {
      // Diagonal stripes
      var sa = (h[7] / 255) * Math.PI;
      var sp = 5 + (h[8] % 5);
      ctx.save();
      ctx.rotate(sa);
      ctx.strokeStyle = '#fff';
      ctx.lineWidth = 1.5;
      for (var s = -r * 2; s < r * 2; s += sp) {
        ctx.beginPath();
        ctx.moveTo(s, -r * 2);
        ctx.lineTo(s, r * 2);
        ctx.stroke();
      }
      ctx.restore();
    } else {
      // Soft blobs
      for (var i = 0; i < 4; i++) {
        var bx = ((h[(i*2+10)%32] / 255) * 2 - 1) * r * 0.5;
        var by = ((h[(i*2+11)%32] / 255) * 2 - 1) * r * 0.5;
        var bg = ctx.createRadialGradient(bx, by, 0, bx, by, r * 0.35);
        bg.addColorStop(0, 'rgba(255,255,255,0.3)');
        bg.addColorStop(1, 'rgba(255,255,255,0)');
        ctx.fillStyle = bg;
        ctx.fillRect(-r, -r, r * 2, r * 2);
      }
    }
    ctx.globalAlpha = 1;
  }

  _drawRay(fx, fy, tx, ty, t, color, label) {
    var ctx = this.ctx;
    var prog = Math.min(t * 2.5, 1);
    prog = 1 - Math.pow(1 - prog, 3);
    var mx = fx + (tx - fx) * prog;
    var my = fy + (ty - fy) * prog;
    var alpha = 1 - t;

    ctx.save();
    ctx.globalAlpha = alpha;

    // Trail
    ctx.setLineDash([5, 4]);
    ctx.strokeStyle = color;
    ctx.lineWidth = 2;
    ctx.beginPath();
    ctx.moveTo(fx, fy);
    ctx.lineTo(mx, my);
    ctx.stroke();

    // Head
    if (prog < 1) {
      ctx.setLineDash([]);
      ctx.beginPath();
      ctx.arc(mx, my, 4, 0, Math.PI * 2);
      ctx.fillStyle = color;
      ctx.fill();
    }

    // Impact ring
    if (prog >= 1 && t < 0.9) {
      var ring = (t - 0.4) / 0.5;
      if (ring > 0) {
        ctx.setLineDash([]);
        ctx.globalAlpha = alpha * (1 - ring);
        ctx.beginPath();
        ctx.arc(tx, ty, 20 + ring * 30, 0, Math.PI * 2);
        ctx.strokeStyle = color;
        ctx.lineWidth = 2;
        ctx.stroke();
      }
    }

    // Label
    if (t < 0.5) {
      ctx.setLineDash([]);
      ctx.fillStyle = color;
      ctx.font = '10px monospace';
      ctx.textAlign = 'center';
      ctx.fillText(label, (fx + tx) / 2, (fy + ty) / 2 - 10);
    }

    ctx.restore();
  }

  // ── Utilities ──

  _hash(str) {
    var b = new Uint8Array(32);
    for (var r = 0; r < 32; r++) {
      var h = 0x6a09e667 ^ (r * 0x9e3779b9);
      for (var i = 0; i < str.length; i++) {
        h ^= str.charCodeAt(i);
        h = Math.imul(h, 0xcc9e2d51);
        h = (h << 15) | (h >>> 17);
        h = Math.imul(h, 0x1b873593);
      }
      h ^= str.length;
      h ^= h >>> 16;
      h = Math.imul(h, 0x85ebca6b);
      h ^= h >>> 13;
      h = Math.imul(h, 0xc2b2ae35);
      h ^= h >>> 16;
      b[r] = h & 0xFF;
    }
    return b;
  }

  _eqArr(a, b) {
    if (!a || !b) return false;
    for (var i = 0; i < 32; i++) if (a[i] !== b[i]) return false;
    return true;
  }

  _col(h, off, alpha) {
    if (!h) return 'rgb(100,100,100)';
    var r = h[off % 32] % 180 + 75;
    var g = h[(off + 1) % 32] % 180 + 75;
    var b = h[(off + 2) % 32] % 180 + 75;
    if (alpha !== undefined && alpha < 1) {
      return 'rgba(' + r + ',' + g + ',' + b + ',' + alpha + ')';
    }
    return 'rgb(' + r + ',' + g + ',' + b + ')';
  }

  _strColor(s) {
    var h = 5381;
    for (var i = 0; i < s.length; i++) h = ((h << 5) + h + s.charCodeAt(i)) | 0;
    h = Math.abs(h);
    return 'rgb(' + (80 + (h >> 16 & 0xFF) % 160) + ',' + (80 + (h >> 8 & 0xFF) % 160) + ',' + (80 + (h & 0xFF) % 160) + ')';
  }
}

if (typeof window !== 'undefined') window.BlimpCanvas = BlimpCanvas;
