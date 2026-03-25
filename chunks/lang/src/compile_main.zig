const std = @import("std");
const Parser = @import("parser.zig").Parser;
const ast = @import("ast.zig");
const Codegen = @import("codegen.zig").Codegen;

pub fn main() !void {
    var gpa = std.heap.GeneralPurposeAllocator(.{}){};
    defer _ = gpa.deinit();
    const allocator = gpa.allocator();

    const args = try std.process.argsAlloc(allocator);
    defer std.process.argsFree(allocator, args);

    if (args.len < 2) {
        std.debug.print("Usage: blimp-compile <file.blimp> [-o <output>] [--dump-ir] [--run]\n", .{});
        std.process.exit(1);
    }

    // Parse arguments
    const input_file = args[1];
    var output_name: []const u8 = "a.out";
    var dump_ir = false;
    var run_after = false;
    var canvas_mode = false;
    var i: usize = 2;
    while (i < args.len) : (i += 1) {
        if (std.mem.eql(u8, args[i], "-o") and i + 1 < args.len) {
            output_name = args[i + 1];
            i += 1;
        } else if (std.mem.eql(u8, args[i], "--dump-ir")) {
            dump_ir = true;
        } else if (std.mem.eql(u8, args[i], "--run")) {
            run_after = true;
        } else if (std.mem.eql(u8, args[i], "--canvas")) {
            canvas_mode = true;
            run_after = true; // canvas implies run
        }
    }

    // Read source file
    const source = std.fs.cwd().readFileAlloc(allocator, input_file, 1024 * 1024) catch |err| {
        std.debug.print("Error reading '{s}': {}\n", .{ input_file, err });
        std.process.exit(1);
    };
    defer allocator.free(source);

    // Parse the source
    var arena = std.heap.ArenaAllocator.init(allocator);
    defer arena.deinit();

    const program_nodes = parseProgram(arena.allocator(), source);

    // Codegen
    var codegen = Codegen.init(arena.allocator(), "blimp_module");
    defer codegen.deinit();

    if (canvas_mode) {
        codegen.canvas_mode = true;
    }

    codegen.buildProgram(program_nodes) catch |err| {
        std.debug.print("Codegen error: {}\n", .{err});
        std.process.exit(1);
    };

    if (dump_ir) {
        codegen.dumpIR();
    }

    codegen.verify() catch |err| {
        std.debug.print("Verification error: {}\n", .{err});
        codegen.dumpIR();
        std.process.exit(1);
    };

    // Emit object file
    const obj_path = try std.fmt.allocPrintSentinel(allocator, "{s}.o", .{output_name}, 0);
    defer allocator.free(obj_path);

    codegen.emitObjectFile(obj_path.ptr) catch |err| {
        std.debug.print("Emit error: {}\n", .{err});
        std.process.exit(1);
    };

    // Find the runtime object
    const self_exe_dir = try std.fs.selfExeDirPathAlloc(allocator);
    defer allocator.free(self_exe_dir);

    const runtime_obj_path = try std.fmt.allocPrint(allocator, "{s}/../lib/blimp_runtime.o", .{self_exe_dir});
    defer allocator.free(runtime_obj_path);

    // Link
    const link_result = std.process.Child.run(.{
        .allocator = allocator,
        .argv = &.{ "cc", obj_path, runtime_obj_path, "-o", output_name },
    }) catch |err| {
        std.debug.print("Linker error: {}\n", .{err});
        std.process.exit(1);
    };
    defer allocator.free(link_result.stdout);
    defer allocator.free(link_result.stderr);

    switch (link_result.term) {
        .Exited => |code| {
            if (code != 0) {
                std.debug.print("Linker failed (exit {d}):\n{s}\n", .{ code, link_result.stderr });
                std.process.exit(1);
            }
        },
        else => {
            std.debug.print("Linker terminated abnormally:\n{s}\n", .{link_result.stderr});
            std.process.exit(1);
        },
    }

    // Clean up object file
    std.fs.cwd().deleteFile(obj_path) catch {};

    if (run_after) {
        // Execute the compiled binary (use absolute path)
        const abs_output = try std.fs.cwd().realpathAlloc(allocator, output_name);
        defer allocator.free(abs_output);
        const abs_z = try allocator.dupeZ(u8, abs_output);
        defer allocator.free(abs_z);

        const run_result = std.process.Child.run(.{
            .allocator = allocator,
            .argv = &.{abs_z},
        }) catch |err| {
            std.debug.print("Run error: {}\n", .{err});
            std.process.exit(1);
        };
        defer allocator.free(run_result.stdout);
        defer allocator.free(run_result.stderr);

        // Print stdout/stderr
        if (run_result.stdout.len > 0) {
            const stdout = std.fs.File.stdout();
            stdout.writeAll(run_result.stdout) catch {};
        }
        if (run_result.stderr.len > 0) {
            const stderr = std.fs.File.stderr();
            stderr.writeAll(run_result.stderr) catch {};
        }

        // Clean up binary
        std.fs.cwd().deleteFile(output_name) catch {};

        // Canvas mode: read JSON events and generate HTML
        if (canvas_mode) {
            const json_data = std.fs.cwd().readFileAlloc(allocator, "blimp_canvas.json", 1024 * 1024) catch |err| {
                std.debug.print("Canvas: no events generated ({s})\n", .{@errorName(err)});
                return;
            };
            defer allocator.free(json_data);
            std.fs.cwd().deleteFile("blimp_canvas.json") catch {};

            // Derive html name from input file
            const html_name = try std.fmt.allocPrint(allocator, "{s}.html", .{
                std.fs.path.stem(input_file),
            });
            defer allocator.free(html_name);

            const html_content = buildCanvasHtml(allocator, json_data, source) catch {
                std.debug.print("Canvas: failed to build HTML\n", .{});
                return;
            };
            defer allocator.free(html_content);
            std.fs.cwd().writeFile(.{ .sub_path = html_name, .data = html_content }) catch |err| {
                std.debug.print("Canvas: cannot write {s}: {s}\n", .{ html_name, @errorName(err) });
                return;
            };
            std.debug.print("Canvas: {s}\n", .{html_name});
        }
    } else {
        std.debug.print("Compiled: {s} -> {s}\n", .{ input_file, output_name });
    }
}

fn buildCanvasHtml(allocator: std.mem.Allocator, json_data: []const u8, source: []const u8) ![]u8 {
    var buf: std.ArrayListAligned(u8, null) = .empty;
    buf.ensureTotalCapacity(allocator, json_data.len + source.len + 16384) catch {};
    const w = buf.writer(allocator);
    try w.writeAll(
        \\<!DOCTYPE html>
        \\<html><head><meta charset="utf-8">
        \\<title>Blimp Canvas</title>
        \\<style>
        \\* { margin: 0; padding: 0; box-sizing: border-box; }
        \\body { background: #0e0e1a; overflow: hidden; font-family: monospace; }
        \\canvas { display: block; width: 100vw; height: 100vh; }
        \\#source { position: fixed; top: 12px; left: 12px; color: #fff; font-size: 11px;
        \\  white-space: pre; max-height: 40vh; overflow: auto; opacity: 0.6; z-index: 10;
        \\  background: rgba(14,14,26,0.85); padding: 8px; border-radius: 4px; }
        \\#info { position: fixed; bottom: 12px; left: 12px; color: #668; font-size: 11px; z-index: 10; }
        \\</style></head><body>
        \\<div id="source"></div>
        \\<canvas id="c"></canvas>
        \\<div id="info"></div>
        \\<script>
        \\const EVENTS =
    );
    try w.writeAll(json_data);
    try w.writeAll(
        \\;
        \\const SOURCE = `
    );
    // Escape backticks in source
    for (source) |ch| {
        if (ch == '`') {
            try w.writeAll("\\`");
        } else if (ch == '\\') {
            try w.writeAll("\\\\");
        } else {
            try w.writeByte(ch);
        }
    }
    try w.writeAll(
        \\`;
        \\document.getElementById('source').textContent = SOURCE;
        \\
        \\// ── Canvas replay engine ──
        \\const canvas = document.getElementById('c');
        \\const ctx = canvas.getContext('2d');
        \\const dpr = window.devicePixelRatio || 1;
        \\let W, H;
        \\function resize() {
        \\  W = window.innerWidth; H = window.innerHeight;
        \\  canvas.width = W * dpr; canvas.height = H * dpr;
        \\  canvas.style.width = W + 'px'; canvas.style.height = H + 'px';
        \\}
        \\resize(); window.addEventListener('resize', resize);
        \\
        \\// State
        \\const actors = {}; // id -> {type, fields, x, y, hash, scale, birthT, flashT}
        \\const rays = [];   // {from, to, t0, color, label}
        \\let eventIdx = 0;
        \\const EVENT_INTERVAL = 120; // ms between events
        \\const startTime = performance.now();
        \\
        \\function hash(str) {
        \\  let b = new Uint8Array(32);
        \\  for (let r = 0; r < 32; r++) {
        \\    let h = 0x6a09e667 ^ (r * 0x9e3779b9);
        \\    for (let i = 0; i < str.length; i++) { h ^= str.charCodeAt(i); h = Math.imul(h, 0x5bd1e995); h ^= h >>> 15; }
        \\    b[r] = h & 0xff;
        \\  }
        \\  return b;
        \\}
        \\
        \\function strColor(s) {
        \\  let h = 0; for (let i = 0; i < s.length; i++) { h = s.charCodeAt(i) + ((h << 5) - h); }
        \\  return `hsl(${Math.abs(h) % 360}, 70%, 60%)`;
        \\}
        \\
        \\function col(h, off, a) {
        \\  if (!h) return `rgba(40,40,60,${a})`;
        \\  let hue = ((h[off % 32] * 7 + h[(off+1) % 32]) % 360);
        \\  let sat = 40 + (h[(off+2) % 32] % 30);
        \\  return `hsla(${hue}, ${sat}%, 35%, ${a})`;
        \\}
        \\
        \\function layoutActors() {
        \\  let ids = Object.keys(actors);
        \\  let n = ids.length; if (n === 0) return;
        \\  let pad = 60, startX = W * 0.28, areaW = W - startX - pad, areaH = H - pad * 2;
        \\  let bestCols = 1, bestSize = 0;
        \\  for (let c = 1; c <= n; c++) {
        \\    let r = Math.ceil(n / c), cw = areaW / c, ch = areaH / r, fit = Math.min(cw, ch);
        \\    if (fit > bestSize) { bestSize = fit; bestCols = c; }
        \\  }
        \\  let cols = bestCols, rows = Math.ceil(n / cols);
        \\  let cellW = areaW / cols, cellH = areaH / rows;
        \\  let gridW = cols * cellW, gridH = rows * cellH;
        \\  let offX = startX + (areaW - gridW) / 2, offY = pad + (areaH - gridH) / 2;
        \\  ids.forEach((id, i) => {
        \\    let c = i % cols, r = Math.floor(i / cols);
        \\    actors[id].x = offX + cellW * (c + 0.5) + (r % 2) * cellW * 0.3;
        \\    actors[id].y = offY + cellH * (r + 0.5);
        \\  });
        \\}
        \\
        \\function processEvents() {
        \\  let now = performance.now();
        \\  while (eventIdx < EVENTS.length && (eventIdx * EVENT_INTERVAL) < (now - startTime)) {
        \\    let e = EVENTS[eventIdx++];
        \\    if (e.t === 'spawn') {
        \\      actors[e.id] = { type: e.type, fields: {}, x: 0, y: 0, hash: hash(e.type + '|' + e.id),
        \\        scale: 0, birthT: now, flashT: 0 };
        \\      layoutActors();
        \\    } else if (e.t === 'send') {
        \\      rays.push({ from: e.from, to: e.to, t0: now, color: strColor(e.msg), label: ':' + e.msg });
        \\    } else if (e.t === 'state') {
        \\      let a = actors[e.id];
        \\      if (a) { a.fields = e.fields; a.hash = hash(e.id + '|' + JSON.stringify(e.fields)); a.flashT = now; }
        \\    }
        \\  }
        \\}
        \\
        \\function drawBlob(x, y, now) {
        \\  let t = now / 2000;
        \\  ctx.save(); ctx.translate(x, y); ctx.beginPath();
        \\  for (let i = 0; i <= 40; i++) {
        \\    let a = (i / 40) * Math.PI * 2;
        \\    let w = Math.sin(a * 3 + t) * 4 + Math.cos(a * 5 + t * 1.3) * 3;
        \\    let r = 22 + w;
        \\    i === 0 ? ctx.moveTo(Math.cos(a)*r, Math.sin(a)*r) : ctx.lineTo(Math.cos(a)*r, Math.sin(a)*r);
        \\  }
        \\  ctx.closePath();
        \\  let g = ctx.createRadialGradient(0, 0, 0, 0, 0, 30);
        \\  g.addColorStop(0, 'rgba(166,226,46,0.25)'); g.addColorStop(1, 'rgba(166,226,46,0)');
        \\  ctx.fillStyle = g; ctx.fill();
        \\  ctx.strokeStyle = 'rgba(166,226,46,0.4)'; ctx.lineWidth = 1; ctx.stroke();
        \\  ctx.fillStyle = 'rgba(166,226,46,0.5)'; ctx.font = '9px monospace'; ctx.textAlign = 'center';
        \\  ctx.fillText('main', 0, 38); ctx.restore();
        \\}
        \\
        \\function drawHex(a, now) {
        \\  let age = (now - a.birthT) / 400;
        \\  a.scale = Math.min(1, 1 - Math.pow(1 - Math.min(age, 1), 3));
        \\  let r = 32 * a.scale; if (r < 1) return;
        \\  ctx.save(); ctx.translate(a.x, a.y);
        \\  // Hex path
        \\  let hexPath = () => { ctx.beginPath();
        \\    for (let i = 0; i < 6; i++) { let an = Math.PI/3*i - Math.PI/6;
        \\      i===0 ? ctx.moveTo(Math.cos(an)*r, Math.sin(an)*r) : ctx.lineTo(Math.cos(an)*r, Math.sin(an)*r); }
        \\    ctx.closePath(); };
        \\  // Fill
        \\  hexPath(); ctx.save(); ctx.clip();
        \\  let c1 = col(a.hash, 0, 1), c2 = col(a.hash, 3, 1);
        \\  let g = ctx.createLinearGradient(-r, -r, r, r); g.addColorStop(0, c1); g.addColorStop(1, c2);
        \\  ctx.fillStyle = g; ctx.fillRect(-r, -r, r*2, r*2);
        \\  // Pattern
        \\  let ptype = a.hash[6] % 4; ctx.globalAlpha = 0.4;
        \\  if (ptype === 0) { for (let i=0;i<12;i++) {
        \\    let dx=((a.hash[(i*2+8)%32]/255)*2-1)*r*0.8, dy=((a.hash[(i*2+9)%32]/255)*2-1)*r*0.8;
        \\    ctx.beginPath(); ctx.arc(dx,dy,(a.hash[(i+20)%32]/255)*4+1.5,0,Math.PI*2); ctx.fillStyle='#fff'; ctx.fill(); }
        \\  } else if (ptype === 1) { for (let i=0;i<3;i++) {
        \\    ctx.beginPath(); ctx.arc(((a.hash[(i*2+14)%32]/255)-0.5)*r*0.6,((a.hash[(i*2+15)%32]/255)-0.5)*r*0.6,
        \\      (a.hash[(i+12)%32]/255)*r*0.5+8,0,Math.PI*2); ctx.strokeStyle='#fff'; ctx.lineWidth=1.5; ctx.stroke(); }
        \\  } else if (ptype === 2) { ctx.save(); ctx.rotate((a.hash[7]/255)*Math.PI); ctx.strokeStyle='#fff'; ctx.lineWidth=1.5;
        \\    for (let s=-r*2;s<r*2;s+=5+(a.hash[8]%5)) { ctx.beginPath(); ctx.moveTo(s,-r*2); ctx.lineTo(s,r*2); ctx.stroke(); }
        \\    ctx.restore();
        \\  } else { for (let i=0;i<4;i++) { let bx=((a.hash[(i*2+10)%32]/255)*2-1)*r*0.5, by=((a.hash[(i*2+11)%32]/255)*2-1)*r*0.5;
        \\    let bg=ctx.createRadialGradient(bx,by,0,bx,by,r*0.35); bg.addColorStop(0,'rgba(255,255,255,0.3)');
        \\    bg.addColorStop(1,'rgba(255,255,255,0)'); ctx.fillStyle=bg; ctx.fillRect(-r,-r,r*2,r*2); } }
        \\  ctx.globalAlpha = 1; ctx.restore();
        \\  // Border
        \\  hexPath(); let flash = (now - a.flashT) / 500;
        \\  if (flash >= 0 && flash < 1) { ctx.strokeStyle = 'rgba(255,255,255,' + (1-flash)*0.9 + ')'; ctx.lineWidth = 2 + (1-flash)*4; }
        \\  else { ctx.strokeStyle = col(a.hash, 0, 0.6); ctx.lineWidth = 1.5; }
        \\  ctx.stroke();
        \\  // Label
        \\  ctx.fillStyle = '#fff'; ctx.font = '12px monospace'; ctx.textAlign = 'center';
        \\  ctx.fillText(a.type, 0, r + 13);
        \\  // State text
        \\  let fields = Object.entries(a.fields);
        \\  if (fields.length > 0) {
        \\    ctx.fillStyle = 'rgba(255,255,255,0.7)'; ctx.font = '10px monospace';
        \\    fields.forEach(([k,v], i) => ctx.fillText(k + ': ' + v, 0, r + 23 + i * 10));
        \\  }
        \\  ctx.restore();
        \\}
        \\
        \\function drawRay(fx, fy, tx, ty, t, color, label) {
        \\  let prog = Math.min(t * 2.5, 1); prog = 1 - Math.pow(1 - prog, 3);
        \\  let mx = fx + (tx - fx) * prog, my = fy + (ty - fy) * prog;
        \\  let alpha = 1 - t;
        \\  ctx.save(); ctx.globalAlpha = alpha;
        \\  ctx.setLineDash([5, 4]); ctx.strokeStyle = color; ctx.lineWidth = 2;
        \\  ctx.beginPath(); ctx.moveTo(fx, fy); ctx.lineTo(mx, my); ctx.stroke();
        \\  if (prog < 1) { ctx.setLineDash([]); ctx.beginPath(); ctx.arc(mx, my, 4, 0, Math.PI*2); ctx.fillStyle = color; ctx.fill(); }
        \\  if (prog >= 1 && t < 0.9) { let ring = (t - 0.4) / 0.5;
        \\    if (ring > 0) { ctx.setLineDash([]); ctx.globalAlpha = alpha * (1-ring);
        \\      ctx.beginPath(); ctx.arc(tx, ty, 20 + ring*30, 0, Math.PI*2); ctx.strokeStyle = color; ctx.lineWidth = 2; ctx.stroke(); } }
        \\  if (t < 0.5) { ctx.setLineDash([]); ctx.fillStyle = color; ctx.font = '10px monospace'; ctx.textAlign = 'center';
        \\    ctx.fillText(label, (fx+tx)/2, (fy+ty)/2 - 10); }
        \\  ctx.restore();
        \\}
        \\
        \\function drawParentLines() {
        \\  let ids = Object.keys(actors);
        \\  ctx.save();
        \\  ctx.strokeStyle = 'rgba(255,255,255,0.12)';
        \\  ctx.lineWidth = 1;
        \\  ctx.setLineDash([3, 6]);
        \\  for (let id of ids) {
        \\    let a = actors[id];
        \\    let dot = a.type.lastIndexOf('.');
        \\    if (dot < 0) continue;
        \\    let parentType = a.type.substring(0, dot);
        \\    // Find the parent actor by type name
        \\    for (let pid of ids) {
        \\      if (actors[pid].type === parentType) {
        \\        let p = actors[pid];
        \\        ctx.beginPath(); ctx.moveTo(p.x, p.y); ctx.lineTo(a.x, a.y); ctx.stroke();
        \\        break;
        \\      }
        \\    }
        \\  }
        \\  ctx.restore();
        \\}
        \\
        \\function draw() {
        \\  let now = performance.now();
        \\  processEvents();
        \\  ctx.setTransform(dpr, 0, 0, dpr, 0, 0);
        \\  ctx.fillStyle = '#0e0e1a'; ctx.fillRect(0, 0, W, H);
        \\  // Dots
        \\  ctx.fillStyle = '#161625';
        \\  for (let x = 0; x < W; x += 30) for (let y = 0; y < H; y += 30) ctx.fillRect(x, y, 1, 1);
        \\  let bx = W * 0.12, by = H * 0.5;
        \\  drawBlob(bx, by, now);
        \\  // Parent-child lines (behind hexagons)
        \\  drawParentLines();
        \\  Object.values(actors).forEach(a => drawHex(a, now));
        \\  // Rays
        \\  for (let i = rays.length - 1; i >= 0; i--) {
        \\    let r = rays[i], t = (now - r.t0) / 1200;
        \\    if (t > 1) { rays.splice(i, 1); continue; }
        \\    let from = actors[r.from], to = actors[r.to];
        \\    let fx = from ? from.x : bx, fy = from ? from.y : by;
        \\    if (to) drawRay(fx, fy, to.x, to.y, t, r.color, r.label);
        \\  }
        \\  // Info
        \\  let total = EVENTS.length, done = eventIdx;
        \\  document.getElementById('info').textContent = `${done}/${total} events` + (done >= total ? ' (complete)' : '');
        \\  requestAnimationFrame(draw);
        \\}
        \\requestAnimationFrame(draw);
        \\</script></body></html>
    );
    return buf.toOwnedSlice(allocator);
}

fn parseProgram(arena: std.mem.Allocator, source: []const u8) []const ast.Node {
    var parser = Parser.init(arena, source);
    if (parser.parseFilePublic()) |nodes| {
        return nodes;
    } else |_| {}

    var parser2 = Parser.init(arena, source);
    const expr = parser2.parseExpressionPublic() catch |err| {
        std.debug.print("Parse error: {} at line {}, col {}\n", .{ err, parser2.current.line, parser2.current.col });
        std.process.exit(1);
    };
    const single = arena.alloc(ast.Node, 1) catch {
        std.debug.print("Out of memory\n", .{});
        std.process.exit(1);
    };
    single[0] = expr;
    return single;
}
