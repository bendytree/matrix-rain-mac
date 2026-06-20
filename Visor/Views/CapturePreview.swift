import AppKit
import CoreText
import MetalKit
import QuartzCore
import SwiftUI

// MARK: - Tunable parameters (shared Swift/Metal layout: all Float, 4-byte aligned)

struct MatrixUniforms {
    var time: Float = 0
    var resX: Float = 1
    var resY: Float = 1
    var flatThreshold: Float = 0.005
    var rainOpacity: Float = 0.563
    var rainSpeed: Float = 0.306
    var glyphChurn: Float = 2.061
    var cellSize: Float = 40.835       // rain glyph size, pixels
    var scanlineStrength: Float = 0.452
    var glow: Float = 0.999
    var curvature: Float = 0.009
    var contrast: Float = 0.95
    var atlasCols: Float = 8
    var atlasCount: Float = 1
    var maskDebug: Float = 0
    var rainOn: Float = 1
    var maskCell: Float = 60.061
    var rainDensity: Float = 4.165
    var trailLen: Float = 50          // stream length in cells
    var rollOffset: Float = 0         // CRT sync-roll vertical phase
    var rollAmt: Float = 0            // CRT sync-roll glitch intensity (0..1)
    var barSpeed: Float = 0.1         // slow rolling hum-bar speed (0 = off)
    var cursorX: Float = 0
    var cursorY: Float = 0
    var cursorRadius: Float = 0       // rain-clear bubble radius in px (0 = off)
    var glowOn: Float = 1             // 1 = CRT bloom on, 0 = skip the 9-tap bloom
}

/// Live-tunable parameters, bound to the settings sliders and read by the renderer each frame.
final class MatrixParams: ObservableObject {
    @Published var flatThreshold: Float = 0.005
    @Published var rainOpacity: Float = 0.563
    @Published var rainSpeed: Float = 0.306
    @Published var glyphChurn: Float = 2.061
    @Published var cellSize: Float = 40.835  // rain glyph size (px)
    @Published var scanlineStrength: Float = 0.452
    @Published var glow: Float = 0.999
    @Published var curvature: Float = 0.009
    @Published var contrast: Float = 0.95
    @Published var maskCell: Float = 60.061  // mask detail grid (px); smaller = hugs text tighter
    @Published var rainDensity: Float = 4.165 // avg simultaneous drops per column
    @Published var trailLength: Float = 50    // stream length in cells
    @Published var barSpeed: Float = 0.1      // rolling hum-bar speed (0 = off)
    @Published var cursorClear: Float = 0     // rain-clear bubble diameter in points (0 = off)
    @Published var fps: Float = 24            // render + capture frame rate (rain doesn't need 60)
    @Published var rainOn: Bool = true
    @Published var glowOn: Bool = true        // CRT bloom (the expensive 9-tap pass)
    @Published var maskDebug: Bool = false
}

// MARK: - Pass 0: busyness mask prepass  (input -> mask, one thread per mask-cell)

let maskShaderSource = """
#include <metal_stdlib>
using namespace metal;

struct Uniforms {
    float time, resX, resY, flatThreshold, rainOpacity, rainSpeed,
          glyphChurn, cellSize, scanlineStrength, glow, curvature, contrast,
          atlasCols, atlasCount, maskDebug, rainOn, maskCell, rainDensity, trailLen,
          rollOffset, rollAmt, barSpeed, cursorX, cursorY, cursorRadius, glowOn;
};
static inline float luma(float3 c) { return dot(c, float3(0.299, 0.587, 0.114)); }

// One thread per mask-cell. Writes per-cell luma contrast (max-min) so the matrix pass reads a
// single texel instead of re-running this 36-tap loop for every pixel in the cell.
kernel void computeShader(texture2d<float, access::read>  input [[texture(0)]],
                          texture2d<float, access::write> mask  [[texture(1)]],
                          constant Uniforms&              u     [[buffer(0)]],
                          uint2 gid [[thread_position_in_grid]])
{
    uint MW = mask.get_width();
    uint MH = mask.get_height();
    if (gid.x >= MW || gid.y >= MH) return;

    uint W = input.get_width();
    uint H = input.get_height();
    float mcell = max(u.maskCell, 4.0);
    float2 mOrigin = float2(gid) * mcell;
    float mn = 1.0, mx = 0.0;
    const int M = 6;
    for (int sy = 0; sy < M; sy++) {
        for (int sx = 0; sx < M; sx++) {
            float2 sp = mOrigin + (float2(float(sx), float(sy)) + 0.5) / float(M) * mcell;
            uint2 ip = uint2(clamp(sp, float2(0.0), float2(float(W) - 1.0, float(H) - 1.0)));
            float Ls = luma(input.read(ip).rgb);
            mn = min(mn, Ls);
            mx = max(mx, Ls);
        }
    }
    mask.write(float4(mx - mn, 0.0, 0.0, 0.0), gid);
}
"""

// MARK: - Pass 1: matrixify + content-aware rain  (input -> mid)

let matrixShaderSource = """
#include <metal_stdlib>
using namespace metal;

struct Uniforms {
    float time, resX, resY, flatThreshold, rainOpacity, rainSpeed,
          glyphChurn, cellSize, scanlineStrength, glow, curvature, contrast,
          atlasCols, atlasCount, maskDebug, rainOn, maskCell, rainDensity, trailLen,
          rollOffset, rollAmt, barSpeed, cursorX, cursorY, cursorRadius, glowOn;
};

static inline float hash11(float p) {
    p = fract(p * 0.1031);
    p *= p + 33.33;
    p *= p + p;
    return fract(p);
}
static inline float hash21(float2 p) {
    float3 p3 = fract(float3(p.xyx) * 0.1031);
    p3 += dot(p3, p3.yzx + 33.33);
    return fract((p3.x + p3.y) * p3.z);
}
static inline float luma(float3 c) { return dot(c, float3(0.299, 0.587, 0.114)); }

kernel void computeShader(texture2d<float, access::read>   input      [[texture(0)]],
                          texture2d<float, access::write>  output     [[texture(1)]],
                          texture2d<float, access::sample> glyphAtlas [[texture(2)]],
                          texture2d<float, access::read>   mask       [[texture(3)]],
                          constant Uniforms&               u          [[buffer(0)]],
                          uint2 gid [[thread_position_in_grid]])
{
    uint W = input.get_width();
    uint H = input.get_height();
    if (gid.x >= W || gid.y >= H) return;

    float3 c = input.read(gid).rgb;
    float L = luma(c);

    // --- "busyness" mask: precomputed once per mask-cell in the prepass (see maskShader) and
    //     read here as a single texel. Per mask-cell luma contrast (max-min), brightness-
    //     independent: only detail (text, icons, images) reads as busy; plain backgrounds flat. ---
    float mcell = max(u.maskCell, 4.0);
    float range = mask.read(uint2(floor(float2(gid) / mcell))).r;
    float busy = smoothstep(u.flatThreshold, u.flatThreshold * 2.5, range);
    float flat = 1.0 - busy;   // 1 = plain background => rain eligible

    // --- strict green monochrome phosphor ramp ---
    float g = clamp(L * u.contrast, 0.0, 1.0);
    float3 green = float3(0.0, 1.0, 0.25);
    float3 content = green * g;
    content += float3(1.0) * smoothstep(0.78, 1.0, g) * 0.85;   // hot highlights bloom white

    // --- DEBUG: paint rain-eligible (flat) areas pink, draw no rain ---
    if (u.maskDebug > 0.5) {
        float3 pink = float3(1.0, 0.15, 0.85);
        output.write(float4(mix(content, pink, flat * 0.65), 1.0), gid);
        return;
    }

    // --- Matrix digital rain: per-column falling streams (leading glyph brightest, trail fades
    //     up). Skipped entirely when Rain is off, so the per-pixel loop + glyph sample cost nothing. ---
    float intensity = 0.0;           // brightness envelope at this cell (1 = head)
    float headMix = 0.0;             // 1 at the leading glyph (white), 0 up the trail
    float glyph = 0.0;
    if (u.rainOn > 0.5) {
        constexpr sampler smp(filter::linear, address::clamp_to_edge);
        float cell = max(u.cellSize, 4.0);
        float2 cellId = floor(float2(gid) / cell);
        float2 cellUV = fract(float2(gid) / cell);
        float rows = max(u.resY / cell, 1.0);
        float gap = rows * 0.6;          // dark gap between successive streams in a column
        const int MAXDROPS = 12;
        for (int d = 0; d < MAXDROPS; d++) {
            float w = clamp(u.rainDensity - float(d), 0.0, 1.0);
            if (w <= 0.0) break;
            float ds = hash21(float2(cellId.x, float(d) * 37.0));
            float trailLen = u.trailLen * (0.6 + 0.8 * hash11(cellId.x * 1.7 + float(d) * 5.3));
            float total = rows + trailLen + gap;
            float spd = u.rainSpeed * rows * (0.5 + ds);          // rows per second
            float head = fmod(ds * total + u.time * spd, total) - trailLen;
            float dd = head - cellId.y;                            // cells above the head = trail
            if (dd >= 0.0 && dd < trailLen) {
                float b = exp(-dd * (3.5 / trailLen)) * w;         // head brightest, fades up
                if (b > intensity) {
                    intensity = b;
                    headMix = smoothstep(1.5, 0.0, dd);
                }
            }
        }
        // Glyph per cell with per-cell desynchronised flicker (Glyph churn = rate; 0 = static).
        float cellRand = hash21(cellId * 1.31 + 2.0);
        float flick = floor(u.time * u.glyphChurn * (0.4 + cellRand) + cellRand * 13.0);
        float gi = floor(hash21(cellId * 1.13 + flick * 1.7) * u.atlasCount);
        float ac = max(u.atlasCols, 1.0);
        float arows = ceil(u.atlasCount / ac);
        float2 aCell = float2(fmod(gi, ac), floor(gi / ac));
        float2 auv = (aCell + cellUV) / float2(ac, max(arows, 1.0));
        glyph = glyphAtlas.sample(smp, auv).r;
    }

    float lightAmt = smoothstep(0.40, 0.80, g);
    float coverage = glyph * intensity;
    // On light backgrounds lift faint trail coverage so the whole stream applies, not just the head.
    coverage = mix(coverage, pow(coverage, 0.45), lightAmt);
    // Light backgrounds need more ink to darken; boost opacity there but keep it tied to the slider
    // (pow keeps it 0 when the slider is 0, so the head still obeys opacity).
    float opEff = mix(u.rainOpacity, pow(u.rainOpacity, 0.35), lightAmt);
    float ink = coverage * flat * u.rainOn * opEff;
    // Clear bubble around the cursor: fade rain out within the radius.
    if (u.cursorRadius > 0.0) {
        float dc = distance(float2(gid), float2(u.cursorX, u.cursorY));
        ink *= smoothstep(u.cursorRadius * 0.5, u.cursorRadius, dc);
    }

    // Dark bg: bright/saturated green ink painted over the darkness (leading glyph brightest).
    float3 headColor = float3(0.05, 1.30, 0.18);
    float3 brightInk = mix(green, headColor, headMix);
    float3 litDark = mix(content, brightInk, ink);

    // Light bg: ink ABSORBS light (multiplicative darken) so glyphs read clearly dark, tinted
    // green (greener at the leading glyph) rather than going pure black.
    float3 tintLight = mix(float3(0.0, 0.40, 0.09), float3(0.0, 0.85, 0.18), headMix);
    float3 litLight = content * (1.0 - ink * 0.92) + tintLight * ink * 0.35;

    float3 outc = mix(litDark, litLight, lightAmt);
    output.write(float4(outc, 1.0), gid);
}
"""

// MARK: - Pass 2: 80's CRT (mid -> drawable)

let crtShaderSource = """
#include <metal_stdlib>
using namespace metal;

struct Uniforms {
    float time, resX, resY, flatThreshold, rainOpacity, rainSpeed,
          glyphChurn, cellSize, scanlineStrength, glow, curvature, contrast,
          atlasCols, atlasCount, maskDebug, rainOn, maskCell, rainDensity, trailLen,
          rollOffset, rollAmt, barSpeed, cursorX, cursorY, cursorRadius, glowOn;
};

kernel void computeShader(texture2d<float, access::sample> input  [[texture(0)]],
                          texture2d<float, access::write>  output [[texture(1)]],
                          constant Uniforms&               u      [[buffer(0)]],
                          uint2 gid [[thread_position_in_grid]])
{
    uint W = output.get_width();
    uint H = output.get_height();
    if (gid.x >= W || gid.y >= H) return;

    float2 res = float2(W, H);
    float2 uv  = (float2(gid) + 0.5) / res;

    // --- barrel curvature ---
    float2 cc = uv * 2.0 - 1.0;
    float r2 = dot(cc, cc);
    cc *= 1.0 + u.curvature * r2;
    float2 duv = cc * 0.5 + 0.5;

    // --- CRT vertical-hold sync roll (triggered on a Space switch) ---
    if (u.rollAmt > 0.0) {
        duv.x += (fract(sin(uv.y * 130.0 + u.time * 47.0) * 43758.5453) - 0.5) * 0.012 * u.rollAmt; // tearing
        duv.y = fract(duv.y + u.rollOffset);                                                          // vertical roll (wraps)
    }
    if (duv.x < 0.0 || duv.x > 1.0 || duv.y < 0.0 || duv.y > 1.0) {
        output.write(float4(0.0, 0.0, 0.0, 1.0), gid);
        return;
    }

    constexpr sampler smp(filter::linear, address::clamp_to_edge);
    float3 col = input.sample(smp, duv).rgb;

    // --- phosphor glow (3x3) — skipped entirely when Glow is off (saves 9 texture taps/pixel) ---
    if (u.glowOn > 0.5) {
        float2 px = 2.0 / res;
        float3 bloom = float3(0.0);
        for (int dx = -1; dx <= 1; dx++)
            for (int dy = -1; dy <= 1; dy++)
                bloom += input.sample(smp, duv + float2(dx, dy) * px).rgb;
        bloom /= 9.0;
        col += bloom * u.glow;
    }

    // --- scanlines (period ~4px) ---
    float scan = 1.0 - u.scanlineStrength * (0.5 + 0.5 * sin(float(gid.y) * 1.57));
    col *= scan;

    // --- interlace flicker (alternate field per frame) ---
    float field = fmod(fmod(float(gid.y), 2.0) + fmod(floor(u.time * 60.0), 2.0), 2.0);
    col *= 1.0 - 0.05 * field;

    // --- vignette ---
    col *= 1.0 - 0.35 * r2;

    // --- slow rolling horizontal "hum" bar (analog horizontal-hold drift) ---
    if (u.barSpeed > 0.0) {
        float barPos = fract(u.time * u.barSpeed);
        float dist = abs(fract(uv.y - barPos + 0.5) - 0.5);   // wrapped distance from the bar
        col *= 1.0 + 0.12 * smoothstep(0.22, 0.0, dist);      // soft brightening band
        col *= 1.0 - 0.07 * smoothstep(0.02, 0.0, dist);      // thin darker core line
    }

    // --- rolling dark retrace bar at the sync-roll seam ---
    if (u.rollAmt > 0.0) {
        float w = fract(uv.y + u.rollOffset);
        float bar = smoothstep(0.05, 0.0, w) + smoothstep(0.95, 1.0, w);
        col *= 1.0 - 0.8 * bar;
        col += float3(0.1, 0.5, 0.15) * bar * 0.6;   // green retrace glow
    }

    output.write(float4(col, 1.0), gid);
}
"""

struct CapturePreview: NSViewRepresentable {
    var metalView: MetalView

    init() {
        guard let device = MTLCreateSystemDefaultDevice() else {
            fatalError("Device not created. Run on a physical device.")
        }
        metalView = MetalView(frame: .zero, device: device)
    }

    func makeNSView(context: Context) -> NSView { metalView }
    func updateNSView(_ nsView: NSView, context: Context) {}

    func updateFrame(_ frame: CapturedFrame) {
        guard let surface = frame.surface else { return }
        metalView.updateTexture(with: surface)
    }
}

class MetalView: MTKView {
    private var commandQueue: MTLCommandQueue!
    private var maskPipeline: MTLComputePipelineState!
    private var matrixPipeline: MTLComputePipelineState!
    private var crtPipeline: MTLComputePipelineState!

    private var texture: MTLTexture!        // latest captured frame
    private var midTexture: MTLTexture!     // pass-1 output / pass-2 input
    private var maskTexture: MTLTexture!    // pass-0 output: per-cell busyness
    private var maskCols = 0, maskRows = 0
    private var glyphAtlas: MTLTexture!

    let params = MatrixParams()
    private var uniforms = MatrixUniforms()
    private let startTime = CACurrentMediaTime()
    // Corner warp: flat (no curvature) while the cursor is near a corner, bulge otherwise.
    private var lastCornerTime: CFTimeInterval = -10
    private var warpFactor: Float = 1   // 1 = warped, 0 = flat (cursor near a corner)
    private var rollStartTime: CFTimeInterval = -10   // CRT sync-roll trigger time

    required init(coder: NSCoder) {
        super.init(coder: coder)
        guard let device = MTLCreateSystemDefaultDevice() else {
            fatalError("Device not created. Run on a physical device.")
        }
        self.device = device
        commonInit(device)
    }

    override init(frame frameRect: CGRect, device: MTLDevice?) {
        super.init(frame: frameRect, device: device)
        guard let device = device else {
            fatalError("Device not created. Run on a physical device.")
        }
        self.device = device
        commonInit(device)
    }

    private func commonInit(_ device: MTLDevice) {
        clearColor = MTLClearColor(red: 0, green: 0, blue: 0, alpha: 1)
        colorPixelFormat = .bgra8Unorm
        framebufferOnly = false
        autoResizeDrawable = false
        // Self-driven clock so the rain animates even when the screen is static.
        // Rate is driven live from params.fps in draw(); start at that default.
        isPaused = false
        enableSetNeedsDisplay = false
        preferredFramesPerSecond = max(1, Int(params.fps.rounded()))

        commandQueue = device.makeCommandQueue()
        glyphAtlas = MetalView.makeGlyphAtlas(device: device, uniforms: &uniforms)
        maskPipeline = MetalView.makePipeline(device: device, source: maskShaderSource)
        matrixPipeline = MetalView.makePipeline(device: device, source: matrixShaderSource)
        crtPipeline = MetalView.makePipeline(device: device, source: crtShaderSource)
        NSWorkspace.shared.notificationCenter.addObserver(
            self, selector: #selector(spaceChangedRoll),
            name: NSWorkspace.activeSpaceDidChangeNotification, object: nil)
    }

    deinit { NSWorkspace.shared.notificationCenter.removeObserver(self) }

    @objc private func spaceChangedRoll() { rollStartTime = CACurrentMediaTime() }

    private static func makePipeline(device: MTLDevice, source: String) -> MTLComputePipelineState? {
        do {
            let lib = try device.makeLibrary(source: source, options: nil)
            guard let fn = lib.makeFunction(name: "computeShader") else { return nil }
            return try device.makeComputePipelineState(function: fn)
        } catch {
            print("Failed to create pipeline: \(error)")
            return nil
        }
    }

    /// Lets the "Select Shader" picker hot-swap the matrix (pass-1) shader.
    func updateShader(shaderPath: String) {
        guard let device = device,
              let src = try? String(contentsOfFile: shaderPath, encoding: .utf8),
              let pipeline = MetalView.makePipeline(device: device, source: src) else { return }
        matrixPipeline = pipeline
    }

    func updateTexture(with surface: IOSurface) {
        guard let device = device else { return }
        let w = IOSurfaceGetWidth(surface)
        let h = IOSurfaceGetHeight(surface)
        let descriptor = MTLTextureDescriptor.texture2DDescriptor(
            pixelFormat: .bgra8Unorm, width: w, height: h, mipmapped: false)
        descriptor.usage = [.shaderRead, .shaderWrite]
        guard let tex = device.makeTexture(descriptor: descriptor, iosurface: surface, plane: 0) else {
            print("Could not create texture from IOSurface.")
            return
        }
        texture = tex
        drawableSize = CGSize(width: w, height: h)
        uniforms.resX = Float(w)
        uniforms.resY = Float(h)
        ensureMidTexture(width: w, height: h)
    }

    private func ensureMidTexture(width: Int, height: Int) {
        if let m = midTexture, m.width == width, m.height == height { return }
        guard let device = device else { return }
        let d = MTLTextureDescriptor.texture2DDescriptor(
            pixelFormat: .rgba16Float, width: width, height: height, mipmapped: false)
        d.usage = [.shaderRead, .shaderWrite]
        d.storageMode = .private
        midTexture = device.makeTexture(descriptor: d)
    }

    /// Allocates the small per-cell mask texture (one texel per mask-cell). Resizes when the
    /// frame size or the live-tunable mask-cell size changes.
    private func ensureMaskTexture(width: Int, height: Int, mcell: Float) {
        let m = max(mcell, 4)
        let cols = Int((Float(width) / m).rounded(.up))
        let rows = Int((Float(height) / m).rounded(.up))
        if maskTexture != nil, maskCols == cols, maskRows == rows { return }
        guard let device = device, cols > 0, rows > 0 else { return }
        let d = MTLTextureDescriptor.texture2DDescriptor(
            pixelFormat: .r16Float, width: cols, height: rows, mipmapped: false)
        d.usage = [.shaderRead, .shaderWrite]
        d.storageMode = .private
        maskTexture = device.makeTexture(descriptor: d)
        maskCols = cols; maskRows = rows
    }

    override func draw(_ dirtyRect: CGRect) {
        super.draw(dirtyRect)
        // Live render-rate control (the rain animates fine well below 60fps).
        let targetFPS = max(1, Int(params.fps.rounded()))
        if preferredFramesPerSecond != targetFPS { preferredFramesPerSecond = targetFPS }
        guard let texture = texture,
              let midTexture = midTexture,
              let maskPipeline = maskPipeline,
              let matrixPipeline = matrixPipeline,
              let crtPipeline = crtPipeline,
              let drawable = currentDrawable,
              let commandBuffer = commandQueue?.makeCommandBuffer()
        else { return }

        uniforms.time = Float(CACurrentMediaTime() - startTime)
        uniforms.flatThreshold = params.flatThreshold
        uniforms.rainOpacity = params.rainOpacity
        uniforms.rainSpeed = params.rainSpeed
        uniforms.glyphChurn = params.glyphChurn
        uniforms.cellSize = params.cellSize
        uniforms.scanlineStrength = params.scanlineStrength
        uniforms.glow = params.glow
        uniforms.curvature = params.curvature
        uniforms.contrast = params.contrast
        uniforms.maskCell = params.maskCell
        uniforms.rainDensity = params.rainDensity
        uniforms.trailLen = params.trailLength
        uniforms.barSpeed = params.barSpeed
        uniforms.rainOn = params.rainOn ? 1 : 0
        uniforms.glowOn = params.glowOn ? 1 : 0
        uniforms.maskDebug = params.maskDebug ? 1 : 0

        // Warp only when the mouse is idle: flatten while moving (+1s debounce), bulge when still.
        // Un-warp while the cursor is near a corner (within 10% on both axes) — corners are where
        // barrel distortion shifts the visible position the most. Re-warps ~1s after it leaves.
        if let f = window?.screen?.frame ?? NSScreen.main?.frame {
            let mp = NSEvent.mouseLocation
            let nx = (mp.x - f.minX) / f.width, ny = (mp.y - f.minY) / f.height
            if min(nx, 1 - nx) < 0.18 && min(ny, 1 - ny) < 0.18 {
                lastCornerTime = CACurrentMediaTime()
            }
        }
        let warpTarget: Float = (CACurrentMediaTime() - lastCornerTime) >= 1.5 ? 1.0 : 0.0
        warpFactor += (warpTarget - warpFactor) * (warpTarget < warpFactor ? 0.30 : 0.10)  // fast to flatten, smooth to bulge
        uniforms.curvature = params.curvature * warpFactor

        // Rain-clear bubble around the cursor (diameter in points -> radius in capture pixels).
        if params.cursorClear > 0, let f = window?.screen?.frame ?? NSScreen.main?.frame, f.width > 0 {
            let mp = NSEvent.mouseLocation
            uniforms.cursorX = Float((mp.x - f.minX) / f.width) * uniforms.resX
            uniforms.cursorY = Float(1 - (mp.y - f.minY) / f.height) * uniforms.resY   // flip y (screen up -> texture down)
            uniforms.cursorRadius = params.cursorClear * 0.5 * (uniforms.resX / Float(f.width))
        } else {
            uniforms.cursorRadius = 0
        }

        // Sync-roll glitch on Space switch: ~2 fast vertical rolls that ease out and lock back in.
        let rollElapsed = CACurrentMediaTime() - rollStartTime
        if rollElapsed < 0.55 {
            let t = Float(rollElapsed / 0.55)
            uniforms.rollOffset = 2.0 * (1.0 - (1.0 - t) * (1.0 - t))  // ease-out: 0 -> 2 rolls
            uniforms.rollAmt = 1.0 - t                                  // glitch intensity fades out
        } else {
            uniforms.rollOffset = 0
            uniforms.rollAmt = 0
        }

        ensureMaskTexture(width: texture.width, height: texture.height, mcell: uniforms.maskCell)
        guard let maskTexture = maskTexture else { return }

        let tg = MTLSizeMake(16, 16, 1)
        let groups = MTLSizeMake((texture.width + 15) / 16, (texture.height + 15) / 16, 1)

        // Pass 0: input -> mask (one thread per mask-cell)
        if let e0 = commandBuffer.makeComputeCommandEncoder() {
            e0.setComputePipelineState(maskPipeline)
            e0.setTexture(texture, index: 0)
            e0.setTexture(maskTexture, index: 1)
            e0.setBytes(&uniforms, length: MemoryLayout<MatrixUniforms>.stride, index: 0)
            let mtg = MTLSizeMake(8, 8, 1)
            let mgroups = MTLSizeMake((maskCols + 7) / 8, (maskRows + 7) / 8, 1)
            e0.dispatchThreadgroups(mgroups, threadsPerThreadgroup: mtg)
            e0.endEncoding()
        }

        // Pass 1: input -> mid
        if let e1 = commandBuffer.makeComputeCommandEncoder() {
            e1.setComputePipelineState(matrixPipeline)
            e1.setTexture(texture, index: 0)
            e1.setTexture(midTexture, index: 1)
            e1.setTexture(glyphAtlas, index: 2)
            e1.setTexture(maskTexture, index: 3)
            e1.setBytes(&uniforms, length: MemoryLayout<MatrixUniforms>.stride, index: 0)
            e1.dispatchThreadgroups(groups, threadsPerThreadgroup: tg)
            e1.endEncoding()
        }

        // Pass 2: mid -> drawable
        if let e2 = commandBuffer.makeComputeCommandEncoder() {
            e2.setComputePipelineState(crtPipeline)
            e2.setTexture(midTexture, index: 0)
            e2.setTexture(drawable.texture, index: 1)
            e2.setBytes(&uniforms, length: MemoryLayout<MatrixUniforms>.stride, index: 0)
            e2.dispatchThreadgroups(groups, threadsPerThreadgroup: tg)
            e2.endEncoding()
        }

        commandBuffer.present(drawable)
        commandBuffer.commit()
    }

    // MARK: - Glyph atlas (half-width katakana + digits) via CoreText

    private static func makeGlyphAtlas(device: MTLDevice, uniforms: inout MatrixUniforms) -> MTLTexture? {
        var chars: [String] = (0x30A1...0x30F6).compactMap { UnicodeScalar($0).map { String($0) } } // katakana
        chars += (0x30...0x39).compactMap { UnicodeScalar($0).map { String($0) } }                   // digits
        let cols = 12
        let cell = 32
        let rows = (chars.count + cols - 1) / cols
        let w = cols * cell, h = rows * cell

        guard let ctx = CGContext(data: nil, width: w, height: h, bitsPerComponent: 8,
                                  bytesPerRow: 0, space: CGColorSpaceCreateDeviceRGB(),
                                  bitmapInfo: CGImageAlphaInfo.premultipliedLast.rawValue) else { return nil }
        ctx.setFillColor(CGColor(red: 0, green: 0, blue: 0, alpha: 1))
        ctx.fill(CGRect(x: 0, y: 0, width: w, height: h))

        // Draw via AppKit (reliable font fallback / positioning). Menlo lacks katakana, so use
        // Hiragino; NSString.draw handles centering and colour correctly.
        let ns = NSGraphicsContext(cgContext: ctx, flipped: false)
        NSGraphicsContext.current = ns
        let font = NSFont(name: "Hiragino Sans W3", size: CGFloat(cell) * 0.82)
                    ?? NSFont.monospacedSystemFont(ofSize: CGFloat(cell) * 0.82, weight: .regular)
        let attrs: [NSAttributedString.Key: Any] = [.font: font, .foregroundColor: NSColor.white]
        for (i, ch) in chars.enumerated() {
            let col = i % cols, row = i / cols
            let s = ch as NSString
            let sz = s.size(withAttributes: attrs)
            s.draw(at: NSPoint(x: CGFloat(col * cell) + (CGFloat(cell) - sz.width) / 2,
                               y: CGFloat((rows - 1 - row) * cell) + (CGFloat(cell) - sz.height) / 2),
                   withAttributes: attrs)
        }
        NSGraphicsContext.current = nil

        guard let image = ctx.makeImage() else { return nil }
        uniforms.atlasCols = Float(cols)
        uniforms.atlasCount = Float(chars.count)
        return try? MTKTextureLoader(device: device).newTexture(cgImage: image, options: [.SRGB: false])
    }
}
