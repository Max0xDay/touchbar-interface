import Cocoa
import QuartzCore

private final class TrickleParticleLayer: CALayer, CAAnimationDelegate {
    func animationDidStop(_ animation: CAAnimation, finished: Bool) {
        removeFromSuperlayer()
    }
}

final class ParticleFlowView: NSView {
    static let defaultCount = 45
    static let defaultSeconds = 2.5
    static let defaultColor = NSColor(srgbRed: 52 / 255, green: 199 / 255, blue: 89 / 255, alpha: 1)

    private var completion: DispatchWorkItem?
    private var emission: DispatchWorkItem?
    private var trickling = false
    private var burstActive = false

    static func trickleInterval() -> Double { Double.random(in: 0.8...1.6) }
    static func canEmitTrickle(activeCount: Int) -> Bool { activeCount < 4 }

    static func burstTiming(spawnFraction: Double, seconds: Double) -> (delay: Double, lifetime: Double) {
        let delay = seconds * 0.24 * spawnFraction * spawnFraction
        let lifetime = min(seconds - delay, seconds * Double.random(in: 0.48...0.8))
        return (delay, lifetime)
    }

    func setTrickling(_ enabled: Bool) {
        guard trickling != enabled else { return }
        trickling = enabled
        emission?.cancel()
        emission = nil
        if enabled && !burstActive { scheduleTrickle() }
    }

    private func scheduleTrickle() {
        guard trickling else { return }
        guard window != nil else { return }
        let emission = DispatchWorkItem { [weak self] in
            guard let self = self else { return }
            self.emission = nil
            guard self.trickling else { return }
            guard self.window?.isVisible == true, !self.isHiddenOrHasHiddenAncestor else {
                self.stop()
                return
            }
            let now = CACurrentMediaTime()
            self.layer?.sublayers?.filter { ($0.value(forKey: "expiresAt") as? Double ?? 0) <= now }.forEach { $0.removeFromSuperlayer() }
            if Self.canEmitTrickle(activeCount: self.layer?.sublayers?.count ?? 0) {
                self.addParticle(color: Self.defaultColor, style: "dots", lifetime: Double.random(in: 3.2...4.2), beginsAt: now, trickle: true)
            }
            self.scheduleTrickle()
        }
        self.emission = emission
        DispatchQueue.main.asyncAfter(deadline: .now() + Self.trickleInterval(), execute: emission)
    }

    override init(frame frameRect: NSRect) {
        super.init(frame: frameRect)
        wantsLayer = true
        layer?.masksToBounds = true
    }

    required init?(coder: NSCoder) { return nil }

    override func hitTest(_ point: NSPoint) -> NSView? { return nil }

    override func viewDidMoveToWindow() {
        super.viewDidMoveToWindow()
        if window == nil {
            stop()
            removeFromSuperview()
        }
    }

    func play(count: Int = defaultCount, seconds: Double = defaultSeconds, color: NSColor = defaultColor, style: String = "dots") {
        let resumeTrickle = trickling
        stop()
        trickling = resumeTrickle
        burstActive = true
        guard bounds.width > 0, bounds.height > 0 else {
            removeFromSuperview()
            return
        }
        let startedAt = CACurrentMediaTime()
        CATransaction.begin()
        CATransaction.setDisableActions(true)
        fadeEffect(seconds: seconds)
        for index in 0..<count {
            let spawnFraction = (Double(index) + Double.random(in: 0...1)) / Double(count)
            let timing = Self.burstTiming(spawnFraction: spawnFraction, seconds: seconds)
            addParticle(color: color, style: style, lifetime: timing.lifetime, beginsAt: startedAt + timing.delay)
        }
        CATransaction.commit()
        let completion = DispatchWorkItem { [weak self] in
            guard let self = self else { return }
            let resumeTrickle = self.trickling
            self.stop()
            self.setTrickling(resumeTrickle)
        }
        self.completion = completion
        DispatchQueue.main.asyncAfter(deadline: .now() + seconds, execute: completion)
    }

    func stop() {
        trickling = false
        burstActive = false
        emission?.cancel()
        emission = nil
        completion?.cancel()
        completion = nil
        layer?.removeAllAnimations()
        layer?.sublayers?.forEach {
            $0.removeAllAnimations()
            $0.removeFromSuperlayer()
        }
    }

    private func fadeEffect(seconds: Double) {
        let opacity = CAKeyframeAnimation(keyPath: "opacity")
        opacity.values = [0, 1, 1, 0]
        opacity.keyTimes = [0, 0.02, 0.9, 1]
        opacity.duration = seconds
        opacity.timingFunctions = Array(repeating: CAMediaTimingFunction(name: .easeInEaseOut), count: 3)
        layer?.add(opacity, forKey: "chargingFade")
    }

    private func addParticle(color: NSColor, style: String, lifetime: Double, beginsAt: Double, trickle: Bool = false) {
        let diameter = CGFloat.random(in: trickle ? 1.3...1.8 : 1.3...2.8)
        let length = style == "sparks" ? diameter * CGFloat.random(in: 4...6) : diameter * 2.2
        let particle = trickle ? TrickleParticleLayer() : CALayer()
        particle.bounds = CGRect(x: 0, y: 0, width: length, height: diameter)
        particle.opacity = 0
        particle.shadowColor = color.cgColor
        particle.shadowOpacity = 0.4
        particle.shadowRadius = 2
        particle.shadowOffset = .zero
        let trail = CAGradientLayer()
        trail.frame = particle.bounds
        trail.colors = [color.withAlphaComponent(0).cgColor, color.withAlphaComponent(0.35).cgColor, color.cgColor]
        trail.locations = [0, 0.65, 1]
        trail.startPoint = CGPoint(x: 0, y: 0.5)
        trail.endPoint = CGPoint(x: 1, y: 0.5)
        trail.cornerRadius = diameter / 2
        particle.addSublayer(trail)
        let head = CALayer()
        head.frame = CGRect(x: length - diameter, y: 0, width: diameter, height: diameter)
        head.cornerRadius = diameter / 2
        head.backgroundColor = color.blended(withFraction: 0.25, of: .white)?.cgColor ?? color.cgColor
        particle.addSublayer(head)
        layer?.addSublayer(particle)
        particle.setValue(beginsAt + lifetime, forKey: "expiresAt")
        animate(particle, lifetime: lifetime, beginsAt: beginsAt, trickle: trickle)
    }

    private func motion(for particle: CALayer, trickle: Bool) -> CAKeyframeAnimation {
        let start = -particle.bounds.width / 2
        let end = bounds.width * CGFloat.random(in: 0.7...1) * (trickle ? 0.75 : 1)
        let amplitude = min(CGFloat.random(in: 1...3), bounds.height / 4)
        let inset = min(particle.bounds.height / 2 + amplitude + 1, bounds.height / 2)
        let verticalPosition = CGFloat.random(in: inset...(bounds.height - inset))
        let phase = CGFloat.random(in: 0...(2 * .pi))
        let frequency = CGFloat.random(in: 0.7...1.5)
        let position = CAKeyframeAnimation(keyPath: "position")
        position.values = (0...40).map { index in
            let progress = CGFloat(index) / 40
            let travel = progress * progress * (2 - progress)
            let wobble = sin(phase + progress * frequency * 2 * .pi) * amplitude
            return NSValue(point: NSPoint(x: start + (end - start) * travel, y: verticalPosition + wobble))
        }
        position.calculationMode = .linear
        return position
    }

    private func animate(_ particle: CALayer, lifetime: Double, beginsAt: Double, trickle: Bool) {
        let position = motion(for: particle, trickle: trickle)
        position.duration = lifetime
        let brightness = Double.random(in: 0.65...0.9)
        let opacity = CAKeyframeAnimation(keyPath: "opacity")
        let particleBrightness = brightness * (trickle ? Double.random(in: 0.8...0.95) : 1)
        let launchBrightness = trickle ? particleBrightness : min(1, particleBrightness * 1.15)
        opacity.values = [0, launchBrightness, particleBrightness * 0.85, 0]
        opacity.keyTimes = [0, trickle ? 0.15 : 0.05, 0.8, 1]
        opacity.duration = lifetime
        let scale = CAKeyframeAnimation(keyPath: "transform.scale")
        scale.values = [0.6, 1, 1, 0.05]
        scale.keyTimes = [0, 0.15, 0.8, 1]
        scale.duration = lifetime
        let animation = CAAnimationGroup()
        animation.animations = [position, opacity, scale]
        animation.duration = lifetime
        animation.beginTime = beginsAt
        animation.timingFunction = CAMediaTimingFunction(name: .linear)
        // #COMPLETION_DRIVE: Layer-backed animations composite over the private Touch Bar host without intercepting direct touches.
        // #SUGGEST_VERIFY: Check dots/sparks, dissipating endpoints and underlying button taps on the real bar.
        if trickle { animation.delegate = particle as? TrickleParticleLayer }
        particle.add(animation, forKey: "particleFlow")
    }

    deinit {
        completion?.cancel()
        emission?.cancel()
    }
}
