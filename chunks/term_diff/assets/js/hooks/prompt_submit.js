/**
 * PromptSubmit hook: Enter submits when text is single-line,
 * inserts newline when multiline. Shift+Enter always inserts newline.
 */
const PromptSubmit = {
  mounted() {
    this.el.addEventListener("keydown", (e) => {
      if (e.key !== "Enter") return
      if (e.shiftKey) return // Shift+Enter always inserts newline

      const hasMultipleLines = this.el.value.includes("\n")
      if (!hasMultipleLines) {
        e.preventDefault()
        const form = this.el.closest("form")
        if (form) form.requestSubmit()
      }
    })
  }
}

export default PromptSubmit
