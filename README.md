# matrix-rain-mac

Turn your **live macOS screen** into _Matrix_ digital rain on a vintage 80's CRT — a real-time, click-through overlay that recolors whatever's actually on screen into green phosphor, rains glyphs into the blank areas, and wraps it all in scanlines, glow, and curvature.

![Matrix Rain — live demo](docs/demo.gif)

_Recorded live from a real screen (2× speed). ▶ [Full-quality video](docs/demo.mp4)._

> **Forked from [fchughes/Visor](https://github.com/fchughes/Visor).** Visor supplied the hard plumbing — ScreenCaptureKit → Metal → a click-through full-screen overlay, with screen-recording permission handling. This fork swaps the shader for a content-aware Matrix effect and adds live tuning plus a round of performance work.

> ⚠️ **Entirely vibe-coded by Claude.** Every line of this fork — the shaders, the capture wiring, the performance optimization, and this README — was written by Claude (Anthropic) through conversation, with a human only steering and eyeballing the output. There was no manual code review of the implementation. Calibrate your trust accordingly.

## What it does

- **Content-aware rain** — a per-cell "busyness" mask detects flat/blank regions of the screen; rain only falls there, so your text, icons, and images stay legible and shine through.
- **Green phosphor recolor** — everything on screen is mapped to a strict green/black/white phosphor ramp; bright highlights bloom toward white.
- **Authentic digital rain** — falling katakana streams with a bright leading glyph, exponential trailing fade, per-cell glyph flicker, and varied speed/length. Contrast adapts to the background (bright green on dark areas, dark ink on light ones).
- **80's CRT pass** — scanlines, phosphor glow/bloom, barrel curvature, vignette, interlace flicker, a slow rolling "hum" bar, and a sync-roll glitch when you switch Spaces.
- **Interactive touches** — curvature flattens near the screen corners while the mouse is there (so edge clicks line up with reality), plus an optional rain-clear "bubble" that follows the cursor.
- **Live tuning** — a settings panel with sliders for every parameter (frame rate, rain density, glyph size, glow, scanlines, curvature, contrast, …) and real on/off toggles for Rain and Glow.

## How it works

```
ScreenCaptureKit frame (IOSurface)
  → Pass 0  mask     per-cell "busyness" mask (where is the screen flat vs. busy?)
  → Pass 1  matrix   green phosphor recolor + content-aware falling-glyph rain
  → Pass 2  crt      scanlines · glow · curvature · vignette · roll
  → click-through overlay window (excluded from capture, so it never films itself)
```

Three Metal compute shaders run per frame. The overlay is a borderless, click-through `NSPanel` pinned above the menu bar across all Spaces, with `sharingType = .none` so the effect never captures its own output (which would create a runaway feedback "wormhole"). The renderer runs on its own clock and reuses the latest captured frame between captures, so the rain animates smoothly even on a static screen.

## Performance

The effect was profiled and optimized down to roughly **half** its original cost:

|                | Original (60 fps) | Optimized (24 fps) |
| -------------- | ----------------- | ------------------ |
| CPU over idle  | ~+50% of a core   | **~+29%**          |
| GPU over idle  | ~+46%             | **~+21%**          |

Key wins:

- **Frame rate 60 → 24 fps** (render _and_ capture) — the single biggest lever, since the dominant cost is WindowServer copying the whole screen each frame. Live-tunable from 1–60.
- **Busyness-mask prepass** — the mask used to be a 36-tap loop _per pixel_; it now runs once per mask-cell into a small texture.
- **Real effect toggles** — turning Rain or Glow off actually _skips the work_ (the per-pixel rain loop / the 9-tap bloom) rather than just blanking the output.
- Stopped a 3-second content-refresh timer from polling while the overlay is running.

Measured with `top` (CPU) and `ioreg` GPU utilization, relative to an idle baseline. Interestingly, the individual visual effects turned out _not_ to be meaningful battery levers — the cost is dominated by the screen capture itself, which only frame rate reduces.

## Requirements

- macOS 12.3 or later (Apple Silicon or Intel)
- Screen Recording permission (System Settings → Privacy & Security → Screen Recording)

## Installation & usage

1. Open `Visor.xcodeproj` in Xcode and run (the scheme is `CaptureSample`).
2. A square icon appears in the menu bar. Click it, then:
   - **Visor Down** — start the effect
   - **Visor Up** — stop it
   - **Matrix Settings…** — open the live tuning panel
3. The first run prompts for **Screen Recording** permission, which is required.

Depending on your macOS version and resolution, you may need to adjust **Top Spacing** in Settings to account for the menu-bar height.

## Credits

- Forked from **[fchughes/Visor](https://github.com/fchughes/Visor)** (itself based on Apple's ScreenCaptureKit sample code).
- Matrix effect, performance work, and documentation: **Claude (Anthropic)**, driven by [@bendytree](https://github.com/bendytree).

## License

MIT — see [LICENSE](LICENSE) (inherited from the upstream Apple sample / Visor).
