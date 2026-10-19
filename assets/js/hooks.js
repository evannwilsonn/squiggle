// Browser side of a Squiggle room.
//
// Sketchpad: the drawing surface. Strokes live in a 1000 x 1000 coordinate space so every screen
// size sees the same picture. The drawer's points go to the server in small batches; everyone
// else draws what the server relays. While the drawer draws, the pad also makes a 28 x 28 copy
// of the sketch prepared the way Quick, Draw! doodles were (cropped to the ink, scaled to fill
// the frame, centred, white on black) and sends it for the network to guess at.

const SIZE = 1000
const PEN = 9           // pen width, in the 1000-unit space
const FLUSH_MS = 40     // how often the drawer's new points are sent
const LOOK_MS = 450     // how often the network gets a fresh look while the drawing changes

const ink = () => getComputedStyle(document.documentElement).getPropertyValue("--graphite").trim() || "#2b2b2e"

export const Sketchpad = {
  mounted() {
    this.canvas = this.el.querySelector("canvas")
    this.ctx = this.canvas.getContext("2d")
    this.strokes = new Map()   // id -> [x0, y0, x1, y1, ...]
    this.pending = null        // {s, p} not yet sent
    this.current = null
    this.dirty = false

    this.resize = () => {
      const box = this.canvas.parentElement.getBoundingClientRect()
      const dpr = window.devicePixelRatio || 1
      this.canvas.width = Math.round(box.width * dpr)
      this.canvas.height = Math.round(box.width * dpr)
      this.repaint()
    }
    this.observer = new ResizeObserver(this.resize)
    this.observer.observe(this.canvas.parentElement)
    this.theme = new MutationObserver(() => this.repaint())
    this.theme.observe(document.documentElement, {attributes: true, attributeFilter: ["data-theme"]})

    this.handleEvent("redraw", ({strokes}) => {
      this.strokes = new Map(Object.entries(strokes).map(([k, v]) => [Number(k), v]))
      this.current = null
      this.pending = null
      this.dirty = true
      this.repaint()
    })
    this.handleEvent("ink", ({s, p}) => this.append(s, p))

    const point = (e) => {
      const r = this.canvas.getBoundingClientRect()
      const clamp = (v) => Math.max(0, Math.min(SIZE, Math.round(v)))
      return [clamp((e.clientX - r.left) / r.width * SIZE), clamp((e.clientY - r.top) / r.height * SIZE)]
    }

    this.canvas.addEventListener("pointerdown", (e) => {
      if (!this.drawer()) return
      e.preventDefault()
      this.canvas.setPointerCapture(e.pointerId)
      const id = this.strokes.size ? Math.max(...this.strokes.keys()) + 1 : 0
      if (id >= 1000) return
      this.current = id
      this.queue(id, point(e))
    })
    this.canvas.addEventListener("pointermove", (e) => {
      if (this.current === null || !this.drawer()) return
      const events = e.getCoalescedEvents ? e.getCoalescedEvents() : [e]
      for (const ev of events) {
        const [x, y] = point(ev)
        const pts = this.strokes.get(this.current)
        if (Math.hypot(x - pts[pts.length - 2], y - pts[pts.length - 1]) >= 4) this.queue(this.current, [x, y])
      }
    })
    const end = () => { this.current = null; this.flush() }
    this.canvas.addEventListener("pointerup", end)
    this.canvas.addEventListener("pointercancel", end)

    this.flusher = setInterval(() => this.flush(), FLUSH_MS)
    this.looker = setInterval(() => this.look(), LOOK_MS)
    this.resize()
    this.updated()
  },

  updated() {
    this.canvas.style.cursor = this.drawer() ? "crosshair" : "default"
  },

  destroyed() {
    clearInterval(this.flusher)
    clearInterval(this.looker)
    this.observer.disconnect()
    this.theme.disconnect()
  },

  drawer() { return this.el.dataset.drawer === "true" },

  queue(id, [x, y]) {
    this.append(id, [x, y])
    if (!this.pending || this.pending.s !== id) { this.flush(); this.pending = {s: id, p: []} }
    this.pending.p.push(x, y)
  },

  flush() {
    if (!this.pending || this.pending.p.length === 0) return
    this.pushEvent("ink", this.pending)
    this.pending = {s: this.pending.s, p: []}
  },

  append(id, p) {
    const pts = this.strokes.get(id) || []
    const from = pts.length
    pts.push(...p)
    this.strokes.set(id, pts)
    this.dirty = true
    this.paint(pts, Math.max(0, from - 2))
  },

  repaint() {
    const {ctx, canvas} = this
    ctx.clearRect(0, 0, canvas.width, canvas.height)
    for (const pts of this.strokes.values()) this.paint(pts, 0)
  },

  // Draws a stroke from point index `from` on.
  paint(pts, from) {
    const {ctx, canvas} = this
    const k = canvas.width / SIZE
    ctx.strokeStyle = ctx.fillStyle = ink()
    ctx.lineWidth = PEN * k
    ctx.lineCap = "round"
    ctx.lineJoin = "round"
    if (pts.length === 2) {
      ctx.beginPath()
      ctx.arc(pts[0] * k, pts[1] * k, PEN * k / 2, 0, Math.PI * 2)
      ctx.fill()
      return
    }
    ctx.beginPath()
    ctx.moveTo(pts[from] * k, pts[from + 1] * k)
    for (let i = from + 2; i < pts.length; i += 2) ctx.lineTo(pts[i] * k, pts[i + 1] * k)
    ctx.stroke()
  },

  look() {
    if (!this.drawer() || !this.dirty) return
    this.dirty = false
    const px = rasterize(this.strokes)
    if (px) this.pushEvent("look", {px})
  },
}

// The drawing as Quick, Draw!'s 28 x 28 bitmaps have it: cropped to the ink, scaled so the longer
// side fills the frame (with a small margin), centred, thick white lines on black, then shrunk in
// steps so thin lines survive. Returns base64 of 784 bytes, or null for an empty page.
export function rasterize(strokes) {
  let minX = Infinity, minY = Infinity, maxX = -Infinity, maxY = -Infinity
  for (const pts of strokes.values()) {
    for (let i = 0; i < pts.length; i += 2) {
      minX = Math.min(minX, pts[i]); maxX = Math.max(maxX, pts[i])
      minY = Math.min(minY, pts[i + 1]); maxY = Math.max(maxY, pts[i + 1])
    }
  }
  if (minX === Infinity) return null

  const big = 256, fill = 228, line = 20
  const k = fill / Math.max(maxX - minX, maxY - minY, 1)
  const ox = (big - (maxX - minX) * k) / 2, oy = (big - (maxY - minY) * k) / 2

  const a = document.createElement("canvas")
  a.width = a.height = big
  const c = a.getContext("2d")
  c.fillStyle = "#000"; c.fillRect(0, 0, big, big)
  c.strokeStyle = c.fillStyle = "#fff"
  c.lineWidth = line; c.lineCap = "round"; c.lineJoin = "round"
  for (const pts of strokes.values()) {
    const X = (i) => ox + (pts[i] - minX) * k, Y = (i) => oy + (pts[i + 1] - minY) * k
    c.beginPath()
    if (pts.length === 2) { c.arc(X(0), Y(0), line / 2, 0, Math.PI * 2); c.fill(); continue }
    c.moveTo(X(0), Y(0))
    for (let i = 2; i < pts.length; i += 2) c.lineTo(X(i), Y(i))
    c.stroke()
  }

  let src = a
  for (const size of [128, 56, 28]) {
    const b = document.createElement("canvas")
    b.width = b.height = size
    const bc = b.getContext("2d")
    bc.imageSmoothingEnabled = true
    bc.imageSmoothingQuality = "high"
    bc.drawImage(src, 0, 0, size, size)
    src = b
  }

  const data = src.getContext("2d").getImageData(0, 0, 28, 28).data
  let bin = ""
  for (let i = 0; i < data.length; i += 4) bin += String.fromCharCode(data[i])
  return btoa(bin)
}

// Counts down locally from the server's "milliseconds left" each time the round or phase changes.
export const Clock = {
  mounted() { this.start(); this.timer = setInterval(() => this.tick(), 250) },
  updated() { if (this.el.dataset.key !== this.key) this.start() },
  destroyed() { clearInterval(this.timer) },
  start() {
    this.key = this.el.dataset.key
    this.until = performance.now() + Number(this.el.dataset.left)
    this.tick()
  },
  tick() {
    const s = Math.max(0, Math.ceil((this.until - performance.now()) / 1000))
    this.el.textContent = s
    this.el.classList.toggle("low", s <= 10)
  },
}

// Keeps the chat scrolled to the newest line unless the reader has scrolled up.
export const StickToBottom = {
  mounted() { this.el.scrollTop = this.el.scrollHeight },
  beforeUpdate() { this.atBottom = this.el.scrollHeight - this.el.scrollTop - this.el.clientHeight < 40 },
  updated() { if (this.atBottom) this.el.scrollTop = this.el.scrollHeight },
}
