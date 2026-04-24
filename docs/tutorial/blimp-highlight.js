// Blimp syntax highlighter -- standalone, no dependencies.
//
// Exposes window.blimpHighlight(source) which returns HTML with <span>
// tags around tokens. Pair with blimp-highlight.css for colors.
//
// Token classes: tok-c (comment), tok-s (string), tok-si (interpolation
// delimiter), tok-a (atom), tok-n (number), tok-o (operator), tok-k
// (keyword), tok-cn (constant: true/false/nil), tok-bi (builtin function),
// tok-t (type / capitalized identifier), tok-p (property / map key).
//
// Keyword list is derived from chunks/lang/tree-sitter-blimp/grammar.js
// plus Zig parser extras (test, property, given, if, else).

(function(global) {
  const KEYWORDS = new Set([
    'actor', 'state', 'on', 'do', 'end',
    'become', 'reply', 'spawn',
    'test', 'property', 'given',
    'when', 'case', 'situation',
    'def', 'fn', 'for', 'in', 'self',
    'bubble', 'bubbles', 'orelse',
    'if', 'else',
  ]);

  const CONSTANTS = new Set(['true', 'false', 'nil']);

  // Subset of commonly used stdlib functions. Not exhaustive -- just enough
  // to visually lift them out of the prose.
  const BUILTINS = new Set([
    // assertions
    'assert', 'assert_eq', 'assert_ne', 'refute',
    // collections
    'length', 'append', 'reverse', 'head', 'tail', 'sort', 'merge',
    'flat', 'zip', 'uniq', 'slice', 'elem', 'range',
    'map', 'filter', 'reduce', 'each',
    // maps
    'lookup', 'put', 'keys', 'values',
    // strings
    'concat', 'split', 'contains', 'upcase', 'downcase', 'to_string',
    'char_at', 'char_code', 'from_char_code',
    // math/util
    'max', 'min', 'abs', 'rem', 'floor', 'ceil', 'round', 'random', 'sum',
    'now', 'to_int', 'type_of', 'print', 'nil?', 'empty?', 'size', 'not',
    // property generators
    'gen_int', 'gen_atom', 'gen_list', 'gen_boolean', 'gen_string', 'gen_one_of',
    // view primitives
    'stack', 'row', 'grid', 'heading', 'text', 'bold', 'italic', 'code',
    'code_block', 'blockquote', 'button', 'divider', 'list', 'link', 'image',
  ]);

  function escapeHtml(s) {
    return s
      .replace(/&/g, '&amp;')
      .replace(/</g, '&lt;')
      .replace(/>/g, '&gt;');
  }

  // Match a block, wrapped in a single span class; used for comments and numbers.
  function wrap(cls, s) {
    return '<span class="' + cls + '">' + escapeHtml(s) + '</span>';
  }

  // Highlight a string literal, including #{...} interpolations.
  function highlightString(s) {
    let out = '<span class="tok-s">' + escapeHtml(s[0]); // opening "
    let i = 1;
    while (i < s.length - 1) {
      const c = s[i];
      if (c === '\\' && i + 1 < s.length - 1) {
        out += escapeHtml(s.substr(i, 2));
        i += 2;
        continue;
      }
      if (c === '#' && s[i + 1] === '{') {
        // close string span, render interpolation contents, reopen.
        out += '</span><span class="tok-si">#{</span>';
        let j = i + 2;
        let depth = 1;
        while (j < s.length - 1 && depth > 0) {
          if (s[j] === '{') depth++;
          else if (s[j] === '}') depth--;
          if (depth === 0) break;
          j++;
        }
        const inner = s.slice(i + 2, j);
        out += highlight(inner);
        out += '<span class="tok-si">}</span><span class="tok-s">';
        i = j + 1;
        continue;
      }
      out += escapeHtml(c);
      i++;
    }
    out += escapeHtml(s[s.length - 1]) + '</span>'; // closing "
    return out;
  }

  function highlight(src) {
    let out = '';
    let i = 0;
    const len = src.length;

    while (i < len) {
      const c = src[i];

      // Comment: # to end of line
      if (c === '#') {
        let j = i;
        while (j < len && src[j] !== '\n') j++;
        out += wrap('tok-c', src.slice(i, j));
        i = j;
        continue;
      }

      // String
      if (c === '"') {
        let j = i + 1;
        while (j < len) {
          if (src[j] === '\\') { j += 2; continue; }
          if (src[j] === '"') { j++; break; }
          j++;
        }
        out += highlightString(src.slice(i, j));
        i = j;
        continue;
      }

      // Atom ":name" -- but not "::" which is the default assignment operator,
      // and not ":" alone before a space (used as key delimiter / type annotation).
      if (c === ':') {
        if (src[i + 1] === ':') {
          out += wrap('tok-o', '::');
          i += 2;
          continue;
        }
        const m = src.slice(i).match(/^:[a-zA-Z_][\w]*[?!]?/);
        if (m) {
          out += wrap('tok-a', m[0]);
          i += m[0].length;
          continue;
        }
        // lone colon -- punctuation, leave plain
        out += ':';
        i++;
        continue;
      }

      // Number (integer or float)
      if (/[0-9]/.test(c) || (c === '-' && /[0-9]/.test(src[i + 1] || ''))) {
        const m = src.slice(i).match(/^-?\d+(\.\d+)?/);
        if (m) {
          out += wrap('tok-n', m[0]);
          i += m[0].length;
          continue;
        }
      }

      // Multi-char operators first
      const rest = src.slice(i);
      let opMatch = rest.match(/^(<-|\|>|==|!=|<=|>=|&&|\|\||->|\+\+)/);
      if (opMatch) {
        out += wrap('tok-o', opMatch[0]);
        i += opMatch[0].length;
        continue;
      }
      // Single-char operators
      if ('+-*/=<>!|'.indexOf(c) !== -1) {
        out += wrap('tok-o', c);
        i++;
        continue;
      }

      // Identifier
      if (/[a-zA-Z_]/.test(c)) {
        const m = rest.match(/^[a-zA-Z_][\w]*[?!]?/);
        if (m) {
          const word = m[0];
          let cls = null;
          if (KEYWORDS.has(word)) cls = 'tok-k';
          else if (CONSTANTS.has(word)) cls = 'tok-cn';
          else if (BUILTINS.has(word)) cls = 'tok-bi';
          else if (/^[A-Z]/.test(word)) cls = 'tok-t';
          // Map key: identifier immediately followed by ":" then space (e.g. "id: 1")
          else if (src[i + word.length] === ':' && src[i + word.length + 1] !== ':' && /\s/.test(src[i + word.length + 1] || ' ')) {
            cls = 'tok-p';
          }
          out += cls ? wrap(cls, word) : escapeHtml(word);
          i += word.length;
          continue;
        }
      }

      // Default: escape and advance one char.
      out += escapeHtml(c);
      i++;
    }

    return out;
  }

  global.blimpHighlight = highlight;
})(typeof window !== 'undefined' ? window : globalThis);
