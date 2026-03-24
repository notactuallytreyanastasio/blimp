// Blimp embeddable REPL widget
// Usage:
//   BlimpRepl.modal()          -- opens a modal REPL
//   BlimpRepl.embed('#target') -- embeds inline REPL in an element

(function() {
  var wasmBase = (document.currentScript && document.currentScript.src)
    ? document.currentScript.src.replace(/[^/]*$/, '')
    : 'repl/';

  var CSS = '\
.blimp-repl-container{background:#0e0e1a;color:#d4d4d4;font-family:"IBM Plex Mono","Fira Code","JetBrains Mono",monospace;font-size:13px;line-height:1.6;display:flex;flex-direction:column;overflow:hidden}\
.blimp-repl-container .repl-scroll{flex:1;overflow-y:auto;padding:1rem 1.25rem;min-height:0}\
.blimp-repl-container .line{white-space:pre-wrap;word-break:break-all}\
.blimp-repl-container .prompt-line{color:#a6e22e}\
.blimp-repl-container .result-line{color:#d4d4d4}\
.blimp-repl-container .error-line{color:#f92672}\
.blimp-repl-container .spacer-line{height:0.4em}\
.blimp-repl-container .input-row{display:flex;align-items:flex-start;margin-top:0.15rem}\
.blimp-repl-container .input-row .pc{color:#a6e22e;white-space:pre;user-select:none}\
.blimp-repl-container .input-row textarea{flex:1;background:transparent;border:none;color:#d4d4d4;font:inherit;font-size:13px;line-height:1.6;resize:none;outline:none;min-height:1.6em;max-height:15em;padding:0;margin:0}\
.blimp-repl-header{padding:0.5rem 1.25rem;border-bottom:1px solid #1a1a2e;display:flex;align-items:center;gap:0.75rem;flex-shrink:0}\
.blimp-repl-header .title{font-size:0.9rem;color:#a6e22e;font-weight:500}\
.blimp-repl-header .status{font-size:0.75rem;color:#666}\
.blimp-modal-overlay{position:fixed;top:0;left:0;width:100vw;height:100vh;background:rgba(0,0,0,0.7);z-index:10000;display:flex;align-items:center;justify-content:center;padding:2rem}\
.blimp-modal-overlay .blimp-modal{width:min(900px,90vw);height:min(600px,80vh);border-radius:8px;overflow:hidden;box-shadow:0 8px 60px rgba(0,0,0,0.5);display:flex;flex-direction:column}\
.blimp-modal .close-btn{margin-left:auto;background:none;border:none;color:#666;font-size:1.2rem;cursor:pointer;padding:0 0.5rem}\
.blimp-modal .close-btn:hover{color:#fff}\
.blimp-try-btn{display:inline-block;font-family:inherit;font-size:0.85rem;color:#a6e22e;cursor:pointer;padding:0.4rem 1rem;border:1px solid #a6e22e;border-radius:4px;background:transparent;text-decoration:none;user-select:none;transition:background 0.15s}\
.blimp-try-btn:hover{background:rgba(166,226,46,0.1)}\
';

  var styleInjected = false;
  function injectStyle() {
    if (styleInjected) return;
    var s = document.createElement('style');
    s.textContent = CSS;
    document.head.appendChild(s);
    styleInjected = true;
  }

  function createRepl(container, onReady) {
    injectStyle();

    container.innerHTML = '';
    container.className += ' blimp-repl-container';

    var scroll = document.createElement('div');
    scroll.className = 'repl-scroll';
    scroll.style.flex = '1';
    scroll.style.minHeight = '0';
    container.appendChild(scroll);

    // Canvas pane
    var canvasPane = document.createElement('div');
    canvasPane.style.height = '40%';
    canvasPane.style.borderTop = '1px solid #1a1a2e';
    canvasPane.style.flexShrink = '0';
    canvasPane.style.position = 'relative';
    var canvasEl = document.createElement('canvas');
    canvasEl.style.display = 'block';
    canvasPane.appendChild(canvasEl);
    container.appendChild(canvasPane);

    var viz = null;

    var blimp = null;
    var buffer = '';
    var depth = 0;
    var history = [];
    var historyIdx = -1;
    var inputRow = null;
    var inputEl = null;

    function addLine(cls, text) {
      var div = document.createElement('div');
      div.className = 'line ' + cls;
      if (cls === 'spacer-line') div.innerHTML = '&nbsp;';
      else div.textContent = text;
      scroll.appendChild(div);
      scroll.scrollTop = scroll.scrollHeight;
    }

    function createPrompt() {
      inputRow = document.createElement('div');
      inputRow.className = 'input-row';
      var pc = document.createElement('span');
      pc.className = 'pc';
      pc.textContent = depth > 0 ? '   ... ' : 'blimp> ';
      inputEl = document.createElement('textarea');
      inputEl.rows = 1;
      inputEl.spellcheck = false;
      inputEl.addEventListener('keydown', handleKey);
      inputEl.addEventListener('input', function() {
        this.style.height = 'auto';
        this.style.height = Math.min(this.scrollHeight, 240) + 'px';
      });
      inputRow.appendChild(pc);
      inputRow.appendChild(inputEl);
      scroll.appendChild(inputRow);
      inputEl.focus();
      scroll.scrollTop = scroll.scrollHeight;
    }

    function freezeInput() {
      var text = inputEl.value;
      var prompt = depth > 0 ? '   ... ' : 'blimp> ';
      inputRow.remove();
      addLine('prompt-line', prompt + text);
      inputRow = null;
      inputEl = null;
      return text;
    }

    function countDepth(text) {
      var d = 0;
      var words = text.replace(/#.*/g, '').match(/\b(do|end)\b/g) || [];
      for (var w of words) { if (w === 'do') d++; else if (w === 'end') d--; }
      return d;
    }

    function submitBuffer() {
      var source = buffer.trim();
      if (!source) { buffer = ''; depth = 0; return; }
      history.push(source);
      historyIdx = history.length;
      var result = blimp.eval(source);
      if (result.ok) {
        if (result.value) addLine('result-line', '=> ' + result.value);
      } else {
        addLine('error-line', result.error);
      }
      addLine('spacer-line', '');
      if (viz) viz.feed(blimp.getState(), source);
      buffer = '';
      depth = 0;
    }

    function handleKey(e) {
      if (e.key === 'Enter' && !e.shiftKey) {
        e.preventDefault();
        var line = freezeInput();
        buffer += (buffer ? '\n' : '') + line;
        depth += countDepth(line);
        if (depth > 0) { createPrompt(); return; }
        submitBuffer();
        createPrompt();
        return;
      }
      if (e.key === 'ArrowUp' && !buffer && inputEl.selectionStart === 0) {
        e.preventDefault();
        if (historyIdx > 0) { historyIdx--; inputEl.value = history[historyIdx]; }
      }
      if (e.key === 'ArrowDown' && !buffer) {
        e.preventDefault();
        if (historyIdx < history.length - 1) { historyIdx++; inputEl.value = history[historyIdx]; }
        else { historyIdx = history.length; inputEl.value = ''; }
      }
    }

    // Load WASM, canvas, and initialize
    var scriptsLoaded = 0;
    function checkReady() {
      scriptsLoaded++;
      if (scriptsLoaded < 2) return;
      // Both blimp.js and canvas.js loaded
      if (typeof BlimpCanvas !== 'undefined') {
        viz = new BlimpCanvas(canvasEl);
      }
      blimp = new Blimp();
      blimp.init(wasmBase + 'blimp.wasm').then(function() {
        addLine('result-line', 'Blimp REPL ready. Shift+Enter for newlines.');
        addLine('spacer-line', '');
        createPrompt();
        if (onReady) onReady();
      }).catch(function(err) {
        addLine('error-line', 'Failed to load: ' + err.message);
      });
    }
    var s1 = document.createElement('script');
    s1.src = wasmBase + 'blimp.js';
    s1.onload = checkReady;
    document.head.appendChild(s1);
    var s2 = document.createElement('script');
    s2.src = wasmBase + 'canvas.js';
    s2.onload = checkReady;
    document.head.appendChild(s2);

    // Click anywhere to focus
    container.addEventListener('click', function() {
      if (inputEl) inputEl.focus();
    });
  }

  window.BlimpRepl = {
    embed: function(selector) {
      var el = typeof selector === 'string' ? document.querySelector(selector) : selector;
      if (!el) return;
      createRepl(el);
    },

    modal: function() {
      injectStyle();
      var overlay = document.createElement('div');
      overlay.className = 'blimp-modal-overlay';

      var modal = document.createElement('div');
      modal.className = 'blimp-modal';

      var header = document.createElement('div');
      header.className = 'blimp-repl-header';
      header.innerHTML = '<span class="title">blimp</span><span class="status">repl</span>';
      var closeBtn = document.createElement('button');
      closeBtn.className = 'close-btn';
      closeBtn.textContent = '\u00d7';
      closeBtn.onclick = function() { overlay.remove(); };
      header.appendChild(closeBtn);
      modal.appendChild(header);

      var replEl = document.createElement('div');
      replEl.style.flex = '1';
      replEl.style.overflow = 'hidden';
      modal.appendChild(replEl);

      overlay.appendChild(modal);
      document.body.appendChild(overlay);

      overlay.addEventListener('click', function(e) {
        if (e.target === overlay) overlay.remove();
      });
      document.addEventListener('keydown', function handler(e) {
        if (e.key === 'Escape') { overlay.remove(); document.removeEventListener('keydown', handler); }
      });

      createRepl(replEl);
    }
  };
})();
