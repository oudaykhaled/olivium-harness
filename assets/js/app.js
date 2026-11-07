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
import {hooks as colocatedHooks} from "phoenix-colocated/harness_forge"
import topbar from "../vendor/topbar"

const companyFormIds = new Set([
  "company-guide-project-form", "company-profile-form", "company-repository-form",
  "company-project-form", "company-capability-form", "company-plan-form",
  "company-plan-decision-form", "company-plan-build-form", "company-diff-form",
  "company-analysis-form", "company-analysis-edit-form",
  "company-assessment-scope-form", "company-assessment-rubric-form",
  "company-assessment-results-form",
])
const companyControls = form => Array.from(form.elements).filter(control =>
  control instanceof HTMLInputElement || control instanceof HTMLTextAreaElement ||
  control instanceof HTMLSelectElement)
const companyControlKey = control => JSON.stringify([
  control.tagName, control.type, control.name,
  ["checkbox", "radio"].includes(control.type) ? control.value : "",
])
const companyResetGeneration = form => {
  const value = form.getAttribute("data-company-reset-token")
  return /^(0|[1-9]\d*)$/.test(value) && Number.isSafeInteger(Number(value))
    ? Number(value) : null
}

function resetCompanyControls(form, freshForm) {
  const freshControls = new Map(companyControls(freshForm).map(control =>
    [companyControlKey(control), control]))

  companyControls(form).forEach(control => {
    const fresh = freshControls.get(companyControlKey(control))
    if (control instanceof HTMLSelectElement) {
      Array.from(control.options).forEach(option => {
        const freshOption = fresh && Array.from(fresh.options).find(item => item.value === option.value)
        option.defaultSelected = Boolean(freshOption?.defaultSelected)
        option.selected = Boolean(freshOption?.selected)
      })
      if (!fresh || !Array.from(control.options).some(option => option.selected)) {
        control.selectedIndex = -1
      }
    } else {
      control.defaultValue = fresh?.value ?? ""
      control.value = fresh?.value ?? ""
      if (control instanceof HTMLInputElement) {
        control.defaultChecked = Boolean(fresh?.checked)
        control.checked = Boolean(fresh?.checked)
      }
    }
  })
  form.setAttribute("data-company-reset-token", freshForm.getAttribute("data-company-reset-token"))
}

function resetCompanyFormBeforePatch(fromEl, toEl) {
  if (!(fromEl instanceof HTMLFormElement) || !(toEl instanceof HTMLFormElement) ||
      !companyFormIds.has(fromEl.id) || fromEl.id !== toEl.id) return

  const previous = companyResetGeneration(fromEl)
  const next = companyResetGeneration(toEl)
  if (previous === null || next === null || next <= previous) return

  // LiveView may supply a locked private clone; erase the connected form too.
  const connected = document.getElementById(fromEl.id)
  resetCompanyControls(fromEl, toEl)
  if (connected instanceof HTMLFormElement && connected !== fromEl) {
    resetCompanyControls(connected, toEl)
  }
}

const buildFormGeneration = form => {
  const value = form.getAttribute("data-build-generation")
  return typeof value === "string" && value.length === 36 &&
    /^[0-9a-f]{8}-[0-9a-f]{4}-[0-9a-f]{4}-[0-9a-f]{4}-[0-9a-f]{12}$/.test(value)
    ? value : null
}

function resetBuildFormBeforePatch(fromEl, toEl) {
  if (!(fromEl instanceof HTMLFormElement) || !(toEl instanceof HTMLFormElement) ||
      fromEl.id !== "build-form" || toEl.id !== "build-form") return

  const previous = buildFormGeneration(fromEl)
  const next = buildFormGeneration(toEl)
  if (previous === null || next === null || previous === next) return

  const connected = document.getElementById("build-form")
  resetCompanyControls(fromEl, toEl)
  fromEl.setAttribute("data-build-generation", next)
  if (connected instanceof HTMLFormElement && connected !== fromEl) {
    resetCompanyControls(connected, toEl)
    connected.setAttribute("data-build-generation", next)
  }
}

const csrfToken = document.querySelector("meta[name='csrf-token']").getAttribute("content")
const liveSocket = new LiveSocket("/live", Socket, {
  longPollFallbackMs: 2500,
  params: {_csrf_token: csrfToken},
  hooks: {...colocatedHooks},
  dom: {onBeforeElUpdated(fromEl, toEl) {
    resetCompanyFormBeforePatch(fromEl, toEl)
    resetBuildFormBeforePatch(fromEl, toEl)
  }},
})

// Show progress bar on live navigation and form submits
topbar.config({barColors: {0: "#29d"}, shadowColor: "rgba(0, 0, 0, .3)"})
window.addEventListener("phx:page-loading-start", _info => topbar.show(300))
window.addEventListener("phx:page-loading-stop", _info => topbar.hide())
window.addEventListener("phx:chat-clear-composer", () => {
  const input = document.getElementById("chat-question")
  if (input) input.value = ""
})
window.addEventListener("phx:chat-restore-composer", ({detail}) => {
  const input = document.getElementById("chat-question")
  if (input) input.value = detail.question
})

// Server-directed Company navigation uses fixed destinations after the DOM patch.
const companyFocusTargets = new Set([
  "company-profile-name", "company-repository-identity", "company-project-name",
  "company-review-evidence", "company-plan-name", "company-plan-review-step",
  "company-build-step", "company-toggle-profile", "company-toggle-repository",
  "company-toggle-project", "company-toggle-evidence", "company-toggle-plan",
  "company-toggle-review", "company-toggle-build", "company-profile-error",
  "company-repository-error", "company-project-error", "company-evidence-error",
  "company-plan-error", "company-review-error", "company-build-error",
  "company-guide-project", "evidence-panel", "connections-panel", "goals-panel",
  "package-panel", "evaluations-panel", "releases-panel", "company-panel",
  "company-toggle-analysis", "company-analysis-project", "company-analysis-error",
  "company-analysis-result", "company-analysis-review",
  "company-assessment-start", "company-assessment-goal", "company-assessment-task",
  "company-assessment-error", "company-assessment-frozen", "company-assessment-results",
  "company-assessment-receipt", "company-assessment-departure", "company-toggle-assessment",
  "corpus-results", "corpus-passage", "corpus-error", "corpus-notice",
  "corpus-original-report-title", "source-snapshots", "source-opened-passage",
  "company-corpus-results", "company-corpus-error", "company-corpus-exact-passage",
  "company-corpus-synthesis-title", "company-corpus-proposal", "company-corpus-question-text",
  "company-corpus-pipeline-title",
])
window.addEventListener("phx:company-focus", ({detail}) => {
  const id = detail?.id
  if (!companyFocusTargets.has(id)) return

  requestAnimationFrame(() => {
    const destination = document.getElementById(id)
    // The explicit saved-project action reveals only its own native disclosure.
    if (id === "company-guide-project") {
      const context = destination?.closest("details#company-guide-context")
      if (context instanceof HTMLDetailsElement) context.open = true
    }
    if (destination && destination.getClientRects().length > 0) destination.focus()
  })
})

// Export focus belongs only to the current, visible package outcome.
window.addEventListener("phx:package-export-focus", ({detail}) => {
  if (!detail || typeof detail !== "object" || Array.isArray(detail) ||
      Object.keys(detail).sort().join(",") !== "digest,generation,kind") return

  const {kind, digest, generation} = detail
  if (!["target", "result"].includes(kind) ||
      typeof digest !== "string" || digest.length !== 64 || !/^[0-9a-f]{64}$/.test(digest) ||
      typeof generation !== "string" || generation.length !== 36 ||
      !/^[0-9a-f]{8}-[0-9a-f]{4}-[0-9a-f]{4}-[0-9a-f]{4}-[0-9a-f]{12}$/.test(generation)) return

  requestAnimationFrame(() => {
    const panel = document.getElementById("package-panel")
    const row = document.getElementById("artifact-" + digest)
    const destination = document.getElementById(
      "package-export-" + kind + "-" + generation + "-" + digest)
    if (!(panel instanceof HTMLElement) || !panel.isConnected ||
        panel.dataset.exportGeneration !== generation || panel.getClientRects().length === 0 ||
        getComputedStyle(panel).visibility !== "visible" ||
        !(row instanceof HTMLElement) || !panel.contains(row) ||
        row.dataset.exportDigest !== digest || row.dataset.exportActive !== "true" ||
        row.dataset.exportFocusKind !== kind ||
        !(destination instanceof HTMLElement) || !row.contains(destination) ||
        !destination.isConnected || destination.getClientRects().length === 0 ||
        destination.closest("[hidden], [inert], [aria-hidden='true']") ||
        getComputedStyle(destination).visibility !== "visible") return

    const expectedControl = kind === "target"
      ? destination instanceof HTMLInputElement && destination.name === "export[target]" &&
        destination.type === "text" && !destination.disabled
      : destination.getAttribute("role") === "status" && destination.tabIndex === -1
    if (expectedControl) destination.focus()
  })
})

// Build correction focus belongs to one current, visible refusal.
let focusedBuildGeneration = null
window.addEventListener("phx:package-build-focus", ({detail}) => {
  if (!detail || typeof detail !== "object" || Array.isArray(detail) ||
      Object.keys(detail).sort().join(",") !== "generation,kind" || detail.kind !== "name") return

  const {generation} = detail
  if (typeof generation !== "string" || generation.length !== 36 ||
      !/^[0-9a-f]{8}-[0-9a-f]{4}-[0-9a-f]{4}-[0-9a-f]{4}-[0-9a-f]{12}$/.test(generation)) return

  requestAnimationFrame(() => {
    const panel = document.getElementById("package-panel")
    const form = document.getElementById("build-form")
    const input = document.getElementById("package-name")
    if (focusedBuildGeneration === generation ||
        !(panel instanceof HTMLElement) || !panel.isConnected ||
        panel.getClientRects().length === 0 || getComputedStyle(panel).visibility !== "visible" ||
        !(form instanceof HTMLFormElement) || !form.isConnected || !panel.contains(form) ||
        form.dataset.buildGeneration !== generation || form.dataset.buildOutcome !== "name" ||
        form.getClientRects().length === 0 || getComputedStyle(form).visibility !== "visible" ||
        !(input instanceof HTMLInputElement) || !form.contains(input) || !input.isConnected ||
        input.name !== "package[name]" || input.type !== "text" || input.disabled ||
        input.getClientRects().length === 0 ||
        input.closest("[hidden], [inert], [aria-hidden='true']") ||
        getComputedStyle(input).visibility !== "visible") return

    focusedBuildGeneration = generation
    input.focus()
  })
})

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
    let keyDown
    window.addEventListener("keydown", e => keyDown = e.key)
    window.addEventListener("keyup", _e => keyDown = null)
    window.addEventListener("click", e => {
      if(keyDown === "c"){
        e.preventDefault()
        e.stopImmediatePropagation()
        reloader.openEditorAtCaller(e.target)
      } else if(keyDown === "d"){
        e.preventDefault()
        e.stopImmediatePropagation()
        reloader.openEditorAtDef(e.target)
      }
    }, true)

    window.liveReloader = reloader
  })
}

