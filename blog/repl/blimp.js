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

    const response = await fetch(wasmUrl);
    const result = await WebAssembly.instantiateStreaming(response, importObject);
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
        try { viewData = JSON.parse(viewJson); } catch (e) { /* ignore */ }
      }
      return { ok: true, value: this._readString(resultPtr, resultLen), view: viewData };
    } else {
      const errPtr = this.instance.exports.blimp_get_error_ptr();
      const errLen = this.instance.exports.blimp_get_error_len();
      return { ok: false, error: this._readString(errPtr, errLen) };
    }
  }

  getState() {
    const ptr = this.instance.exports.blimp_get_state_ptr();
    const len = this.instance.exports.blimp_get_state_len();
    const json = this._readString(ptr, len);
    if (!json) return { vars: [], actors: [] };
    try { return JSON.parse(json); } catch (e) { return { vars: [], actors: [] }; }
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

  /**
   * Run every `test` block found in the given source.
   * Returns { ok, total, passed, failed, tests: [{actor, name, ok, detail?}] }
   * or { ok: false, error } on parse failure.
   */
  runTests(source) {
    const encoded = new TextEncoder().encode(source);
    const ptr = this.instance.exports.blimp_alloc(encoded.length);
    if (!ptr) return { ok: false, error: 'Failed to allocate memory' };

    const view = new Uint8Array(this.memory.buffer, ptr, encoded.length);
    view.set(encoded);

    const status = this.instance.exports.blimp_run_tests(ptr, encoded.length);
    this.instance.exports.blimp_free(ptr, encoded.length);

    const reportPtr = this.instance.exports.blimp_get_test_report_ptr();
    const reportLen = this.instance.exports.blimp_get_test_report_len();
    const json = this._readString(reportPtr, reportLen);
    let parsed;
    try { parsed = JSON.parse(json); }
    catch (e) { return { ok: false, error: 'Invalid test report JSON', raw: json }; }

    if (status === 2 || parsed.error) {
      return { ok: false, error: parsed.error || 'parse error', total: 0, passed: 0, failed: 0, tests: [] };
    }
    return { ok: status === 0, ...parsed };
  }

  onPrint(callback) {
    this._onPrint = callback;
  }

  onError(callback) {
    this._onError = callback;
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
