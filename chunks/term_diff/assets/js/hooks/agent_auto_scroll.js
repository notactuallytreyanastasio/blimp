/**
 * AgentAutoScroll hook: Uses MutationObserver to auto-scroll agent output.
 * Respects user scroll position - stops auto-scrolling when user scrolls up.
 */
const AgentAutoScroll = {
  mounted() {
    this._userScrolled = false
    this.scrollToBottom()

    // Track when the user scrolls away from the bottom
    this.el.addEventListener("scroll", () => {
      const threshold = 50
      const atBottom = this.el.scrollHeight - this.el.scrollTop - this.el.clientHeight < threshold
      this._userScrolled = !atBottom
    })

    this.observer = new MutationObserver(() => {
      if (!this._userScrolled) this.scrollToBottom()
    })
    this.observer.observe(this.el, { childList: true, subtree: true, characterData: true })
  },
  updated() {
    if (!this._userScrolled) this.scrollToBottom()
  },
  destroyed() {
    if (this.observer) this.observer.disconnect()
  },
  scrollToBottom() {
    this.el.scrollTop = this.el.scrollHeight
  }
}

export default AgentAutoScroll
