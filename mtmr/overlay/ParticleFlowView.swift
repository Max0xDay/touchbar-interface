import Cocoa
import QuartzCore

final class ParticleFlowView: NSView {
    static let defaultCount = 30
    static let defaultSeconds = 5.5
    static let defaultColor = NSColor(srgbRed: 52 / 255, green: 199 / 255, blue: 89 / 255, alpha: 1)

    private var completion: DispatchWorkItem?

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
        stop()
        guard bounds.width > 0, bounds.height > 0 else {
            removeFromSuperview()
            return
        }
        let startedAt = CACurrentMediaTime()
        let spawnSeconds = seconds * (3.5 / Self.defaultSeconds)
        CATransaction.begin()
        CATransaction.setDisableActions(true)
        fadeEffect(seconds: seconds)
        for index in 0..<count {
            let spawnFraction = (Double(index) + Double.random(in: 0...1)) / Double(count)
            let delay = spawnSeconds * spawnFraction
            let lifetime = min(seconds - delay, seconds * Double.random(in: 2.0...3.0) / Self.defaultSeconds)
            addParticle(color: color, style: style, lifetime: lifetime, beginsAt: startedAt + delay)
        }
        CATransaction.commit()
        let completion = DispatchWorkItem { [weak self] in
            self?.stop()
            self?.removeFromSuperview()
        }
        self.completion = completion
        DispatchQueue.main.asyncAfter(deadline: .now() + seconds, execute: completion)
    }

    func stop() {
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
        opacity.keyTimes = [0, 0.12, 0.85, 1]
        opacity.duration = seconds
        opacity.timingFunctions = Array(repeating: CAMediaTimingFunction(name: .easeInEaseOut), count: 3)
        layer?.add(opacity, forKey: "chargingFade")
    }

    private func addParticle(color: NSColor, style: String, lifetime: Double, beginsAt: Double) {
        let diameter = CGFloat.random(in: 1.3...2.8)
        let length = style == "sparks" ? diameter * CGFloat.random(in: 4...6) : diameter * 2.2
        let particle = CALayer()
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
        animate(particle, lifetime: lifetime, beginsAt: beginsAt)
    }

    private func motion(for particle: CALayer) -> CAKeyframeAnimation {
        let start = -particle.bounds.width / 2
        let end = bounds.width * CGFloat.random(in: 0.7...1)
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

    private func animate(_ particle: CALayer, lifetime: Double, beginsAt: Double) {
        let position = motion(for: particle)
        position.duration = lifetime
        let brightness = Double.random(in: 0...1) < 0.2 ? Double.random(in: 0.12...0.25) : Double.random(in: 0.45...0.8)
        let opacity = CAKeyframeAnimation(keyPath: "opacity")
        opacity.values = [0, brightness, brightness * 0.85, 0]
        opacity.keyTimes = [0, 0.15, 0.8, 1]
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
        particle.add(animation, forKey: "particleFlow")
    }

    deinit { completion?.cancel() }
}
