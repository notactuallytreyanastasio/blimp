// Blimp WASM loader - embeddable interpreter for any page
class Blimp {
  constructor() {
    this.instance = null;
    this.memory = null;
    this._onPrint = null;
    this._onError = null;
  }

  async init(wasmUrl) {
    const importObject = {
      env: {
        blimp_js_print: (ptr, len) => {
          const str = this._readString(ptr, len);
          if (this._onPrint) this._onPrint(str);
          else console.log(str);
        },
        blimp_js_error: (ptr, len) => {
          const str = this._readString(ptr, len);
          if (this._onError) this._onError(str);
          else console.error(str);
        },
      },
    };

    // A URL in a browser; the bytes themselves in Node, which has no fetch
    // for a file path.
    const result = typeof wasmUrl === 'string'
      ? await WebAssembly.instantiateStreaming(fetch(wasmUrl), importObject)
      : await WebAssembly.instantiate(wasmUrl, importObject);
    this.instance = result.instance;
    this.memory = this.instance.exports.memory;

    this.instance.exports.blimp_init();
    return this;
  }

  eval(source) {
    const encoded = new TextEncoder().encode(source);
    const ptr = this.instance.exports.blimp_alloc(encoded.length);
    if (!ptr) return { ok: false, error: 'Failed to allocate memory' };

    const view = new Uint8Array(this.memory.buffer, ptr, encoded.length);
    view.set(encoded);

    const status = this.instance.exports.blimp_eval(ptr, encoded.length);
    this.instance.exports.blimp_free(ptr, encoded.length);

    if (status === 0) {
      const resultPtr = this.instance.exports.blimp_get_result_ptr();
      const resultLen = this.instance.exports.blimp_get_result_len();
      const hasView = this.instance.exports.blimp_has_view();
      let viewData = null;
      if (hasView) {
        const viewPtr = this.instance.exports.blimp_get_view_ptr();
        const viewLen = this.instance.exports.blimp_get_view_len();
        const viewJson = this._readString(viewPtr, viewLen);
        // A view that does not parse is an error the page sees, with where
        // and what. It used to be dropped here, and mount reported that the
        // program "did not produce a view" -- true of nothing but the parse.
        const parsed = Blimp._parseJson(viewJson, 'view JSON');
        if (parsed.error) return { ok: false, error: parsed.error, value: this._readString(resultPtr, resultLen) };
        viewData = parsed.value;
      }
      return { ok: true, value: this._readString(resultPtr, resultLen), view: viewData };
    } else {
      const errPtr = this.instance.exports.blimp_get_error_ptr();
      const errLen = this.instance.exports.blimp_get_error_len();
      return { ok: false, error: this._readString(errPtr, errLen) };
    }
  }

  // Send one message to the actor bound to `target` and return its reply as
  // a value: { ok: true, value } or { ok: false, error }. `args` is Blimp
  // source for the arguments, comma-separated ("1, :x"), or omitted.
  //
  // Unlike eval("target <- :msg"), a send keeps nothing afterwards: eval
  // holds on to its source and AST for good (about 390 bytes a call), which
  // a page that sends on every tick and key press cannot afford. It also
  // keeps its messages for getState(), which rebuilds the actors when read.
  send(target, message, args) {
    const x = this.instance.exports;
    if (!x.blimp_send) return { ok: false, error: 'this blimp.wasm has no blimp_send' };
    const put = (s) => {
      const bytes = new TextEncoder().encode(s || '');
      if (bytes.length === 0) return [0, 0];
      const p = x.blimp_alloc(bytes.length);
      new Uint8Array(this.memory.buffer, p, bytes.length).set(bytes);
      return [p, bytes.length];
    };
    const t = put(target), m = put(message), a = put(args);
    const status = x.blimp_send(t[0], t[1], m[0], m[1], a[0], a[1]);
    for (const [p, n] of [t, m, a]) if (n) x.blimp_free(p, n);
    if (status !== 0) {
      return { ok: false, error: this._readString(x.blimp_get_error_ptr(), x.blimp_get_error_len()) };
    }
    const parsed = Blimp._parseJson(this._readString(x.blimp_get_reply_ptr(), x.blimp_get_reply_len()), 'reply JSON');
    if (parsed.error) return { ok: false, error: parsed.error };
    return { ok: true, value: parsed.value };
  }

  // The program's actors and the messages sent since the last read, for
  // the canvas. Rebuilt on every call, so it is current after a send too.
  getState() {
    if (this.instance.exports.blimp_refresh_state) this.instance.exports.blimp_refresh_state();
    const ptr = this.instance.exports.blimp_get_state_ptr();
    const len = this.instance.exports.blimp_get_state_len();
    const json = this._readString(ptr, len);
    if (!json) return { vars: [], actors: [] };
    // A state that does not parse comes back empty, as before, but with an
    // `error` saying why: an empty canvas is otherwise indistinguishable
    // from a program with no actors.
    const parsed = Blimp._parseJson(json, 'state JSON');
    if (parsed.error) return { vars: [], actors: [], messages: [], error: parsed.error };
    return parsed.value;
  }

  complete(prefix) {
    const encoded = new TextEncoder().encode(prefix);
    const ptr = this.instance.exports.blimp_alloc(encoded.length);
    if (!ptr) return [];
    const view = new Uint8Array(this.memory.buffer, ptr, encoded.length);
    view.set(encoded);
    this.instance.exports.blimp_complete(ptr, encoded.length);
    this.instance.exports.blimp_free(ptr, encoded.length);
    const cPtr = this.instance.exports.blimp_get_complete_ptr();
    const cLen = this.instance.exports.blimp_get_complete_len();
    const json = this._readString(cPtr, cLen);
    if (!json) return [];
    try { return JSON.parse(json); } catch (e) { return []; }
  }

  reset() {
    this.instance.exports.blimp_reset();
  }

  onPrint(callback) {
    this._onPrint = callback;
  }

  onError(callback) {
    this._onError = callback;
  }

  // JSON.parse, with a failure turned into a message that names what was
  // being read, what the parser said, and the text around where it stopped
  // (control characters shown escaped, since they are usually the cause).
  static _parseJson(json, what) {
    try {
      return { value: JSON.parse(json) };
    } catch (e) {
      const m = /position (\d+)/.exec(e.message);
      const at = m ? Number(m[1]) : 0;
      const near = json.slice(Math.max(0, at - 30), at + 30)
        .replace(/[\u0000-\u001f]/g, (c) => JSON.stringify(c).slice(1, -1));
      return { error: `blimp.wasm returned ${what} (${json.length} bytes) that does not parse: ${e.message}; near: ${near}` };
    }
  }

  _readString(ptr, len) {
    if (len === 0) return '';
    const bytes = new Uint8Array(this.memory.buffer, ptr, len);
    return new TextDecoder().decode(bytes);
  }
}

// Export for both module and script tag usage
if (typeof module !== 'undefined') module.exports = Blimp;
if (typeof window !== 'undefined') window.Blimp = Blimp;
