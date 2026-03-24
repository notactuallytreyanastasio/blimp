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

    var self = this;
    requestAnimationFrame(function loop() {
      self._draw();
      requestAnimationFrame(loop);
    });
  }

  _resize() {
    var r = this.canvas.parentElement.getBoundingClientRect();
    this.dpr = devicePixelRatio || 1;
    this.w = r.width;
    this.h = r.height;
    this.canvas.width = this.w * this.dpr;
    this.canvas.height = this.h * this.dpr;
    this.canvas.style.width = this.w + 'px';
    this.canvas.style.height = this.h + 'px';
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

    // Sync actor nodes
    if (state.actors) {
      var ids = {};
      for (var a of state.actors) {
        ids[a.ref] = true;
        var h = this._hash(a.ref + JSON.stringify(a.state));
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
            x: 0, y: 0, hash: h,
            scale: 0,       // grows from 0 to 1
            flashT: 0,
            birthT: performance.now()
          });
        }
      }
      this.nodes = this.nodes.filter(n => ids[n.id]);
    }

    // Parse message sends from source
    if (source) {
      var re = /(\w+)\s*<-\s*:(\w+)/g, m;
      while ((m = re.exec(source)) !== null) {
        var toRef = this.varMap[m[1]];
        if (toRef) {
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
    if (n === 0) return;

    var cx = this.w * 0.55;
    var cy = this.h * 0.5;
    // Adaptive radius: grows with actor count but fits in canvas
    var maxR = Math.min(this.w * 0.3, this.h * 0.35);
    var r = Math.min(maxR, Math.max(60, n * 25));

    if (n === 1) {
      this.nodes[0].x = cx;
      this.nodes[0].y = cy;
    } else {
      for (var i = 0; i < n; i++) {
        var a = (2 * Math.PI * i / n) - Math.PI / 2;
        this.nodes[i].x = cx + Math.cos(a) * r;
        this.nodes[i].y = cy + Math.sin(a) * r;
      }
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

    // Rays (behind everything)
    for (var i = this.rays.length - 1; i >= 0; i--) {
      var ray = this.rays[i];
      var t = (now - ray.t0) / 1200;
      if (t > 1) { this.rays.splice(i, 1); continue; }
      var target = this.nodes.find(n => n.id === ray.toId);
      if (!target) { this.rays.splice(i, 1); continue; }
      this._drawRay(bx, by, target.x, target.y, t, ray.color, ray.label);
    }

    // REPL blob
    this._drawBlob(bx, by, now);

    // Actor hexagons
    for (var node of this.nodes) {
      // Animate scale in
      var age = (now - node.birthT) / 400;
      node.scale = Math.min(age, 1);
      node.scale = 1 - Math.pow(1 - node.scale, 3); // easeOut
      this._drawHex(node, now);
    }
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
    var r = 32 * s;
    if (r < 1) return;
    var h = node.hash;

    ctx.save();
    ctx.translate(node.x, node.y);

    // Build hex path
    var hexPath = () => {
      ctx.beginPath();
      for (var i = 0; i < 6; i++) {
        var a = Math.PI / 3 * i - Math.PI / 6;
        i === 0 ? ctx.moveTo(Math.cos(a)*r, Math.sin(a)*r)
                 : ctx.lineTo(Math.cos(a)*r, Math.sin(a)*r);
      }
      ctx.closePath();
    };

    // Fill
    hexPath();
    ctx.save();
    ctx.clip();
    this._genFill(ctx, h, r);
    ctx.restore();

    // Border
    hexPath();
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
