// If you want to use Phoenix channels, run `mix help phx.gen.channel`
// to get started and then uncomment the line below.
// import "./user_socket.js"

// You can include dependencies in two ways.
//
// The simplest option is to put them in assets/vendor and
// import them using relative paths:
//
//     import "../vendor/some-package.js"
//
// Alternatively, you can `npm install some-package --prefix assets` and import
// them using a path starting with the package name:
//
//     import "some-package"
//
// If you have dependencies that try to import CSS, esbuild will generate a separate `app.css` file.
// To load it, simply add a second `<link>` to your `root.html.heex` file.

// Include phoenix_html to handle method=PUT/DELETE in forms and buttons.
import "phoenix_html"
// Establish Phoenix Socket and LiveView configuration.
import {Socket} from "phoenix"
import {LiveSocket} from "phoenix_live_view"
import {hooks as colocatedHooks} from "phoenix-colocated/term_diff"
import topbar from "../vendor/topbar"
import PromptSubmit from "./hooks/prompt_submit"
import AgentAutoScroll from "./hooks/agent_auto_scroll"

let Hooks = {...colocatedHooks}

Hooks.AutoScroll = {
  updated() {
    let hot = this.el.querySelector(".diff-hot-add, .diff-hot-del")
    if (hot) {
      hot.scrollIntoView({ behavior: "smooth", block: "center" })
    }
  }
}

Hooks.KeyNav = {
  mounted() {
    const navKeys = new Set(["j", "k", "Enter", "q", "Tab", "F", "l", "o", "s", "u", "a", "Escape"])
    let lastKey = null
    let lastKeyTime = 0

    window.addEventListener("keydown", (e) => {
      if (e.target.tagName === "INPUT" || e.target.tagName === "TEXTAREA") return

      const now = Date.now()

      // cc chord: commit mode
      if (e.key === "c" && lastKey === "c" && (now - lastKeyTime) < 400) {
        e.preventDefault()
        lastKey = null
        lastKeyTime = 0
        this.pushEvent("keydown", {key: "cc"})
        return
      }

      if (e.key === "c") {
        e.preventDefault()
        lastKey = "c"
        lastKeyTime = now
        return
      }

      if (navKeys.has(e.key)) {
        e.preventDefault()
        lastKey = null
        lastKeyTime = 0
        this.pushEvent("keydown", {key: e.key})
      }
    })
  },
  updated() {
    requestAnimationFrame(() => {
      let selected = this.el.querySelector("[data-selected]")
      if (selected) {
        selected.scrollIntoView({ block: "nearest", behavior: "smooth" })
      }
    })
  }
}

Hooks.PromptSubmit = PromptSubmit
Hooks.AgentAutoScroll = AgentAutoScroll

const csrfToken = document.querySelector("meta[name='csrf-token']").getAttribute("content")
const liveSocket = new LiveSocket("/live", Socket, {
  longPollFallbackMs: 2500,
  params: {_csrf_token: csrfToken},
  hooks: Hooks,
})

// Show progress bar on live navigation and form submits
topbar.config({barColors: {0: "#29d"}, shadowColor: "rgba(0, 0, 0, .3)"})
window.addEventListener("phx:page-loading-start", _info => topbar.show(300))
window.addEventListener("phx:page-loading-stop", _info => topbar.hide())

// connect if there are any LiveViews on the page
liveSocket.connect()

// expose liveSocket on window for web console debug logs and latency simulation:
// >> liveSocket.enableDebug()
// >> liveSocket.enableLatencySim(1000)  // enabled for duration of browser session
// >> liveSocket.disableLatencySim()
window.liveSocket = liveSocket

// The lines below enable quality of life phoenix_live_reload
// development features:
//
//     1. stream server logs to the browser console
//     2. click on elements to jump to their definitions in your code editor
//
if (process.env.NODE_ENV === "development") {
  window.addEventListener("phx:live_reload:attached", ({detail: reloader}) => {
    // Enable server log streaming to client.
    // Disable with reloader.disableServerLogs()
    reloader.enableServerLogs()

    // Open configured PLUG_EDITOR at file:line of the clicked element's HEEx component
    //
    //   * click with "c" key pressed to open at caller location
    //   * click with "d" key pressed to open at function component definition location
    // Disabled c/d click shortcuts to avoid conflict with KeyNav
    // Use reloader.openEditorAtCaller(el) and reloader.openEditorAtDef(el) manually if needed

    window.liveReloader = reloader
  })
}

