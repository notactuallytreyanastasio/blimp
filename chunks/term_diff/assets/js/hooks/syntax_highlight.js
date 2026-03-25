import hljs from "highlight.js/lib/common"

// Highlight a single hunk element.
// Collects all diff-content spans, joins their text (minus +/- prefix),
// highlights as one block for proper context, splits back into per-line HTML.
function highlightHunk(el, lang) {
  const contentSpans = el.querySelectorAll(".dc")
  if (contentSpans.length === 0) return

  const prefixes = []
  const rawLines = []

  for (const span of contentSpans) {
    const text = span.textContent
    const ch = text.charAt(0)
    if (ch === "+" || ch === "-" || ch === " ") {
      prefixes.push(ch)
      rawLines.push(text.slice(1))
    } else {
      prefixes.push("")
      rawLines.push(text)
    }
  }

  // Highlight the whole block as one unit for proper context
  const joined = rawLines.join("\n")
  let highlighted
  try {
    if (lang) {
      highlighted = hljs.highlight(joined, { language: lang, ignoreIllegals: true }).value
    } else {
      return // Skip autodetect - too unreliable for small hunks
    }
  } catch {
    return
  }

  // Split back into lines
  const highlightedLines = highlighted.split("\n")

  // Replace each content span's innerHTML, preserving the +/- prefix
  for (let i = 0; i < contentSpans.length && i < highlightedLines.length; i++) {
    const span = contentSpans[i]
    const prefix = prefixes[i]
    span.innerHTML = prefix + highlightedLines[i]
  }
}

const SyntaxHighlight = {
  mounted() {
    this._highlight()
  },
  updated() {
    this._highlight()
  },
  _highlight() {
    const lang = this.el.dataset.lang
    if (!lang) return // No language detected, skip
    highlightHunk(this.el, lang)
  }
}

export default SyntaxHighlight
