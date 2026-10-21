import QuartzCore

/// Swing animations. All rotations are additive, so the idle sway, pushes and settling
/// combine naturally, and all of them run in the render server, not in our process.
enum Motion {
    static let rotation = "transform.rotation.z"

    /// Endless gentle sway that starts from rest, so it can be added at any time without a jump.
    static func idleSway(amplitude: CGFloat) -> CAKeyframeAnimation {
        let anim = CAKeyframeAnimation(keyPath: rotation)
        anim.values = [0, amplitude, 0, -amplitude, 0]
        anim.keyTimes = [0, 0.25, 0.5, 0.75, 1]
        anim.calculationMode = .cubic
        anim.duration = Double.random(in: 2.9...3.9)
        anim.repeatCount = .infinity
        anim.isAdditive = true
        anim.beginTime = CACurrentMediaTime() + Double.random(in: 0...1.2)
        return anim
    }

    /// A push that swings and dies away: A·e^(−kt)·sin(ωt). Starts at rest, so there is no jump.
    static func push(amplitude: CGFloat, period: Double = 1.1, decay: Double = 1.9, delay: Double = 0) -> CAKeyframeAnimation {
        let duration = 2.4
        let steps = 48
        var values: [CGFloat] = []
        var times: [NSNumber] = []
        for i in 0...steps {
            let t = duration * Double(i) / Double(steps)
            let v = Double(amplitude) * exp(-decay * t) * sin(2 * .pi * t / period)
            values.append(CGFloat(v))
            times.append(NSNumber(value: Double(i) / Double(steps)))
        }
        values[values.count - 1] = 0
        let anim = CAKeyframeAnimation(keyPath: rotation)
        anim.values = values
        anim.keyTimes = times
        anim.duration = duration
        anim.isAdditive = true
        if delay > 0 {
            anim.beginTime = CACurrentMediaTime() + delay
            anim.fillMode = .backwards
        }
        return anim
    }

    /// Brings a swinging photo smoothly to rest from its current angle, without overshoot.
    static func settle(from angle: CGFloat, duration: Double = 0.35) -> CAKeyframeAnimation {
        let steps = 14
        var values: [CGFloat] = []
        for i in 0...steps {
            let t = Double(i) / Double(steps)
            values.append(angle * CGFloat(pow(1 - t, 3)))
        }
        let anim = CAKeyframeAnimation(keyPath: rotation)
        anim.values = values
        anim.duration = duration
        anim.isAdditive = true
        return anim
    }

    /// Spring for moving along the rope and dropping in.
    static func spring(keyPath: String, from: Any?, to: Any?, damping: CGFloat = 16, stiffness: CGFloat = 170) -> CASpringAnimation {
        let anim = CASpringAnimation(keyPath: keyPath)
        anim.fromValue = from
        anim.toValue = to
        anim.mass = 1
        anim.damping = damping
        anim.stiffness = stiffness
        anim.duration = anim.settlingDuration
        return anim
    }

    static func removeRotations(from layer: CALayer) {
        for key in layer.animationKeys() ?? [] where key.hasPrefix("rot.") {
            layer.removeAnimation(forKey: key)
        }
    }

    static func currentRotation(of layer: CALayer) -> CGFloat {
        (layer.presentation()?.value(forKeyPath: rotation) as? CGFloat) ?? 0
    }
}
