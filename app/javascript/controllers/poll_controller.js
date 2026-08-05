import { Controller } from "@hotwired/stimulus"

// Reloads a Turbo Frame on an interval while a run is in progress.
//
// Polling rather than a live stream: the runner is a plain HTTP service with no
// websocket, and a load test's status changes on the order of seconds. Adding a
// streaming transport here would be more machinery than the problem needs.
//
// The interval stops itself once the frame reports the run is no longer running,
// so a finished page does not keep issuing requests forever — and, more to the
// point, does not keep stealing CPU from the load generator it is watching.
export default class extends Controller {
  static values = {
    interval: { type: Number, default: 2000 },
    active: Boolean
  }

  connect() {
    if (this.activeValue) this.start()
  }

  disconnect() {
    this.stop()
  }

  start() {
    this.timer = setInterval(() => this.reload(), this.intervalValue)
  }

  stop() {
    if (this.timer) clearInterval(this.timer)
    this.timer = null
  }

  reload() {
    const frame = this.element.closest("turbo-frame") || this.element
    if (frame && typeof frame.reload === "function") frame.reload()
  }
}
