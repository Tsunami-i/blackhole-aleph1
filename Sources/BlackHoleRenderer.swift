import AppKit
import MetalKit
import CoreGraphics
import ImageIO
import UniformTypeIdentifiers

// MARK: - Uniforms (must match Shaders.metal layout, Metal aligns float3 to 16 bytes)
struct Uniforms {
    var holeRadius: Float    = 0.053
    var lensDepth: Float     = 18.0
    var starGain: Float      = 0.38
    var diskInner: Float     = 2.45
    var diskOuter: Float     = 26.0
    var diskIncl: Float      = 1.42
    var diskRoll: Float      = 0.02
    var diskGain: Float      = 9.25
    var diskOpacity: Float   = 0.82
    var diskTemp: Float      = 9200.0
    var dopplerMix: Float    = 0.22
    var diskBeam: Float      = 1.5
    var diskSpeed: Float     = 1.25
    var diskWind: Float      = 3.2
    var diskContrast: Float  = 1.42
    var exposure: Float      = 1.35
    var driftSpeed: Float    = 1.0
    var workArea: Float      = 0.33
    var dilationMin: Float   = 0.2
    var dilation: Float      = 0.0
    var collapse: Float      = 0.0
    var time: Float          = 0.0
    var animTime: Float      = 0.0
    var aspect: Float        = 1.0
    var center: SIMD2<Float> = SIMD2<Float>(0.5, 0.5)
    var pad1: Float          = 0.0
}

// MARK: - Renderer
class BlackHoleRenderer: NSObject, MTKViewDelegate {
    let device: MTLDevice
    let commandQueue: MTLCommandQueue
    let pipelineState: MTLRenderPipelineState
    let samplerState: MTLSamplerState
    var uniforms: Uniforms
    var screenTexture: MTLTexture?
    var textureLoader: MTKTextureLoader
    var irisPlumeTexture: MTLTexture?
    var slimeTexture: MTLTexture?
    let startTime: CFAbsoluteTime
    let isDemo: Bool
    let isManual: Bool
    let delayMinutes: Double
    let overlayDuration: Double?
    let captureDirectory: URL?
    let captureTimes: [Double]
    var lastBackgroundCapture: CFAbsoluteTime = 0
    var effectHasAppeared = false
    var manualStartTime: CFAbsoluteTime?
    var exitStartTime: CFAbsoluteTime?
    var nextCaptureIndex = 0

    var hasTriggered: Bool {
        !isManual || manualStartTime != nil
    }

    init?(device: MTLDevice, view: MTKView, isDemo: Bool, isManual: Bool, delayMinutes: Double, duration: Double?, captureDir: String?, captureTimes: [Double]) {
        self.device = device
        self.isDemo = isDemo
        self.isManual = isManual
        self.delayMinutes = delayMinutes
        self.overlayDuration = duration
        self.startTime = CFAbsoluteTimeGetCurrent()
        if let captureDir, !captureDir.isEmpty {
            let captureURL = URL(fileURLWithPath: captureDir)
            self.captureDirectory = captureURL.isFileURL && captureURL.path.hasPrefix("/")
                ? captureURL
                : URL(fileURLWithPath: FileManager.default.currentDirectoryPath).appendingPathComponent(captureDir)
            try? FileManager.default.createDirectory(at: self.captureDirectory!, withIntermediateDirectories: true)
        } else {
            self.captureDirectory = nil
        }
        self.captureTimes = captureTimes.sorted()

        guard let queue = device.makeCommandQueue() else { return nil }
        self.commandQueue = queue
        self.textureLoader = MTKTextureLoader(device: device)

        // Load shader from embedded source (Metal Shading Language)
        let shaderSource = BlackHoleRenderer.metalShaderSource
        do {
            let library = try device.makeLibrary(source: shaderSource, options: nil)
            guard let vertexFn = library.makeFunction(name: "blackHoleVertex"),
                  let fragmentFn = library.makeFunction(name: "blackHoleFragment") else {
                print("ERROR: Could not find shader functions")
                return nil
            }

            let desc = MTLRenderPipelineDescriptor()
            desc.vertexFunction = vertexFn
            desc.fragmentFunction = fragmentFn
            desc.colorAttachments[0].pixelFormat = view.colorPixelFormat

            self.pipelineState = try device.makeRenderPipelineState(descriptor: desc)
        } catch {
            print("ERROR: Shader/pipeline creation failed: \(error)")
            return nil
        }

        // Sampler
        let samplerDesc = MTLSamplerDescriptor()
        samplerDesc.minFilter = .linear
        samplerDesc.magFilter = .linear
        samplerDesc.sAddressMode = .clampToEdge
        samplerDesc.tAddressMode = .clampToEdge
        guard let sampler = device.makeSamplerState(descriptor: samplerDesc) else { return nil }
        self.samplerState = sampler

        // Load Aleph asset textures from project root Assets/aleph/
        let assetsURL = BlackHoleRenderer.alephAssetsBaseURL()
        self.irisPlumeTexture = BlackHoleRenderer.loadOptionalTexture(loader: textureLoader, url: assetsURL.appendingPathComponent("iris_plume_mask.png"))
        self.slimeTexture = BlackHoleRenderer.loadOptionalTexture(loader: textureLoader, url: assetsURL.appendingPathComponent("slime_mask.png"))
        if irisPlumeTexture == nil { print("INFO: iris_plume_mask.png not loaded — texture layer disabled") }
        if slimeTexture == nil { print("INFO: slime_mask.png not loaded — texture layer disabled") }

        // Init uniforms
        self.uniforms = Uniforms()

        super.init()
        view.delegate = self
        view.framebufferOnly = false
        view.enableSetNeedsDisplay = true
        view.isPaused = true

        captureScreen()
    }

    func triggerManual() {
        guard isManual else { return }
        if manualStartTime == nil {
            captureScreen()
            manualStartTime = CFAbsoluteTimeGetCurrent()
            effectHasAppeared = false
        }
    }

    func requestExitAnimation() {
        if isManual && manualStartTime == nil {
            NSApplication.shared.terminate(nil)
            return
        }

        if exitStartTime == nil {
            exitStartTime = CFAbsoluteTimeGetCurrent()
        }
    }

    // MARK: - Asset texture helpers

    /// Resolve Assets/aleph/ at the project root by walking up from the executable.
    static func alephAssetsBaseURL() -> URL {
        let execPath = CommandLine.arguments[0]
        let execURL = URL(fileURLWithPath: execPath)
        // .build/debug/BlackHoleScreenWarp → .build → project root
        let projectRoot = execURL.deletingLastPathComponent()
            .deletingLastPathComponent()
            .deletingLastPathComponent()
        return projectRoot.appendingPathComponent("Assets/aleph/")
    }

    /// Try to load a texture; return nil on failure (non-fatal).
    static func loadOptionalTexture(loader: MTKTextureLoader, url: URL) -> MTLTexture? {
        guard FileManager.default.fileExists(atPath: url.path) else {
            print("WARNING: Texture not found at \(url.path)")
            return nil
        }
        do {
            return try loader.newTexture(URL: url, options: nil)
        } catch {
            print("WARNING: Failed to load texture \(url.lastPathComponent): \(error)")
            return nil
        }
    }

    func captureScreen() {
        guard let image = CGDisplayCreateImage(CGMainDisplayID()) else {
            print("WARNING: Could not capture screen. Screen Recording permission may be needed.")
            return
        }
        let width = image.width
        let height = image.height
        let rect = CGRect(x: 0, y: 0, width: width, height: height)

        let desc = MTLTextureDescriptor.texture2DDescriptor(
            pixelFormat: .rgba8Unorm,
            width: width,
            height: height,
            mipmapped: false
        )
        desc.usage = .shaderRead

        guard let tex = device.makeTexture(descriptor: desc) else { return }

        let colorSpace = CGColorSpaceCreateDeviceRGB()
        let bytesPerRow = 4 * width
        var data = [UInt8](repeating: 0, count: height * bytesPerRow)

        guard let ctx = CGContext(
            data: &data,
            width: width, height: height,
            bitsPerComponent: 8,
            bytesPerRow: bytesPerRow,
            space: colorSpace,
            bitmapInfo: CGImageAlphaInfo.noneSkipLast.rawValue
        ) else { return }

        ctx.draw(image, in: rect)
        tex.replace(region: MTLRegionMake2D(0, 0, width, height),
                    mipmapLevel: 0, withBytes: data, bytesPerRow: bytesPerRow)
        screenTexture = tex
        uniforms.aspect = Float(width) / Float(height)
        lastBackgroundCapture = CFAbsoluteTimeGetCurrent()
    }

    struct EffectState {
        let dilation: Float
        let collapse: Float
    }

    func outroDuration(totalDuration: Double?) -> Double {
        guard let totalDuration else { return 3.5 }
        return min(max(totalDuration * 0.25, 2.0), 6.0)
    }

    func computeEffectState(now: CFAbsoluteTime) -> EffectState {
        func smoothstep(_ x: Double) -> Double {
            let t = min(max(x, 0.0), 1.0)
            return t * t * (3.0 - 2.0 * t)
        }
        func bell(_ x: Double) -> Double {
            let t = min(max(x, 0.0), 1.0)
            return sin(t * .pi)
        }

        let activeElapsed: Double
        if isManual {
            guard let manualStartTime else {
                return EffectState(dilation: 0.0, collapse: 0.0)
            }
            activeElapsed = now - manualStartTime
        } else {
            let elapsed = now - startTime
            let triggerDelay = isDemo ? 0.0 : delayMinutes * 60.0
            activeElapsed = elapsed - triggerDelay
        }

        if activeElapsed < 0 {
            return EffectState(dilation: 0.0, collapse: 0.0)
        }

        let introDuration = (isDemo || isManual) ? 5.5 : 90.0
        let enterProgress = activeElapsed / introDuration
        let enter = smoothstep(enterProgress)
        var collapse = 0.9 * bell(enterProgress)

        if let exitStartTime {
            let exitProgress = (now - exitStartTime) / outroDuration(totalDuration: nil)
            let exit = 1.0 - smoothstep(exitProgress)
            collapse = max(collapse, 0.85 * bell(exitProgress))
            return EffectState(
                dilation: Float(max(0.0, min(enter * exit, 1.0))),
                collapse: Float(max(0.0, min(collapse, 1.0)))
            )
        }

        if let dur = overlayDuration {
            let timedOutroDuration = outroDuration(totalDuration: dur)
            let outroStart = max(dur - timedOutroDuration, 0.0)
            let exitProgress = activeElapsed >= outroStart
                ? (activeElapsed - outroStart) / timedOutroDuration
                : 0.0
            let exit = activeElapsed >= outroStart
                ? 1.0 - smoothstep(exitProgress)
                : 1.0
            collapse = max(collapse, 0.75 * bell(exitProgress))
            return EffectState(
                dilation: Float(max(0.0, min(enter * exit, 1.0))),
                collapse: Float(max(0.0, min(collapse, 1.0)))
            )
        }

        if isManual || isDemo || delayMinutes > 0 {
            return EffectState(dilation: Float(enter), collapse: Float(max(0.0, min(collapse, 1.0))))
        }
        return EffectState(dilation: 0.0, collapse: 0.0)
    }

    func activeAnimationElapsed(now: CFAbsoluteTime) -> Double {
        if isManual {
            guard let manualStartTime else { return 0.0 }
            return max(0.0, now - manualStartTime)
        }
        let triggerDelay = isDemo ? 0.0 : delayMinutes * 60.0
        return max(0.0, now - startTime - triggerDelay)
    }

    func shouldTerminate(now: CFAbsoluteTime) -> Bool {
        if let exitStartTime, now - exitStartTime >= outroDuration(totalDuration: nil) {
            return true
        }

        if let duration = overlayDuration {
            if isManual {
                guard let manualStartTime else { return false }
                return now - manualStartTime > duration
            }
            return now - startTime > duration
        }

        return false
    }

    func mtkView(_ view: MTKView, drawableSizeWillChange size: CGSize) {
        uniforms.aspect = Float(size.width) / Float(size.height)
    }

    func draw(in view: MTKView) {
        let now = CFAbsoluteTimeGetCurrent()
        let elapsed = now - startTime
        uniforms.time = Float(elapsed)
        uniforms.animTime = Float(activeAnimationElapsed(now: now))
        let state = computeEffectState(now: now)
        uniforms.dilation = state.dilation
        uniforms.collapse = state.collapse
        if uniforms.dilation > 0.001 {
            effectHasAppeared = true
        }

        if shouldTerminate(now: now) {
            NSApplication.shared.terminate(nil)
            return
        }

        // Refresh only before the black hole is visible. Capturing the overlay
        // itself creates feedback silhouettes and stale event-horizon ghosts.
        if !effectHasAppeared && elapsed - lastBackgroundCapture > 3.0 {
            captureScreen()
        }

        guard let drawable = view.currentDrawable,
              let desc = view.currentRenderPassDescriptor,
              let cmdBuf = commandQueue.makeCommandBuffer(),
              let encoder = cmdBuf.makeRenderCommandEncoder(descriptor: desc) else {
            return
        }

        encoder.setRenderPipelineState(pipelineState)
        encoder.setFragmentBytes(&uniforms, length: MemoryLayout<Uniforms>.stride, index: 0)
        encoder.setFragmentTexture(screenTexture, index: 0)
        encoder.setFragmentTexture(irisPlumeTexture, index: 1)
        encoder.setFragmentTexture(slimeTexture, index: 2)
        encoder.setFragmentSamplerState(samplerState, index: 0)
        encoder.drawPrimitives(type: .triangle, vertexStart: 0, vertexCount: 6)
        encoder.endEncoding()

        scheduleFrameCaptureIfNeeded(drawable: drawable, commandBuffer: cmdBuf, animElapsed: Double(uniforms.animTime))

        cmdBuf.present(drawable)
        cmdBuf.commit()

        view.setNeedsDisplay(view.bounds)
    }

    func scheduleFrameCaptureIfNeeded(drawable: CAMetalDrawable, commandBuffer: MTLCommandBuffer, animElapsed: Double) {
        guard let captureDirectory, nextCaptureIndex < captureTimes.count else { return }
        let targetTime = captureTimes[nextCaptureIndex]
        guard animElapsed >= targetTime else { return }

        let texture = drawable.texture
        let width = texture.width
        let height = texture.height
        let bytesPerPixel = 4
        let sourceBytesPerRow = width * bytesPerPixel
        let bytesPerRow = ((sourceBytesPerRow + 255) / 256) * 256
        let byteCount = bytesPerRow * height

        guard let buffer = device.makeBuffer(length: byteCount, options: [.storageModeShared]),
              let blit = commandBuffer.makeBlitCommandEncoder() else {
            print("WARNING: Could not schedule renderer capture at \(targetTime)s.")
            nextCaptureIndex += 1
            return
        }

        blit.copy(
            from: texture,
            sourceSlice: 0,
            sourceLevel: 0,
            sourceOrigin: MTLOrigin(x: 0, y: 0, z: 0),
            sourceSize: MTLSize(width: width, height: height, depth: 1),
            to: buffer,
            destinationOffset: 0,
            destinationBytesPerRow: bytesPerRow,
            destinationBytesPerImage: byteCount
        )
        blit.endEncoding()

        let captureIndex = nextCaptureIndex
        let actualTime = animElapsed
        let fileName = String(format: "frame_%02d_target_%05.2f_actual_%05.2f.png", captureIndex + 1, targetTime, actualTime)
        let outputURL = captureDirectory.appendingPathComponent(fileName)
        nextCaptureIndex += 1

        commandBuffer.addCompletedHandler { _ in
            Self.writeBGRA8PNG(
                buffer: buffer,
                width: width,
                height: height,
                sourceBytesPerRow: bytesPerRow,
                outputURL: outputURL
            )
        }
    }

    static func writeBGRA8PNG(buffer: MTLBuffer, width: Int, height: Int, sourceBytesPerRow: Int, outputURL: URL) {
        let bytesPerPixel = 4
        let destinationBytesPerRow = width * bytesPerPixel
        var pixels = Data(count: destinationBytesPerRow * height)

        pixels.withUnsafeMutableBytes { destination in
            guard let dstBase = destination.baseAddress else { return }
            let srcBase = buffer.contents()
            for y in 0..<height {
                let dst = dstBase.advanced(by: y * destinationBytesPerRow)
                let src = srcBase.advanced(by: y * sourceBytesPerRow)
                memcpy(dst, src, destinationBytesPerRow)
            }
        }

        let colorSpace = CGColorSpaceCreateDeviceRGB()
        let bitmapInfo = CGBitmapInfo.byteOrder32Little.union(
            CGBitmapInfo(rawValue: CGImageAlphaInfo.premultipliedFirst.rawValue)
        )

        guard let provider = CGDataProvider(data: pixels as CFData),
              let image = CGImage(
                  width: width,
                  height: height,
                  bitsPerComponent: 8,
                  bitsPerPixel: 32,
                  bytesPerRow: destinationBytesPerRow,
                  space: colorSpace,
                  bitmapInfo: bitmapInfo,
                  provider: provider,
                  decode: nil,
                  shouldInterpolate: false,
                  intent: .defaultIntent
              ),
              let destination = CGImageDestinationCreateWithURL(outputURL as CFURL, UTType.png.identifier as CFString, 1, nil) else {
            print("WARNING: Could not create renderer capture PNG at \(outputURL.path).")
            return
        }

        CGImageDestinationAddImage(destination, image, nil)
        if CGImageDestinationFinalize(destination) {
            print("Renderer capture: \(outputURL.path)")
        } else {
            print("WARNING: Could not write renderer capture PNG at \(outputURL.path).")
        }
    }

    // MARK: - Embedded Metal Shader Source
    static let metalShaderSource = """
    #include <metal_stdlib>
    using namespace metal;

    struct Uniforms {
        float holeRadius;
        float lensDepth;
        float starGain;
        float diskInner;
        float diskOuter;
        float diskIncl;
        float diskRoll;
        float diskGain;
        float diskOpacity;
        float diskTemp;
        float dopplerMix;
        float diskBeam;
        float diskSpeed;
        float diskWind;
        float diskContrast;
        float exposure;
        float driftSpeed;
        float workArea;
        float dilationMin;
        float dilation;
        float collapse;
        float time;
        float animTime;
        float aspect;
        float2 center;
    };

    #define N_STEPS 48
    #define B_CRIT 2.5980762f
    #define PI      3.14159265f

    // ── helpers ──────────────────────────────────────────────

    float hash21(float2 p) {
        p = fract(p * float2(234.34, 435.345));
        p += dot(p, p + 34.23);
        return fract(p.x * p.y);
    }

    float vnoiseWrapY(float2 p, float perY) {
        float2 i = floor(p);
        float2 f = fract(p);
        f = f * f * (3.0 - 2.0 * f);
        float y0 = fmod(i.y, perY);
        float y1 = fmod(i.y + 1.0, perY);
        return mix(mix(hash21(float2(i.x, y0)), hash21(float2(i.x + 1.0, y0)), f.x),
                   mix(hash21(float2(i.x, y1)), hash21(float2(i.x + 1.0, y1)), f.x), f.y);
    }

    float vnoise(float2 p) {
        float2 i = floor(p);
        float2 f = fract(p);
        f = f * f * (3.0 - 2.0 * f);
        return mix(mix(hash21(i), hash21(i + float2(1.0, 0.0)), f.x),
                   mix(hash21(i + float2(0.0, 1.0)), hash21(i + float2(1.0, 1.0)), f.x), f.y);
    }

    float fbm(float2 p) {
        float val = 0.0, amp = 0.5, freq = 1.0;
        for (int i = 0; i < 4; i++) {
            val += amp * vnoise(p * freq);
            freq *= 2.1;
            amp *= 0.55;
        }
        return val;
    }

    float3 sampleScreen(texture2d<float, access::sample> tex, sampler smp, float2 uv) {
        return tex.sample(smp, clamp(uv, 0.0, 1.0)).rgb;
    }

    float2 rot(float2 v, float a) {
        float c = cos(a), s = sin(a);
        return float2(c * v.x - s * v.y, s * v.x + c * v.y);
    }

    // ── star-field layer (layer 4) ───────────────────────────

    float3 starFieldLayer(float3 d, float time, float starGain) {
        float2 sph = float2(atan2(d.x, -d.z), asin(clamp(d.y, -1.0, 1.0)));
        float2 g = sph * 55.0;
        float2 id = floor(g);
        float h = hash21(id);
        // denser star count – lower threshold
        if (h < 0.82) return float3(0.0);
        float2 f = fract(g) - 0.5;
        float2 off = (float2(hash21(id + 17.3), hash21(id + 31.7)) - 0.5) * 0.7;
        float spark = smoothstep(0.10, 0.0, length(f - off));
        float tw = 0.65 + 0.35 * sin(time * (0.5 + 2.0 * hash21(id + 5.1)) + 40.0 * h);
        float3 tint = mix(float3(0.90, 0.88, 1.0), float3(0.70, 0.82, 1.0), hash21(id + 2.9));
        return tint * spark * tw * ((h - 0.82) / 0.18);
    }

    // faint cosmic-streamline overlay on background
    float3 cosmicStreams(float3 d, float time) {
        float2 sph = float2(atan2(d.x, -d.z), asin(clamp(d.y, -1.0, 1.0)));
        float2 q = sph * 6.0;
        float n = vnoiseWrapY(q + float2(0.0, time * 0.04), 11.0);
        float strand = smoothstep(0.52, 0.58, n) * (1.0 - smoothstep(0.62, 0.68, n));
        return float3(0.08, 0.14, 0.32) * strand * 0.45;
    }

    // ── cold accretion-disk spectrum (layer 2) ───────────────

    float3 coldDiskSpectrum(float tprof, float g, float streaks, float phi) {
        // cold white → silver → blue-purple palette
        float3 coldCore  = float3(0.78, 0.84, 1.0);   // blue-violet cold white
        float3 coldMid   = float3(0.50, 0.62, 0.96);   // silver-blue violet
        float3 coldOuter = float3(0.25, 0.32, 0.72);   // blue-purple
        float3 base = mix(coldOuter, coldMid, tprof);
        base = mix(base, coldCore, tprof * tprof);
        // doppler brightening pushes toward blue-white, not red
        float3 dopplered = mix(base, coldCore, g * 0.55);
        // streaks add icy purple variation
        float violetWash = 0.16 + 0.18 * smoothstep(0.18, 1.1, streaks);
        float3 streaked = mix(dopplered, float3(0.42, 0.38, 0.96), violetWash);
        // faint orange-hot accent on right side only (phi ~ 0 to PI/2)
        float orangeBias = smoothstep(0.0, 1.8, phi) * (1.0 - smoothstep(0.0, 3.14, phi));
        orangeBias *= smoothstep(0.4, 0.9, tprof) * 0.18;
        streaked = mix(streaked, float3(0.80, 0.64, 0.58), orangeBias * 0.35);
        return streaked;
    }

    // ── photon-ring clock ticks (layer 3) ────────────────────

    float photonRingTicks(float2 p, float plen, float theta, float time, float rh, float life, float collapse) {
        // elliptical ring outside the iris
        float ringR  = rh * 9.2;
        float ringY  = ringR * 0.52;               // flattened by inclination, kept outside disk body
        float2 ringP = float2(p.x / ringR, p.y / ringY);
        float ellR   = length(ringP);
        // proximity to ring
        float ringProx = exp(-pow((ellR - 1.0) / 0.050, 2.0));

        // clock ticks: sparse outer scale marks
        float tickAngle  = atan2(ringP.y, ringP.x);
        float tickPhase  = tickAngle * 40.0 / (2.0 * PI) + time * 0.06; // slow rotation
        float tickId     = round(tickPhase);
        float tickDist   = abs(tickPhase - tickId);
        float tickAngular = 1.0 - smoothstep(0.0, 0.038, tickDist);

        // each tick is a short radial dash
        float tickRadial  = 1.0 - smoothstep(0.0, 0.030, abs(ellR - 1.0));
        float tick = tickAngular * tickRadial;

        // visibility modulation: more visible lower-half & sides
        float visAngle = atan2(p.y, p.x);
        float visMod   = 0.25 + 0.75 * smoothstep(-0.5, 1.2, -sin(visAngle));
        // also dim topmost ticks
        visMod *= 1.0 - 0.55 * smoothstep(0.6, 1.0, sin(visAngle));

        float glow = exp(-pow((ellR - 1.0) / 0.12, 2.0)) * 0.35;

        float pulseAmp = 1.0 + 0.45 * collapse * sin(time * 5.5 + tickAngle * 8.0);

        return (tick * 0.56 + glow * 0.52) * visMod * life * pulseAmp * ringProx;
    }

    // ── Aleph flow helpers (keep existing) ───────────────────

    float alephFlowField(float2 q, float time) {
        float ribbon = q.y * 33.0 + 4.0 * sin(q.x * 11.0 + q.y * 1.6) - time * 4.4;
        float bands = 0.55 + 0.45 * sin(ribbon) + 0.22 * sin(ribbon * 2.31 + q.x * 19.0);
        float n = vnoiseWrapY(float2(q.x * 15.0 + sin(q.y * 6.0), q.y * 21.0 - time * 3.8), 23.0);
        return clamp(bands * 0.48 + n * 0.72, 0.0, 1.0);
    }

    float alephParticles(float2 q, float plume, float time) {
        float2 grid = float2(q.x * 12.0, q.y * 20.0 - time * 5.8);
        float2 id = floor(grid);
        float2 f = fract(grid) - 0.5;
        float h = hash21(id);
        float2 off = (float2(hash21(id + 2.1), hash21(id + 5.7)) - 0.5) * 0.62;
        float spark = smoothstep(0.10, 0.0, length(f - off));
        return spark * step(0.78, h) * plume;
    }

    // ── Aleph-1 iris composite (layer 1) ─────────────────────
    //    black pupil + electric iris + mushroom crown + non-Newtonian drip

    float3 alephIrisLayer(float2 eyeP, float eyeSize, float t, float life, float collapse, float influence) {
        float3 col = float3(0.0);

        // coordinate normalisation
        float2 eq = eyeP / max(eyeSize, 1e-4);
        float  er = length(eq);
        float  ea = atan2(eq.y, eq.x);

        // flow noise reused across sub-layers
        float flowN = alephFlowField(eq, t);
        float fbmN  = fbm(eq * 4.5 + t * 0.3) * 0.5 + 0.5;

        // ── A. black pupil ────────────────────────────────
        float pupilCore  = 1.0 - smoothstep(0.16, 0.38, er);
        float pupilSoft  = 1.0 - smoothstep(0.34, 0.56, er);
        float pupilDark  = pupilCore * 0.92 + pupilSoft * 0.08;
        // faint deep-blue micro-stars inside pupil
        float pStar = 0.0;
        {   float2 pg = eq * 28.0;
            float2 pid = floor(pg);
            float  ph = hash21(pid);
            if (ph > 0.94) {
                float2 pf = fract(pg) - 0.5;
                float2 po = (float2(hash21(pid+3.1), hash21(pid+7.2)) - 0.5) * 0.55;
                pStar = smoothstep(0.08, 0.0, length(pf - po)) * ((ph - 0.94) / 0.06);
            }
        }
        float3 pupilCol = float3(0.0, 0.008, 0.040) * (1.0 - pupilCore);
        pupilCol += float3(0.02, 0.12, 0.50) * pStar * pupilSoft;
        col = mix(col, pupilCol, pupilDark * life);

        // ── B. electric iris — angular breakup so crown/slime dominate, not a uniform ring ──
        float irisAnnulus = smoothstep(0.30, 0.44, er) * (1.0 - smoothstep(0.65, 0.80, er));
        // angular gate: iris visible on sides, suppressed top (crown) and bottom (slime)
        float irisAngleGate = 1.0 - 0.75 * smoothstep(0.55, 0.95, abs(sin(ea)))  // weaker top/bottom
                                  - 0.60 * smoothstep(0.55, 0.95, abs(cos(ea))); // weaker sides too → mostly diagonal
        irisAngleGate = clamp(irisAngleGate, 0.15, 1.0);
        // radial fibres — more organic, less ring-like
        float fibres = 0.4 + 0.6 * sin(ea * 19.0 + fbmN * 8.0);
        fibres = mix(fibres, 1.0, 0.4);
        float irisTexture = fibres * (0.5 + 0.5 * flowN) * irisAnnulus * irisAngleGate;
        // orange-hot bias on right / lower-right quadrant
        float orangeZone = smoothstep(-0.6, 1.5, ea) * (1.0 - smoothstep(1.8, 3.14, abs(ea)));
        orangeZone *= smoothstep(0.35, 0.75, er) * 0.55;
        float3 irisBase  = float3(0.05, 0.58, 1.0);
        float3 irisHot   = float3(1.0, 0.65, 0.25);
        // AC007: reduced iris ring intensity 0.85→0.35 — texture provides shape,
        //        iris ring adds only subtle colour infusion at edges.
        float3 irisColor = mix(irisBase, irisHot, orangeZone * (0.5 + 0.5 * fbmN));
        float innerRim = exp(-pow((er - 0.38) / 0.09, 2.0));
        irisColor = mix(irisColor, float3(0.55, 0.88, 1.0), innerRim * 0.55);
        col += irisColor * irisTexture * life * 0.35;

        // ── C. 3-lobe mushroom cloud (explicit asymmetric lobes with fBM edges) ──
        // lobe positions and sizes in eq-space (relative to pupil centre)
        float2 lobeL_ctr = float2(-0.16, -0.48);  float lobeL_rx = 0.14, lobeL_ry = 0.18;
        float2 lobeC_ctr = float2( 0.00, -0.62);  float lobeC_rx = 0.09, lobeC_ry = 0.12;
        float2 lobeR_ctr = float2( 0.15, -0.42);  float lobeR_rx = 0.15, lobeR_ry = 0.17;
        // lower bound mask so lobes only appear above pupil
        float lobeBase = smoothstep(-0.15, 0.25, -eq.y);
        // left blue-cyan lobe
        float2 lq = float2((eq.x - lobeL_ctr.x)/lobeL_rx, (eq.y - lobeL_ctr.y)/lobeL_ry);
        float  lobeL = exp(-dot(lq, lq) * 1.1) * lobeBase;
        // centre cold-white bright core (smaller, more intense)
        float2 cq = float2((eq.x - lobeC_ctr.x)/lobeC_rx, (eq.y - lobeC_ctr.y)/lobeC_ry);
        float  lobeC = exp(-dot(cq, cq) * 1.3) * lobeBase;
        // right orange-white lobe
        float2 rq = float2((eq.x - lobeR_ctr.x)/lobeR_rx, (eq.y - lobeR_ctr.y)/lobeR_ry);
        float  lobeR = exp(-dot(rq, rq) * 1.0) * lobeBase;
        // fBM rough edges on each lobe
        float fbmL = fbm(eq * 7.0 + float2(0.0, t * 0.04));
        float fbmC = fbm(eq * 9.0 + float2(3.0, t * 0.06));
        float fbmR = fbm(eq * 6.5 + float2(6.0, t * 0.05));
        lobeL *= 0.50 + 0.50 * fbmL;
        lobeC *= 0.55 + 0.45 * fbmC;
        lobeR *= 0.45 + 0.55 * fbmR;
        // build colours — each lobe its own colour, then sum
        // AC007: reduced multipliers — texture layer provides the shape,
        //        procedural lobes add subtle colour infusion, not standalone blobs.
        float3 crownCol = float3(0.0);
        crownCol += float3(0.18, 0.52, 1.0)  * lobeL * 1.5;  // blue-cyan left
        crownCol += float3(0.90, 0.95, 1.0)  * lobeC * 2.0;  // cold white centre
        crownCol += float3(1.0, 0.35, 0.07)  * lobeR * 1.8;  // orange-white right
        // edge scattering tint per lobe (also reduced)
        crownCol += float3(0.48, 0.22, 0.88) * lobeL * fbmL * 0.18;
        crownCol += float3(0.70, 0.85, 1.0)  * lobeC * fbmC * 0.10;
        crownCol += float3(0.95, 0.48, 0.12) * lobeR * fbmR * 0.15;
        col += crownCol * life;

        // ── D. 3-flow-column mucus drip with rounded droplet heads ──
        // Each column = path of blobs + a larger droplet head at the bottom.
        // Columns are distinct enough to read as 3 streams, bridged for adhesion.
        float dripY = eq.y;
        float dripMask = smoothstep(0.02, 0.18, dripY)
                       * (1.0 - smoothstep(2.2, 3.8, dripY));
        float slowT = t * 0.10;
        float density = 0.0;

        // --- centre column (thickest, main droop) ---
        float cCx = 0.0, cCy[4] = {0.30, 0.60, 0.95, 1.35}, cCr[4] = {0.10, 0.08, 0.07, 0.11};
        for (int i = 0; i < 4; i++) {
            float wx = 0.008 * sin(slowT * 1.3 + float(i) * 2.1);
            float wy = slowT * 0.28;
            float d2 = ((eq.x - (cCx + wx))*(eq.x - (cCx + wx)) + (eq.y - (cCy[i] + wy))*(eq.y - (cCy[i] + wy))) / (cCr[i]*cCr[i] * 1.0);
            density += exp(-d2);
        }
        // centre droplet head (larger, rounded at bottom tip)
        float chY = 1.70 + slowT * 0.28;
        float chR = 0.10;
        float chD2 = ((eq.x - cCx)*(eq.x - cCx) + (eq.y - chY)*(eq.y - chY)) / (chR*chR * 0.7);
        density += exp(-chD2) * 0.75;

        // --- left column (shorter, thinner) ---
        float lCx = -0.10, lCy[3] = {0.35, 0.65, 1.00}, lCr[3] = {0.07, 0.06, 0.08};
        for (int i = 0; i < 3; i++) {
            float wx = 0.010 * sin(slowT * 1.1 + float(i) * 2.5 + 1.0);
            float wy = slowT * 0.25;
            float d2 = ((eq.x - (lCx + wx))*(eq.x - (lCx + wx)) + (eq.y - (lCy[i] + wy))*(eq.y - (lCy[i] + wy))) / (lCr[i]*lCr[i] * 0.9);
            density += exp(-d2);
        }
        float lhY = 1.20 + slowT * 0.25, lhR = 0.07;
        float lhD2 = ((eq.x - lCx)*(eq.x - lCx) + (eq.y - lhY)*(eq.y - lhY)) / (lhR*lhR * 0.6);
        density += exp(-lhD2) * 0.65;

        // --- right column (medium, angled slightly outward) ---
        float rCx = 0.09, rCy[3] = {0.33, 0.60, 0.92}, rCr[3] = {0.07, 0.06, 0.07};
        for (int i = 0; i < 3; i++) {
            float wx = 0.009 * sin(slowT * 1.2 + float(i) * 2.3 + 2.0);
            float wy = slowT * 0.26;
            float d2 = ((eq.x - (rCx + wx))*(eq.x - (rCx + wx)) + (eq.y - (rCy[i] + wy))*(eq.y - (rCy[i] + wy))) / (rCr[i]*rCr[i] * 0.9);
            density += exp(-d2);
        }
        float rhY = 1.10 + slowT * 0.26, rhR = 0.08;
        float rhD2 = ((eq.x - rCx)*(eq.x - rCx) + (eq.y - rhY)*(eq.y - rhY)) / (rhR*rhR * 0.6);
        density += exp(-rhD2) * 0.65;

        // --- bridge strands between centre–left and centre–right ---
        for (int b = 0; b < 3; b++) {
            float by = 0.45 + float(b) * 0.30;
            // centre↔left bridge
            float bLx = mix(cCx, lCx, 0.5);
            float bLw = length(float2(cCx - lCx, 0.0)) * 0.8;
            float bLd = length(float2(eq.x - bLx, eq.y - by)) / max(bLw, 1e-4);
            density += exp(-bLd * bLd * 4.0) * 0.30;
            // centre↔right bridge
            float bRx = mix(cCx, rCx, 0.5);
            float bRw = length(float2(cCx - rCx, 0.0)) * 0.8;
            float bRd = length(float2(eq.x - bRx, eq.y - by)) / max(bRw, 1e-4);
            density += exp(-bRd * bRd * 4.0) * 0.30;
        }

        // threshold → separate streams with adhesion bridges
        float goo      = smoothstep(0.18, 0.38, density);
        float thick    = smoothstep(0.42, 0.64, density);
        float specular = smoothstep(0.60, 0.78, density) * 0.28; // much weaker white highlight

        // colour: blue-cyan body, subtle white-blue on specular edge only
        float3 dripBodyCol = float3(0.04, 0.60, 0.95);
        float3 dripThick   = float3(0.15, 0.72, 1.0);
        float3 dripSpec    = float3(0.45, 0.78, 0.95);  // toned down from AC003 (was 0.78,0.94,1.0)
        float3 dripOut = mix(dripBodyCol, dripThick, thick);
        dripOut = mix(dripOut, dripSpec, specular);
        // AC008: keep procedural mucus as a faint colour infusion only.
        // The reference-cut slime texture now owns the silhouette and gaps.
        col += dripOut * goo * dripMask * life * 0.35;
        // edge rim light — blue-cyan, not white (also reduced)
        float rim = goo * (1.0 - thick) * 0.08;
        col += float3(0.35, 0.55, 0.95) * rim * dripMask * life;

        // ── E. outer shell — reduced to faint angular rim light (NOT a dominant ring) ──
        float shell = exp(-pow((er - 0.88) / 0.18, 2.0));
        // break the ring by angle: only visible in upper-left and lower-right quadrants
        float shellAngleGate = 0.25 + 0.75 * smoothstep(0.3, 0.8, abs(sin(ea * 1.7 + 0.5)));
        float shellTex = shell * (0.5 + 0.5 * fbm(eq * 6.0 + t * 0.05)) * shellAngleGate;
        float3 shellCol = float3(0.45, 0.70, 0.95) * shellTex * life * 0.12;
        col += shellCol;

        return col;
    }

    // ── AC006: Aleph asset-texture layer (anti-sticker rewrite) ──
    //    Back-haze + front-core two-pass, strong edge fracture,
    //    multi-frequency alpha dissolve, slime trailing wisp threads.

    float4 sampleAlephAssetLayer(
        float2 p, float2 eyeP, float eyeSize, float t, float life,
        texture2d<float, access::sample> plumeTex,
        texture2d<float, access::sample> slimeTex,
        sampler smp
    ) {
        // Normalised eye coordinates
        float2 eq = eyeP / max(eyeSize, 1e-4);
        float  er = length(eq);
        float  ea = atan2(eq.y, eq.x);

        // ── UV mapping ──────────────────────────────────────
        float  uvScale  = 0.96;  // AC012: show the newly re-cropped wider reference range
        float2 uvBase   = eq * uvScale + 0.5;

        // ── two-frequency domain warp ───────────────────────
        // AC018: slow liquid-flow strengthens as eye appears
        float localEyeAppear = smoothstep(0.25, 0.55, life);
        float  warpStr  = 0.018 + 0.010 * sin(t * 0.47) + localEyeAppear * 0.016;
        float2 warpOff  = float2(
            fbm(eq * 8.0 + t * 0.10),
            fbm(eq * 8.0 + t * 0.10 + float2(4.7, 2.3))
        );
        float2 uvWarp   = uvBase + warpOff * warpStr;

        // Viscous flow effect: slow, low-frequency surface ooze distortion
        float viscousTime = t * 0.08;
        float2 viscousFlow = float2(
            fbm(eq * 5.5 + float2(viscousTime, -viscousTime * 0.7)),
            fbm(eq * 5.5 + float2(viscousTime * 0.6 + 3.0, viscousTime * 0.8 + 1.5))
        );
        float viscousStr = 0.012 + 0.008 * sin(t * 0.23) + localEyeAppear * 0.010;
        uvWarp += viscousFlow * viscousStr;

        // Coarser warp for back-haze layer (more diffuse)
        float2 hazeWarp = uvBase + warpOff * warpStr * 1.8 + viscousFlow * viscousStr * 1.3;

        // Slime UV — AC010-B: centered, no x-shift. Slime hangs from pupil centerline.
        float2 slimeUV   = uvWarp;
        // No x-shift: slime centerline = BH centre x
        slimeUV.y        = (slimeUV.y - 0.50) * 0.92 + 0.08;
        float2 slimeHazeUV = hazeWarp;
        slimeHazeUV.y      = (slimeHazeUV.y - 0.50) * 0.92 + 0.08;

        // ── directional gates — widened for AC007 so plume/slime cover full angular range ──
        float upFacing   = smoothstep(-0.35, 0.65, -sin(ea));
        float downFacing = smoothstep(-0.35, 0.65,  sin(ea));

        // ── sample textures (front core) ────────────────────
        float4 plumeSample = plumeTex.sample(smp, clamp(uvWarp,   0.001, 0.999));
        float4 slimeSample = slimeTex.sample(smp, clamp(slimeUV,  0.001, 0.999));

        // ── sample textures (back haze — coarser, softer) ───
        float4 plumeHaze = plumeTex.sample(smp, clamp(hazeWarp,     0.001, 0.999));
        float4 slimeHaze = slimeTex.sample(smp, clamp(slimeHazeUV,  0.001, 0.999));

        // ── multi-frequency edge fracture noise ─────────────
        float edgeNoiseHi = fbm(eq * 18.0 + t * 0.17 + 1.5);
        float edgeNoiseLo = fbm(eq * 6.0  + t * 0.08 + 5.0);
        float edgeFracture = edgeNoiseHi * 0.55 + edgeNoiseLo * 0.45;

        // ── per-pixel alpha dissolve (reduced for AC007 — let texture shape through) ──
        float dissolveHi = 0.92 + 0.08 * fbm(eq * 15.0 + t * 0.18 + 6.0);
        float dissolveLo = 0.94 + 0.06 * fbm(eq * 5.0  + t * 0.07 + 2.3);
        float dissolve   = dissolveHi * 0.6 + dissolveLo * 0.4;
        // Additional erosion at texture edges (where alpha gradient is high)
        float alphaGrad = abs(plumeSample.a - plumeHaze.a) + abs(slimeSample.a - slimeHaze.a);
        float edgeErode = 1.0 - alphaGrad * 0.18 * edgeFracture;
        dissolve = dissolve * clamp(edgeErode, 0.78, 1.0);

        // ── plume colour: front core + back haze ────────────
        float3 plumeRgb = plumeSample.rgb;
        float plumeLum = dot(plumeRgb, float3(0.2126, 0.7152, 0.0722));
        plumeRgb = clamp(mix(float3(plumeLum), plumeRgb, 1.06), 0.0, 1.0); // AC023: colour blocks without cyan oversaturation
        // AC007: boost warm (orange/red) channels to make right lobe visible
        float warmth = clamp((plumeRgb.r - plumeRgb.b) / max(plumeRgb.r + plumeRgb.b, 0.01), 0.0, 1.0);
        plumeRgb.r *= 1.0 + warmth * 0.35;  // restrained warm recovery
        plumeRgb = pow(plumeRgb, float3(0.96));              // mild contrast, not saturation
        float pulse = 1.0 + 0.035 * sin(t * 3.3 + ea * 2.0);
        plumeRgb *= pulse;

        // Back haze: desaturated, lower opacity, wider spread
        float3 plumeHazeRgb = plumeHaze.rgb * 0.55;
        float  hazeAlpha    = pow(plumeHaze.a, 0.70) * 0.52;

        // ── slime colour: front core + back haze ────────────
        // AC021: slimeTex is sampled here only for legacy colour support; the direct
        // eye overlay below is now driven by the cleaned iris asset. The actual
        // falling fluid silhouette is generated in the coarse-column grey model.
        float3 slimeRgb = slimeSample.rgb;
        float slimeEdge = slimeSample.a * (1.0 - slimeSample.a) * 4.0;
        slimeRgb = mix(slimeRgb, float3(0.55, 0.82, 1.0), slimeEdge * 0.45);

        float3 slimeHazeRgb = slimeHaze.rgb * 0.45;
        float  slimeHazeAlpha = pow(slimeHaze.a, 0.68) * 0.40;

        // AC008: separate radial gates. Plume must stay inside the black central
        // opening; slime may extend lower, but still cannot spill onto the disk.
        float plumeRadial = 1.0 - smoothstep(0.28, 0.92, er);
        float plumeHazeRadial = 1.0 - smoothstep(0.24, 1.02, er);
        float slimeRadial = 1.0 - smoothstep(0.18, 1.08, er);
        float slimeHazeRadial = 1.0 - smoothstep(0.16, 1.18, er);

        // ── edge glow ───────────────────────────────────────
        float  glow       = exp(-pow(max(1.0 - er * 1.05, 0.0) / 0.58, 2.0));
        float3 glowColor  = float3(0.32, 0.62, 1.0);
        glowColor         = mix(glowColor, float3(0.90, 0.44, 0.12),
                                smoothstep(0.0, 2.8, ea) * (1.0 - smoothstep(0.0, 3.14, ea)) * 0.48);

        // ── slime trailing threads (low-alpha, thin, not swinging) ──
        float threadAlpha = 0.0;
        float3 threadRgb  = float3(0.0);
        {
            float slowT = t * 0.025; // very slow drift
            // 4 thin vertical wisp positions, each a very elongated Gaussian
            float2 threadPos[4] = {
                float2(-0.03, 0.65), float2( 0.02, 0.72),
                float2(-0.06, 0.82), float2( 0.04, 0.88)
            };
            float threadLen[4]  = {0.22, 0.18, 0.26, 0.15};
            float threadWid[4]  = {0.009, 0.007, 0.010, 0.006};
            float threadOp[4]   = {0.10, 0.08, 0.11, 0.06};
            for (int ti = 0; ti < 4; ti++) {
                float tx = threadPos[ti].x + 0.006 * sin(slowT * 1.3 + float(ti) * 2.1);
                float ty = threadPos[ti].y + slowT * 0.12;
                float dx = (eq.x - tx) / threadWid[ti];
                float dy = (eq.y - ty) / threadLen[ti];
                float g  = exp(-(dx*dx + dy*dy));
                threadAlpha += g * threadOp[ti];
                threadRgb   += float3(0.10, 0.45, 0.82) * g * threadOp[ti];
            }
        }
        // AC021: no hidden slime wisps during the eye-only reveal.
        threadAlpha *= 0.0;
        threadAlpha *= 0.85 + 0.15 * edgeNoiseLo; // slight flicker

        // ── assemble: back haze first, then front core ──────
        float cleanEyeFacing = clamp(upFacing + downFacing * 0.72 + (1.0 - abs(sin(ea))) * 0.35, 0.0, 1.0);
        // Back haze (wide, soft, low alpha)
        float hazeUpAlpha   = hazeAlpha * cleanEyeFacing * plumeHazeRadial;
        float hazeDownAlpha = 0.0;
        float3 hazeUpCol    = plumeHazeRgb * hazeUpAlpha;
        float3 hazeDownCol  = float3(0.0);

        // Front core (sharp, higher alpha, edge-fractured)
        float coreUpAlpha   = min(pow(plumeSample.a, 0.64) * 2.00, 1.0) * cleanEyeFacing * plumeRadial;
        float coreDownAlpha = 0.0;
        float3 coreUpCol    = plumeRgb * coreUpAlpha;
        float3 coreDownCol  = float3(0.0);

        // Glow contribution
        float3 glowColAdd   = glowColor * glow * cleanEyeFacing * plumeRadial * 0.18;

        // Composite: haze (behind) + core (front) + glow + threads
        float  totalAlpha = clamp(
            (hazeUpAlpha + hazeDownAlpha) * 0.72 +
            (coreUpAlpha + coreDownAlpha) * dissolve * 0.96 +
            threadAlpha,
            0.0, 1.0);
        float3 totalRgb   = (hazeUpCol + hazeDownCol) * 1.12 +
                            (coreUpCol + coreDownCol) * dissolve * 1.08 +
                            glowColAdd +
                            threadRgb * threadAlpha;
        float contourAlpha = clamp(pow(plumeSample.a, 0.54) * cleanEyeFacing * plumeHazeRadial * 0.34, 0.0, 1.0);
        totalRgb += float3(0.42, 0.85, 1.0) * contourAlpha * 0.36;
        totalAlpha = max(totalAlpha, contourAlpha * 0.54);

        // Apply life
        totalAlpha *= life;
        totalRgb   *= life;

        // AC022: return straight RGB. The outer compositing path already uses alpha
        // for visibility; returning pre-weighted colour washed out texture blocks.
        float3 straightRgb = totalRgb / max(totalAlpha, 0.045);
        straightRgb = clamp(mix(totalRgb, straightRgb, smoothstep(0.10, 0.72, totalAlpha)), 0.0, 1.45);
        return float4(straightRgb, totalAlpha);
    }

    // ── vertex shader ────────────────────────────────────────

    struct VertexOut {
        float4 position [[position]];
        float2 texCoord;
    };

    vertex VertexOut blackHoleVertex(uint vid [[vertex_id]]) {
        const float2 positions[6] = {
            float2(-1, -1), float2( 1, -1), float2(-1,  1),
            float2( 1, -1), float2( 1,  1), float2(-1,  1)
        };
        const float2 texCoords[6] = {
            float2(0, 1), float2(1, 1), float2(0, 0),
            float2(1, 1), float2(1, 0), float2(0, 0)
        };
        VertexOut out;
        out.position = float4(positions[vid], 0, 1);
        out.texCoord = texCoords[vid];
        return out;
    }

    // ── fragment shader ──────────────────────────────────────

    fragment float4 blackHoleFragment(
        VertexOut in [[stage_in]],
        constant Uniforms& u [[buffer(0)]],
        texture2d<float, access::sample> screenTex [[texture(0)]],
        texture2d<float, access::sample> irisPlumeTex [[texture(1)]],
        texture2d<float, access::sample> slimeTex [[texture(2)]],
        sampler texSampler [[sampler(0)]]
    ) {
        float2 uv = in.texCoord;
        float t = u.time * u.driftSpeed;
        float3 baseColor = sampleScreen(screenTex, texSampler, uv);
        float life = smoothstep(0.0, 1.0, clamp(u.dilation, 0.0, 1.0));
        float collapse = smoothstep(0.0, 1.0, clamp(u.collapse, 0.0, 1.0));
        float sz = mix(0.12, 1.55, life);
        float vis = life;

        // ── Eyelid and eyeball appear with accretion disk from the start ──
        float animT = u.animTime;
        float holeSettled = life;
        float squintOpen = life;
        float eyeAppear = pow(life, 2.2);
        float slimeAppear = smoothstep(2.5, 4.0, animT) * eyeAppear;
        float slimeStretch = smoothstep(3.5, 16.0, animT) * eyeAppear;

        if (vis <= 0.0) {
            return float4(baseColor, 1.0);
        }

        float rh = u.holeRadius * sz;
        float2 center = u.center;
        // AC018: disk fixed horizontally, no rotation
        float spin = 0.0;
        float2 p = (uv - center) * float2(u.aspect, 1.0);
        float plen = length(p);
        float theta = atan2(p.y, p.x);
        float influenceRadius = mix(max(rh * 2.8, 0.08), 1.55, life);
        float influenceFeather = mix(0.035, 0.34, life);
        float influence = 1.0 - smoothstep(influenceRadius, influenceRadius + influenceFeather, plen);
        influence = clamp(influence * vis, 0.0, 1.0);
        float2 dir2 = p / max(plen, 1e-5);

        // collapse shock-wave
        float shockRadius = mix(max(rh * 2.4, 0.10), 1.38, life);
        float shockWidth = mix(0.018, 0.10, life);
        float shock = exp(-pow((plen - shockRadius) / max(shockWidth, 1e-4), 2.0)) * collapse;
        float collapseFalloff = exp(-plen * 2.2) * collapse;
        float tidalRipple = sin(plen * 95.0 - t * 16.0) * 0.006 * shock;
        float pull = collapseFalloff * mix(0.12, 0.035, life) + tidalRipple;
        float2 collapseUV = clamp(uv + dir2 / float2(u.aspect, 1.0) * pull, 0.0, 1.0);
        float3 collapseColor = sampleScreen(screenTex, texSampler, collapseUV);
        float3 shockGlow = float3(0.60, 0.78, 1.0) * shock * 0.45;
        float collapseMix = clamp(collapseFalloff + shock * 0.65, 0.0, 1.0);
        baseColor = mix(baseColor, collapseColor * (1.0 - 0.28 * collapseFalloff) + shockGlow, collapseMix);

        // ── geodesic integration ──────────────────────────
        float W = B_CRIT / max(rh, 1e-4);
        float2 pr = rot(float2(p.x, -p.y), spin) * W;
        float b = length(pr);
        float bmax = u.diskOuter + 3.0;
        float Z0 = max(14.0, u.diskOuter + 5.0);

        // ── outer region: gravitational lensing + layer 4 (stars) ──
        if (b >= bmax) {
            float uu = Z0 * rsqrt(Z0 * Z0 + b * b);
            float defl = (2.0 / (W * W)) / max(plen, 1e-4)
                       * (1.29 * uu + 0.07) * max(u.lensDepth - 2.14 * uu + 0.75, 0.0);
            float2 dir = p / max(plen, 1e-5);
            float3 term = float3(0.0);
            float ab = 0.035 * smoothstep(1.0, 2.0, b / bmax);
            for (int i = 0; i < 3; i++) {
                float k = 1.0 + (float(i) - 1.0) * ab;
                float2 suv = clamp(center + (p - dir * defl * k) / float2(u.aspect, 1.0), 0.0, 1.0);
                term[i] = sampleScreen(screenTex, texSampler, suv)[i];
            }
            float3 d = normalize(float3(-(pr / b) * (2.0 / b), -1.0));
            float3 starsLayer = starFieldLayer(d, u.time, u.starGain);
            float3 cosmosBg    = cosmicStreams(d, u.time);
            float3 warpedOuter = term + starsLayer + cosmosBg;
            return float4(mix(baseColor, warpedOuter, influence), 1.0);
        }

        // ── geodesic ray-march ────────────────────────────
        float3 x = float3(pr, Z0);
        float3 v = float3(0.0, 0.0, -1.0);
        float h2 = dot(pr, pr);
        float ci = cos(u.diskIncl), si = sin(u.diskIncl);
        float3 n = float3(0.0, si, ci);
        float3 e2 = float3(0.0, ci, -si);
        float sdir = u.diskSpeed < 0.0 ? -1.0 : 1.0;
        float spd = abs(u.diskSpeed);
        float3 emitc = float3(0.0);
        float trans = 1.0;
        bool captured = false;
        float sPrev = dot(x, n);
        float3 xPrev = x;

        for (int i = 0; i < N_STEPS; i++) {
            float r2 = dot(x, x);
            if (r2 < 1.0) { captured = true; break; }
            if (x.z < -Z0 && v.z < 0.0) break;
            if (r2 > 4.0 * Z0 * Z0) break;
            float r = sqrt(r2);
            float dt = clamp(0.16 * r, 0.03, 1.5);
            float3 a = -1.5 * h2 * x / (r2 * r2 * r);
            v += a * (0.5 * dt);
            x += v * dt;
            r2 = dot(x, x);
            r = sqrt(r2);
            a = -1.5 * h2 * x / (r2 * r2 * r);
            v += a * (0.5 * dt);

            float s = dot(x, n);
            if (s * sPrev < 0.0 && trans > 0.02) {
                float tc = sPrev / (sPrev - s);
                float3 xc = mix(xPrev, x, tc);
                float rc = length(xc);
                if (rc > u.diskInner && rc < u.diskOuter) {
                    float band = smoothstep(u.diskInner, u.diskInner * 1.14, rc)
                               * (1.0 - smoothstep(u.diskOuter * 0.50, u.diskOuter * 0.88, rc));
                    float phi = atan2(dot(xc, e2), xc.x);
                    float turns = phi / 6.2831853;
                    float kep = pow(u.diskInner / rc, 1.5);
                    float gloc = sqrt(max(1.0 - 1.5 / rc, 0.02));
                    float ringFlow = t * (0.42 + 1.85 * kep) * spd * gloc * max(life, collapse * 0.35) * sdir;
                    float swirl = rc * u.diskWind * 0.12 - ringFlow;
                    float rawStreaks = vnoiseWrapY(float2(rc * 2.8, turns * 19.0 + swirl * 3.0), 19.0) * 0.65 +
                                       vnoiseWrapY(float2(rc * 1.0, turns * 9.0 + swirl * 1.5 + 7.0), 9.0) * 0.35;
                    float beadPhase = phi * 10.0 - ringFlow * 6.0 + rc * 0.65;
                    float beads = pow(smoothstep(0.55, 1.0, 0.5 + 0.5 * sin(beadPhase)), 5.0);
                    float filament = pow(smoothstep(0.35, 1.0, 0.5 + 0.5 * sin(phi * 3.0 - ringFlow * 1.7)), 3.0);
                    float lineGate = smoothstep(0.46, 0.80, rawStreaks);
                    float bodyGate = smoothstep(0.30, 0.62, rawStreaks);
                    float purpleRoute = pow(smoothstep(0.64, 1.0, 0.5 + 0.5 * sin(phi * 5.0 - ringFlow * 2.8 + rc * 0.72)), 4.0)
                                      * smoothstep(0.18, 0.92, lineGate);
                    float streaks = 0.16 + u.diskContrast * lineGate * lineGate * 0.66 + bodyGate * 0.18
                                  + 0.82 * beads + 0.54 * filament;

                    float3 gasdir = normalize(cross(n, xc)) * sdir;
                    float beta = clamp(rsqrt(max(2.0 * (rc - 1.0), 0.2)), 0.0, 0.99);
                    float g = gloc / max(1.0 + beta * dot(gasdir, normalize(v)), 0.05);
                    g = mix(1.0, g, u.dopplerMix);
                    float xpr = max(1.0 - sqrt(u.diskInner / rc), 0.0);
                    float tprof = pow(u.diskInner / rc, 0.75) * pow(xpr, 0.25) / 0.488;

                    // layer 2: cold accretion disk spectrum
                    float3 diskRad = coldDiskSpectrum(tprof, g, streaks, phi);

                    float boost = pow(g, u.diskBeam);
                    float sideLobe = smoothstep(0.05, 0.70, abs(cos(theta)));
                    float upperLid = smoothstep(0.02, 0.80, -sin(theta));
                    // AC018: strongly suppress lower half of accretion disk
                    float lowerCull = 1.0 - 0.96 * smoothstep(-0.10, 0.75, sin(theta));
                    float eyelidGate = (0.22 + 1.82 * sideLobe + 0.86 * upperLid) * lowerCull;
                    float outerT = smoothstep(u.diskInner * 1.35, u.diskOuter * 0.82, rc);
                    float sparseNoise = vnoiseWrapY(float2(rc * 0.82, turns * 7.0 + swirl * 0.65 + 11.0), 7.0);
                    float sparseGate = mix(0.34, 1.0, smoothstep(0.44, 0.80, sparseNoise));
                    sparseGate *= (0.54 + 0.46 * lineGate);
                    sparseGate = mix(sparseGate, smoothstep(0.50, 0.88, sparseNoise), outerT * 0.42);
                    float radialWeight = mix(1.62, 0.68, outerT);
                    float density = band * streaks * eyelidGate * radialWeight * sparseGate;
                    float ignition = smoothstep(0.04, 0.55, life) * (1.0 + 0.75 * collapse);
                    diskRad += float3(0.26, 0.16, 0.86) * purpleRoute * (0.55 + 0.45 * outerT);
                    emitc += trans * diskRad * (u.diskGain * 1.48 * density * tprof * tprof * boost * ignition);
                    trans *= 1.0 - clamp(u.diskOpacity * density * 0.72, 0.0, 1.0);
                }
            }
            sPrev = s;
            xPrev = x;
        }

        if (!captured && dot(x, x) < 4.0) captured = true;

        // ── background (lens plane + stars layer 4) ────────
        float3 bg = float3(0.0);
        if (!captured) {
            float3 d = normalize(v);
            bg += starFieldLayer(d, u.time, u.starGain);
            bg += cosmicStreams(d, u.time);
            if (d.z < -0.05) {
                float tpl = (-u.lensDepth - x.z) / d.z;
                float3 hp = x + d * tpl;
                float2 q = rot(float2(hp.x, hp.y), -spin) / W;
                float2 sp = float2(q.x, -q.y);
                float2 suv = clamp(center + (p + (sp - p)) / float2(u.aspect, 1.0), 0.0, 1.0);
                float toward = smoothstep(0.05, 0.35, -d.z);
                float3 samp = sampleScreen(screenTex, texSampler, suv);
                bg += samp * toward;
            }
        }

        // ── AC019: delayed eyelid snap-open after the black hole settles ──
        float eventBlackR = rh * 2.58;
        float lidYBase = mix(0.006, 0.90, squintOpen);
        float isLower = smoothstep(-0.03, 0.10, p.y / max(eventBlackR, 1e-4));
        float lidYLo = lidYBase * mix(0.08, 0.45, squintOpen); // lower: starts fully shut
        float lidYHi = mix(0.001, 0.74, squintOpen);            // upper: fully shut when closed, opens to 0.74
        float lidYEff = mix(lidYHi, lidYLo, isLower);         // upper=Hi, lower=Lo
        float lidShrink = 0.90;                                 // overall smaller eyelid
        float2 lidP = float2(p.x / max(eventBlackR * 1.22 * lidShrink, 1e-4),
                             p.y / max(eventBlackR * lidYEff * lidShrink, 1e-4));
        float lidLen = length(lidP);
        float centralShield = smoothstep(0.84, 1.12, lidLen);
        emitc *= centralShield;
        // Also suppress bg (lensed desktop) across the black horizon.
        float bgShield = smoothstep(0.72, 1.06, lidLen);
        bg *= bgShield;

        // ── composite base colour ─────────────────────────
        float3 col = bg * trans + (float3(1.0) - exp(-emitc * u.exposure));
        // subtle blue-shift on the whole composite
        col = mix(col, col * float3(0.72, 0.94, 1.32), 0.38 * life);

        // ── AC009: deep-blue starfield vignette behind the black hole ──
        float bgRing = smoothstep(rh * 3.6, rh * 12.0, plen)
                     * (1.0 - smoothstep(rh * 18.0, rh * 30.0, plen));
        float edgeVignette = smoothstep(0.22, 1.06, length((uv - 0.5) * float2(u.aspect, 1.0)));
        float starNoise = vnoise(float2(uv.x * 95.0 + t * 0.012, uv.y * 72.0 - t * 0.018));
        float blueStars = pow(smoothstep(0.82, 1.0, starNoise), 5.0) * (0.45 + 0.55 * edgeVignette);
        float nebula = fbm(float2(uv.x * 4.8 - t * 0.018, uv.y * 3.8 + t * 0.012));
        float3 blueSpace = float3(0.015, 0.055, 0.17) * (0.45 + 0.55 * nebula)
                         + float3(0.20, 0.45, 0.95) * blueStars;
        col += blueSpace * bgRing * edgeVignette * life * 0.34;

        // ── AC018: lensed star backdrop — stars + gravitational lensing ──
        {
            // gravitational deflection
            float lensDefl = rh * 1.6 / max(plen, rh * 0.3);
            float2 lensedP = p + normalize(p) * lensDefl;

            float starField = fbm(lensedP * 12.0) * 0.7 + fbm(lensedP * 30.0 + 3.0) * 0.3;
            float brightStars = smoothstep(0.72, 1.0, starField);

            float starRadial = smoothstep(rh * 1.0, rh * 3.5, plen)
                             * (1.0 - smoothstep(rh * 18.0, rh * 32.0, plen));

            float3 starColor = float3(0.72, 0.85, 1.0);

            col += starColor * brightStars * starRadial * life * 0.65;
        }

        // ── AC018: horizontal outward-expanding halo flow ────────
        {
            // strong horizontal gate: only along disk plane (left/right)
            float haloPlane = pow(abs(cos(theta)), 3.5);
            // mid-to-outer radial range, extending beyond the disk body
            float haloRing  = smoothstep(rh * 3.8, rh * 5.2, plen)
                            * (1.0 - smoothstep(rh * 18.0, rh * 26.0, plen));
            // multiple flow layers with outward drift
            float flowDrift = t * 0.12;
            float flowN1 = fbm(float2(plen * 3.5 - flowDrift, theta * 8.0));
            float flowN2 = fbm(float2(plen * 2.2 - flowDrift * 0.7, theta * 12.0 + 2.0));
            float flowN3 = vnoise(float2(plen * 5.0 - flowDrift * 1.4, theta * 6.0 + 4.0));
            // flowing streaks
            float streaks1 = smoothstep(0.52, 0.72, flowN1) * (1.0 - smoothstep(0.75, 0.90, flowN1));
            float streaks2 = smoothstep(0.48, 0.68, flowN2) * (1.0 - smoothstep(0.72, 0.88, flowN2));
            float streaks3 = smoothstep(0.55, 0.78, flowN3) * (1.0 - smoothstep(0.80, 0.95, flowN3));
            float allStreaks = streaks1 * 0.5 + streaks2 * 0.35 + streaks3 * 0.25;
            // radial fade: brighter mid-range, fading outward
            float radialGlow = exp(-pow((plen - rh * 8.0) / (rh * 5.5), 2.0)) * 0.5
                             + exp(-pow((plen - rh * 13.0) / (rh * 7.0), 2.0)) * 0.3;
            // colour: blue-purple → silver-white, matching accretion disk palette
            float3 haloColor = float3(0.28, 0.38, 0.92);
            haloColor = mix(haloColor, float3(0.55, 0.68, 1.0), streaks1 * 0.7);
            haloColor = mix(haloColor, float3(0.78, 0.86, 1.0), streaks2 * 0.5);
            // combine
            float haloAlpha = (allStreaks * 0.55 + radialGlow * 0.35) * haloPlane * haloRing;
            col += haloColor * haloAlpha * life * 0.48;
        }

        // ── AC016: sparse blue-purple ejection arms outside the accretion disk ──
        float2 armP1 = rot(p, 0.18);
        float armEll1 = length(float2(armP1.x / max(rh * 8.8, 1e-4), armP1.y / max(rh * 2.42, 1e-4)));
        float2 armP2 = rot(p, -0.36);
        float armEll2 = length(float2((armP2.x + rh * 1.15) / max(rh * 7.5, 1e-4), armP2.y / max(rh * 2.15, 1e-4)));
        float armNoise = fbm(p * 9.0 + float2(t * 0.035, -t * 0.018));
        float arm1 = exp(-pow((armEll1 - 1.0) / 0.052, 2.0)) * smoothstep(0.42, 0.82, abs(cos(theta))) * smoothstep(0.45, 0.82, armNoise);
        float arm2 = exp(-pow((armEll2 - 1.0) / 0.060, 2.0)) * smoothstep(0.36, 0.76, abs(cos(theta + 0.5))) * smoothstep(0.55, 0.88, armNoise);
        float outerOnly = smoothstep(rh * 4.8, rh * 6.2, plen);
        col += float3(0.22, 0.20, 0.95) * (arm1 * 0.34 + arm2 * 0.24) * outerOnly * life;

        // ── layer 3: photon-ring clock ticks ──────────────
        float ticks = photonRingTicks(p, plen, theta, t, rh, life, collapse);
        float3 tickColor = float3(0.45, 0.82, 1.0);  // cold white-blue
        // brighter ticks during collapse
        tickColor = mix(tickColor, float3(0.85, 0.96, 1.0), collapse * 0.6);
        col += tickColor * ticks * 1.1;

        // AC011: black horizon is above the accretion disk/ticks and below Aleph assets.
        // AC018: widened soft transition with blue-purple tint
        float horizonFill = 1.0 - smoothstep(0.85, 1.00, lidLen);
        float horizonSoft = 1.0 - smoothstep(0.55, 1.20, lidLen);
        float3 horizonSoftColor = float3(0.06, 0.03, 0.28);    // blue-purple edge
        float3 horizonCoreColor = float3(0.01, 0.00, 0.06);    // deep blue-black core
        col = mix(col, horizonSoftColor, clamp(horizonSoft * 0.72 * life, 0.0, 1.0));
        col = mix(col, horizonCoreColor, clamp(horizonFill * 0.88 * life, 0.0, 1.0));
        float lidCrack = exp(-pow((lidLen - 1.0) / 0.035, 2.0));
        col += float3(0.40, 0.72, 1.0) * lidCrack * life * 0.22;

        // ── layer 1: Aleph-1 iris composite (AC003 mask-based compositing) ──
        // AC010-B: zero offset — texture pupil must align with shader hard pupil at geometric centre
        // AC018: low-amplitude irregular eye tremor, only after eye opens
        // AC018: enhanced tremor + stronger liquid flow
        float tremorX = (fbm(p * 30.0 + t * 5.0) - 0.5) * rh * 0.048 * eyeAppear;
        float tremorY = (fbm(p * 30.0 + t * 5.0 + float2(5.0, 3.0)) - 0.5) * rh * 0.038 * eyeAppear;
        float2 eyeOffset = float2(tremorX, tremorY);
        float2 eyeP = rot(p - eyeOffset, 0.0);
        float eyeSize = max(rh * 4.05, 0.13);
        float3 irisLayer = alephIrisLayer(eyeP, eyeSize, t, life, collapse, influence);

        // directional angle gates — widened for AC007 so plume/slime cover full angular range
        float ang = atan2(p.y, p.x);
        // upFacing: covers upper hemisphere broadly, including upper-right (orange lobe) and upper-left
        float upFacing   = smoothstep(-0.35, 0.65, -sin(ang));
        // downFacing: covers lower hemisphere broadly
        float downFacing = smoothstep(-0.35, 0.65, sin(ang));
        float sideFacing = 1.0 - abs(sin(ang));                 // left/right for disk

        // AC007: tightened masks — plume and slime stay within event horizon zone,
        //        must not cross the external cold-white accretion disk.
        // coreMask: tight, pupil + iris ring only
        float coreMask = 1.0 - smoothstep(rh * 0.25, rh * 1.35, plen);
        // plumeMask: upper bloom, constrained below accretion disk inner edge (~rh*2.2)
        float plumeMask = (1.0 - smoothstep(rh * 0.50, rh * 2.2, plen)) * upFacing;
        // slimeMask: lower drip, constrained below accretion disk inner edge
        float slimeMask = (1.0 - smoothstep(rh * 0.45, rh * 2.4, plen)) * downFacing;

        // ── AC007: strengthened diskProtect — accretion disk must be clearly visible ──
        // Base side protection: strongest on pure left/right (disk plane), weaker above/below
        float diskPlaneFidelity = abs(cos(ang)); // 1.0 at disk plane (left/right), 0.0 at top/bottom
        float diskProtectBase = 1.0 - 0.88 * sideFacing
                                      * smoothstep(rh * 0.9, rh * 5.5, plen)
                                      * smoothstep(0.03, 0.45, abs(sin(ang)))
                                      * diskPlaneFidelity; // stronger on disk plane
        // Extra protection on the right half (long white tail in reference)
        float rightSide = smoothstep(-0.15, 1.2, sin(ang)); // 1 on right, 0 on left
        float rightDiskProtect = 1.0 - 0.78 * rightSide
                                        * smoothstep(rh * 1.5, rh * 6.5, plen)
                                        * (1.0 - abs(sin(ang)) * 0.35)
                                        * diskPlaneFidelity; // stronger on disk plane
        float diskProtect = min(diskProtectBase, rightDiskProtect);

        // ── AC007 iter3: Direct texture overlay — bypass procedural iris blending ──
        // Sample texture layer first
        float4 texLayer = sampleAlephAssetLayer(p, eyeP, eyeSize, t, life,
                                                 irisPlumeTex, slimeTex, texSampler);

        // Blend iris layer as before (subtle procedural underneath)
        float3 enrichedIris = irisLayer;

        float irisFull = max(max(coreMask, plumeMask * 0.95), slimeMask * 0.95);
        irisFull = clamp(irisFull * diskProtect * life, 0.0, 1.0);

        // Reduce irisFull further so procedural doesn't dominate
        // AC018: iris fades in with eye opening
        irisFull *= 0.55 * eyeAppear;
        col = mix(col, enrichedIris, irisFull);

        // DIRECT texture overlay: add texture colours on top of everything.
        // AC019: upper eye reveals after the lid opens; lower slime waits for its own phase.
        float eyeBallGate = 1.0 - smoothstep(rh * 2.58, rh * 3.36, plen);
        float2 eyeEqNorm = eyeP / max(eyeSize, 1e-4);
        float lowerEyeOnlyGate = eyeBallGate * (1.0 - smoothstep(0.32, 0.58, eyeEqNorm.y));
        float eyeTextureGate = clamp(upFacing + sideFacing * 0.45 + downFacing * lowerEyeOnlyGate, 0.0, 1.0) * eyeAppear;
        float texPhaseGate = clamp(eyeTextureGate, 0.0, 1.0);
        float texDirectAlpha = texLayer.a * texPhaseGate;
        float texRadial = 1.0 - smoothstep(rh * 0.10, rh * 3.42, plen);
        float texAngular = clamp(upFacing + sideFacing * 0.45 + downFacing * lowerEyeOnlyGate, 0.0, 1.0);
        texAngular = clamp(texAngular, 0.0, 1.0);
        float texDiskProtect = 1.0;
        float texDirectMask = texDirectAlpha * texRadial * texAngular * texDiskProtect;
        float edgeReveal = pow(clamp(texDirectAlpha, 0.0, 1.0), 0.58) * texRadial * texAngular;
        float shellLight = smoothstep(rh * 1.85, rh * 3.36, plen) * (1.0 - smoothstep(rh * 3.36, rh * 3.72, plen));

        // AC028: after slime starts, soften the lower eyeball edge so it melts into the falling column.
        float dropMelt = smoothstep(0.06, 0.72, slimeAppear);
        float lowerSeamMelt = smoothstep(0.10, 0.28, eyeEqNorm.y) *
                              (1.0 - smoothstep(0.42, 0.76, abs(eyeEqNorm.x)));
        float lowerContourMelt = smoothstep(0.26, 0.58, eyeEqNorm.y) *
                                 (1.0 - smoothstep(0.56, 0.92, abs(eyeEqNorm.x)));
        float lowerMelt = clamp(max(lowerSeamMelt * 0.82, lowerContourMelt) * dropMelt * eyeAppear, 0.0, 1.0);
        float2 lowerBlurUV = eyeEqNorm * 0.96 + 0.5;
        float blurRadius = mix(0.004, 0.020, slimeStretch) * lowerMelt;
        float4 lowerBlur = irisPlumeTex.sample(texSampler, clamp(lowerBlurUV, 0.001, 0.999)) * 0.36;
        lowerBlur += irisPlumeTex.sample(texSampler, clamp(lowerBlurUV + float2( blurRadius, 0.0), 0.001, 0.999)) * 0.16;
        lowerBlur += irisPlumeTex.sample(texSampler, clamp(lowerBlurUV + float2(-blurRadius, 0.0), 0.001, 0.999)) * 0.16;
        lowerBlur += irisPlumeTex.sample(texSampler, clamp(lowerBlurUV + float2(0.0,  blurRadius), 0.001, 0.999)) * 0.16;
        lowerBlur += irisPlumeTex.sample(texSampler, clamp(lowerBlurUV + float2(0.0, -blurRadius), 0.001, 0.999)) * 0.16;
        texDirectMask *= 1.0 - lowerMelt * 0.42;
        edgeReveal *= 1.0 - lowerMelt * 0.34;

        // lower eyeball melt-drip into slime: downward UV distortion
        float meltDripNoise = fbm(eyeEqNorm * 9.0 + float2(t * 0.025, -t * 0.018));
        float meltDrips = smoothstep(0.32, 0.62, meltDripNoise) * lowerMelt;
        float meltShiftY = meltDrips * 0.28 + lowerMelt * 0.10;
        float2 meltUV = float2(eyeEqNorm.x * 0.96 + 0.5, eyeEqNorm.y * 0.92 + 0.5 - meltShiftY);
        float3 meltTex = irisPlumeTex.sample(texSampler, clamp(meltUV, 0.001, 0.999)).rgb;
        float meltAlpha = meltDrips * 0.45 + lowerMelt * 0.18;
        texLayer.rgb = mix(texLayer.rgb, meltTex, meltAlpha);
        texLayer.a = max(texLayer.a, meltAlpha * 0.5);
        float lowerBufferBand = smoothstep(0.16, 0.34, eyeEqNorm.y) *
                                (1.0 - smoothstep(0.66, 0.98, abs(eyeEqNorm.x))) *
                                texRadial * eyeAppear;
        float lowerCloud = fbm(eyeEqNorm * 7.5 + float2(t * 0.018, -t * 0.011));
        float lowerCloudFine = fbm(eyeEqNorm * 18.0 + float2(-t * 0.020, t * 0.014));
        float lowerCrackA = 1.0 - smoothstep(0.012, 0.045, abs(sin((eyeEqNorm.x * 9.5 + eyeEqNorm.y * 4.2 + lowerCloud * 2.7) * 3.14159)));
        float lowerCrackB = 1.0 - smoothstep(0.010, 0.040, abs(sin((eyeEqNorm.x * -5.8 + eyeEqNorm.y * 8.6 + lowerCloudFine * 2.0) * 3.14159)));
        float lowerCracks = (lowerCrackA * 0.55 + lowerCrackB * 0.45) *
                            smoothstep(0.36, 0.86, lowerCloudFine);
        float lowerSoftEdge = smoothstep(0.08, 0.42, lowerCloud) * (0.74 + 0.26 * lowerCloudFine);
        float lowerBuffer = clamp(lowerBufferBand * (0.46 + 0.34 * lowerSoftEdge + 0.26 * lowerCracks), 0.0, 1.0);
        float3 lowerBufferCol = mix(float3(0.006, 0.030, 0.105),
                                    float3(0.018, 0.105, 0.245),
                                    lowerSoftEdge);
        lowerBufferCol += float3(0.030, 0.20, 0.42) * lowerCracks * 0.45;

        float3 softenedEyeTex = mix(texLayer.rgb, lowerBlur.rgb, lowerMelt * 0.62);
        softenedEyeTex = mix(softenedEyeTex, lowerBufferCol, lowerBuffer * 0.46);
        float3 revealedTex = softenedEyeTex * 1.10 + float3(0.22, 0.40, 0.62) * edgeReveal * 0.10
                           + float3(0.64, 0.74, 0.84) * shellLight * texDirectAlpha * 0.08;
        float directEyeBlend = clamp(max(texDirectMask * 2.52, edgeReveal * 0.52), 0.0, 0.80);
        directEyeBlend *= 1.0 - lowerMelt * 0.20;
        col = mix(col, revealedTex, directEyeBlend);
        col = mix(col, lowerBufferCol, lowerBuffer * texDirectAlpha * 0.18);
        col += lowerBlur.rgb * lowerMelt * texDirectAlpha * 0.035;

        // ── Orange/red cloud streaks and cracks across upper eyeball ──
        float upperZone = smoothstep(0.02, 0.78, -sin(ang))       // upper hemisphere
                        * (1.0 - smoothstep(rh * 0.3, rh * 3.2, plen)); // within eye region
        float upperCloud = fbm(p * 6.5 + float2(t * 0.025, -t * 0.015));
        float upperCloudFine = fbm(p * 14.0 + float2(-t * 0.018, t * 0.022));
        float upperCrackA = 1.0 - smoothstep(0.010, 0.038, abs(sin((p.x * 7.5 + p.y * 3.8 + upperCloud * 2.4) * 3.14159)));
        float upperCrackB = 1.0 - smoothstep(0.008, 0.032, abs(sin((p.x * -6.2 + p.y * 7.0 + upperCloudFine * 2.8) * 3.14159)));
        float upperCracks = (upperCrackA * 0.55 + upperCrackB * 0.45) * smoothstep(0.32, 0.82, upperCloudFine);
        float upperCloudShape = upperCloud * (0.52 + 0.48 * upperCloudFine);
        float upperOrangeMask = upperZone * (0.48 + 0.35 * upperCloudShape + 0.22 * upperCracks) * eyeAppear;
        float3 upperOrangeCol = mix(float3(1.0, 0.28, 0.05), float3(0.95, 0.42, 0.10), upperCloudShape);
        upperOrangeCol = mix(upperOrangeCol, float3(1.0, 0.55, 0.25), upperCracks * 0.65);
        col += upperOrangeCol * upperOrangeMask * 0.42;

        // right warm zone (existing, kept)
        float rightWarmZone = smoothstep(-0.6, 1.2, sin(ang))
                            * smoothstep(0.05, 0.85, -sin(ang))
                            * (1.0 - smoothstep(rh * 0.4, rh * 2.8, plen));
        float rightWarmFbm = fbm(p * 5.0 + t * 0.03);
        float rightWarm = rightWarmZone * (0.55 + 0.45 * rightWarmFbm) * life;
        col += float3(1.0, 0.30, 0.06) * rightWarm * 0.06;

        // ── inner photon ring (AC010-B iter2: fully suppressed in central zone) ──
        float horizon = rh * 1.35;
        float ringWidth = max(0.003, rh * 0.04);  // narrower ring
        float ringBand = exp(-pow((plen - horizon) / ringWidth, 2.0));
        float runner = pow(smoothstep(0.72, 1.0, 0.5 + 0.5 * sin(theta * 9.0 - t * 6.2)), 6.0);
        float pulse = 1.0 + 1.2 * collapse * exp(-pow((plen - horizon * 1.05) / max(ringWidth * 1.5, 0.004), 2.0));
        float3 ringColor = float3(0.06, 0.55, 0.90) * (0.4 + 0.6 * runner);
        // AC010-B iter4: ring nearly invisible in central zone, faint outside
        float ringNearCentre = smoothstep(rh * 3.7, rh * 4.8, plen);
        col += ringColor * ringBand * vis * (0.03 + 0.06 * life) * pulse * ringNearCentre;
        col += float3(0.35, 0.65, 0.95) * ringBand * collapse * 0.08 * ringNearCentre;

        // ── Hard pupil with irregular cracked/cloudy edge following texture grain ──
        float pupilPlen = plen / max(rh, 1e-4);
        float pupilAngle = atan2(p.y, p.x);
        // multi-frequency noise aligned with eyeball texture direction
        float pupilNoiseLo = fbm(float2(p.x * 9.0 + t * 0.015, p.y * 9.0 - t * 0.012));
        float pupilNoiseHi = fbm(float2(p.x * 18.0 - t * 0.022, p.y * 18.0 + t * 0.018));
        float pupilNoiseEdge = fbm(float2(p.x * 26.0 + pupilAngle * 3.0, p.y * 26.0));
        float pupilCrack = 1.0 - smoothstep(0.010, 0.040, abs(sin(pupilAngle * 8.0 + pupilNoiseEdge * 5.0)));
        float pupilCloud = pupilNoiseLo * 0.55 + pupilNoiseHi * 0.30 + pupilCrack * 0.20;
        float pupilPerturb = (pupilCloud - 0.5) * 0.24; // ±12% radius perturbation
        float hardPupil1 = smoothstep(0.48, 0.78, pupilPlen + pupilPerturb);
        float3 pupilBlack = float3(0.0, 0.0, 0.003);
        float pupilFade1 = mix(1.0, hardPupil1, eyeAppear);
        col = mix(pupilBlack, col, pupilFade1);
        float hardPupil2 = smoothstep(0.31, 0.50, pupilPlen + pupilPerturb * 0.7);
        float pupilFade2 = mix(1.0, hardPupil2, eyeAppear);
        col = mix(float3(0.0, 0.0, 0.0), col, pupilFade2);

        // ── AC021: coarse-column non-Newtonian slime grey-model ──
        {
            float2 tailEq = eyeP / max(eyeSize, 1e-4);
            float stretch = slimeStretch;
            float s = clamp(stretch, 0.0, 1.0);
            float sourceP = slimeAppear;
            float slowFall = pow(s, 1.56);
            float shoulderP = max(smoothstep(0.0, 0.055, s), sourceP * 0.82);
            float mergeP = smoothstep(0.16, 0.82, s);
            float tailDown = smoothstep(0.045, 0.135, tailEq.y);
            float pupilRadialCut = smoothstep(0.42, 0.62, length(tailEq));
            float lowerContourPass = smoothstep(0.12, 0.22, tailEq.y);
            float tailPupilCut = mix(pupilRadialCut, 1.0, lowerContourPass);

            // AC024: source hugs the lower eyeball contour instead of starting below it.
            float yRoot = 0.125;
            float yTip = mix(0.195, 2.62, slowFall);
            float yNorm = clamp((tailEq.y - yRoot) / max(yTip - yRoot, 0.04), 0.0, 1.0);
            float nLo = fbm(float2(tailEq.x * 3.2 + t * 0.012, tailEq.y * 1.1 - t * 0.010));
            float nHi = fbm(tailEq * 9.0 + float2(t * 0.015, -t * 0.022));
            float nEdge = fbm(float2(tailEq.x * 12.0 + t * 0.018, tailEq.y * 5.2 - t * 0.020));
            float boundaryWave = 0.5 + 0.5 * sin(tailEq.y * 10.5 + nLo * 6.0 + t * 0.030);
            float sideWander = ((nLo - 0.5) * 0.065 + (nEdge - 0.5) * 0.035) * s;

            // Sample eyeball texture RGB lower boundary to create complementary seam shape
            float2 seamUV = float2(tailEq.x * 0.48 + 0.50, clamp(tailEq.y * 0.44 + 0.42, 0.0, 1.0));
            float4 seamTexSample = irisPlumeTex.sample(texSampler, clamp(seamUV, 0.001, 0.999));
            float seamTexLum = dot(seamTexSample.rgb, float3(0.299, 0.587, 0.114));
            float seamTexVisible = max(seamTexSample.a, seamTexLum);
            float seamComplement = 1.0 - smoothstep(0.06, 0.28, seamTexVisible);
            float seamContour = seamComplement * smoothstep(0.04, 0.18, tailEq.y) * (1.0 - smoothstep(0.30, 0.50, length(tailEq)));

            // Wide shoulder reservoirs peel off the lower eyeball contour first.
            float shoulderY = exp(-pow((tailEq.y - 0.175) / 0.105, 2.0));
            float leftShoulder = exp(-pow((tailEq.x + 0.215) / 0.180, 2.0)) * shoulderY * (1.0 + seamContour * 0.6);
            float rightShoulder = exp(-pow((tailEq.x - 0.215) / 0.180, 2.0)) * shoulderY * (1.0 + seamContour * 0.6);

            // Coarse rivulets: broad at the eye contour, narrowing and converging toward the centre.
            float leftLine = mix(-0.245, -0.030, pow(yNorm, 0.72)) + sideWander * (1.0 - yNorm * 0.45);
            float rightLine = mix(0.245, 0.030, pow(yNorm, 0.72)) - sideWander * (0.85 - yNorm * 0.35);
            float centreLine = (nLo - 0.5) * 0.035 * yNorm * s;
            float sideWidth = mix(0.215, 0.078, pow(yNorm, 0.82)) * (0.92 + 0.20 * nEdge);
            float centreWidth = mix(0.255, 0.118, pow(yNorm, 0.94)) * (0.95 + 0.18 * nLo);
            float yBodyGate = smoothstep(yRoot - 0.045, yRoot + 0.060, tailEq.y);

            float frontNoise = (nHi - 0.5) * 0.115 + sin(tailEq.x * 17.0 + t * 0.07) * 0.026;
            float front = yTip + frontNoise * (0.35 + 0.65 * yNorm);
            float frontGate = 1.0 - smoothstep(front - 0.10, front + 0.075, tailEq.y);
            float sideColumns = (exp(-pow((tailEq.x - leftLine) / sideWidth, 2.0)) +
                                 exp(-pow((tailEq.x - rightLine) / sideWidth, 2.0))) * shoulderP;
            float centreSheet = exp(-pow((tailEq.x - centreLine) / centreWidth, 2.0)) * mergeP;
            float curtain = max(sideColumns * 0.82, centreSheet * 0.92);

            // Rounded heavy front: the flow advances as a slow thick tongue, not a flat rectangular wipe.
            float tongueWidth = mix(0.245, 0.115, yNorm);
            float tongue = exp(-(pow((tailEq.x - centreLine) / max(tongueWidth, 0.04), 2.0) +
                                  pow((tailEq.y - yTip) / mix(0.150, 0.255, s), 2.0)));
            float lowerNeck = exp(-pow((tailEq.x - centreLine) / mix(0.170, 0.085, yNorm), 2.0)) *
                              smoothstep(0.38, 0.90, yNorm);
            float heavyCoreWidth = mix(0.190, 0.118, pow(yNorm, 0.76));
            float heavyCore = exp(-pow((tailEq.x - centreLine) / max(heavyCoreWidth, 0.04), 2.0)) *
                              smoothstep(0.12, 0.92, yNorm) * frontGate;

            float thicknessNoise = 0.88 + 0.24 * nLo + 0.11 * nHi;
            float seamBlend = seamContour * shoulderP * yBodyGate * (1.0 - yNorm * 0.7);
            float density = (seamBlend * 0.55 +
                             (leftShoulder + rightShoulder) * 0.48 * shoulderP +
                             curtain * 1.10 * yBodyGate * frontGate +
                             tongue * 0.86 * smoothstep(0.08, 0.98, s) +
                             lowerNeck * 0.42 * mergeP +
                             heavyCore * 0.46 * mergeP) * thicknessNoise;

            // Smooth free-surface threshold for a broad non-Newtonian column with ragged edges.
            float freeSurface = smoothstep(0.25, 0.45, density) * (1.0 - smoothstep(0.65, 0.95, density));
            float edgeNoise = (nHi - 0.5) * 0.055 + (nLo - 0.5) * 0.034 +
                              (nEdge - 0.5) * 0.065 * freeSurface +
                              (boundaryWave - 0.5) * 0.040 * freeSurface;
            float gooMask = smoothstep(0.34, 0.50, density + edgeNoise);
            float volumeCore = smoothstep(0.54, 0.86, density);
            float tailAlpha = gooMask * tailDown * tailPupilCut * slimeAppear;
            tailAlpha *= frontGate * (1.05 + 0.28 * volumeCore);

            float2 flowWarp = float2((nHi - 0.5) * 0.045, -t * 0.014 - slowFall * 0.075);
            float2 tailUV = float2(tailEq.x * 0.48 + 0.50,
                                   mix(0.08, 0.88, yNorm)) + flowWarp;
            float globalTileRate = mix(0.34, 0.62, smoothstep(0.18, 0.88, yNorm));
            float2 tailTileUV = float2(tailEq.x * 0.42 + 0.50 + (nLo - 0.5) * 0.055,
                                       fract((tailEq.y - yRoot) * globalTileRate - t * 0.012 + nHi * 0.10));
            tailTileUV.y = mix(0.08, 0.92, tailTileUV.y);
            float2 sourceStretchUV = float2(tailEq.x * mix(0.50, 0.28, yNorm) + 0.50 + (nHi - 0.5) * 0.035,
                                            mix(0.54, 0.80, pow(yNorm, 0.68)) - slowFall * 0.030 - t * 0.006);
            float2 irisLiquefyUV = float2(tailEq.x * mix(0.54, 0.32, yNorm) + 0.50 + (nLo - 0.5) * 0.045,
                                          mix(0.52, 0.72, pow(yNorm, 0.54)) + (nHi - 0.5) * 0.030);
            float4 tailSample = slimeTex.sample(texSampler, clamp(tailUV, 0.001, 0.999));
            float4 tailTileSample = slimeTex.sample(texSampler, clamp(tailTileUV, 0.001, 0.999));
            float4 sourceStretchSample = slimeTex.sample(texSampler, clamp(sourceStretchUV, 0.001, 0.999));
            float4 irisLiquefySample = irisPlumeTex.sample(texSampler, clamp(irisLiquefyUV, 0.001, 0.999));
            float verticalStreak = pow(smoothstep(0.50, 1.0, fbm(float2(tailEq.x * 18.0 + nLo * 2.0, tailEq.y * 2.4 - t * 0.020))), 2.2);
            float textureVein = pow(smoothstep(0.40, 0.92, fbm(float2(tailEq.x * 24.0 + nHi * 3.0, yNorm * 9.5 - t * 0.030))), 1.8);
            float edgeRim = smoothstep(0.26, 0.38, density + edgeNoise) * (1.0 - smoothstep(0.55, 0.85, density));
            float massCore = volumeCore;
            float sourceWeight = smoothstep(0.02, 0.82, yNorm) * (0.40 + 0.32 * massCore);
            float irisWeight = smoothstep(0.00, 0.70, yNorm) * (1.0 - smoothstep(0.82, 1.0, yNorm)) * 0.30;
            float3 sampledSlime = mix(tailSample.rgb, tailTileSample.rgb, 0.54);
            sampledSlime = mix(sampledSlime, sourceStretchSample.rgb, sourceWeight);
            sampledSlime = mix(sampledSlime, irisLiquefySample.rgb, irisWeight);
            float sampledLum = max(max(sampledSlime.r, sampledSlime.g), sampledSlime.b);
            sampledSlime = mix(float3(0.040, 0.28, 0.48), sampledSlime, smoothstep(0.025, 0.18, sampledLum));
            float3 tailRgb = mix(float3(0.015, 0.18, 0.38), sampledSlime, 0.90);
            float volumeShadow = massCore * (0.36 + 0.26 * smoothstep(0.22, 0.92, yNorm)) * (1.0 - edgeRim * 0.55);
            float3 deepVolume = sampledSlime * float3(0.34, 0.58, 0.78) + float3(0.004, 0.040, 0.11);
            tailRgb = mix(tailRgb, deepVolume, clamp(volumeShadow, 0.0, 0.48));
            tailRgb = mix(tailRgb, float3(0.08, 0.56, 0.90), edgeRim * 0.38);
            // white mucus streaks and specular sheen
            float mucusSheen = fbm(float2(tailEq.x * 14.0 + nHi * 2.5, yNorm * 8.0 - slowFall * 1.2));
            float mucusVein = pow(smoothstep(0.52, 0.72, mucusSheen), 1.8);
            float surfaceGloss = edgeRim * (0.66 + 0.52 * mucusVein) + mucusVein * gooMask * 0.26;
            tailRgb += float3(0.80, 0.93, 1.0) * (verticalStreak * 0.26 + massCore * 0.12 + textureVein * 0.16 + surfaceGloss * 0.38);
            tailRgb += float3(0.92, 0.96, 1.0) * mucusVein * gooMask * 0.28;
            // orange-red warm mucus accents
            float warmMucusNoise = fbm(float2(tailEq.x * 11.0 + nLo * 3.0, yNorm * 6.5 - slowFall * 0.8));
            float warmMucusVein = pow(smoothstep(0.48, 0.78, warmMucusNoise), 1.4);
            float warmMucusMask = warmMucusVein * gooMask * (0.55 + 0.45 * (1.0 - yNorm));
            tailRgb = mix(tailRgb, float3(0.92, 0.32, 0.08), warmMucusMask * 0.22);
            tailRgb += float3(1.0, 0.45, 0.12) * warmMucusVein * edgeRim * 0.15;
            // deep cyan-blue viscous texture
            float deepBlueNoise = fbm(float2(tailEq.x * 13.0 + nEdge * 2.0, yNorm * 7.0 - slowFall * 0.6));
            float deepBlueVein = pow(smoothstep(0.50, 0.80, deepBlueNoise), 1.5);
            float deepBlueMask = deepBlueVein * gooMask * (0.45 + 0.55 * yNorm) * (1.0 - edgeRim * 0.6);
            tailRgb = mix(tailRgb, float3(0.01, 0.15, 0.36), deepBlueMask * 0.28);
            tailRgb += float3(0.02, 0.22, 0.52) * deepBlueVein * volumeCore * 0.18;
            tailRgb = mix(tailRgb, tailRgb * float3(0.72, 1.03, 1.14), textureVein * 0.24);
            tailRgb = mix(tailRgb, tailRgb * float3(0.72, 0.90, 1.05), (1.0 - edgeRim) * 0.20);
            tailRgb *= 0.80 + 0.22 * smoothstep(0.0, 0.85, 1.0 - yNorm);
            col = mix(col, tailRgb, clamp(tailAlpha * 1.12, 0.0, 0.98));
        }

        // ── outer composite: deep blue cosmic tint for far bg ──
        float farBg = smoothstep(0.45, 1.2, plen) * (1.0 - smoothstep(0.0, 0.35, plen));
        col = mix(col, col + float3(0.02, 0.06, 0.18), farBg * 0.3 * life);

        return float4(mix(baseColor, col, influence), 1.0);
    }
    """
}
