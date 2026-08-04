// SPDX-License-Identifier: MPL-2.0

struct DynamicsSuppressionMixer {
    private var suppressionMix: Float = 0

    mutating func mix(
        _ frame: DelayedDynamicsFrame,
        parameters: DynamicsRuntimeParameters
    ) -> (left: Float, right: Float, failed: Bool) {
        let target = frame.wetValid ? frame.suppressionTarget : 0
        if target > suppressionMix {
            suppressionMix = min(target, suppressionMix + parameters.suppressionAttackStep)
        } else if target < suppressionMix {
            suppressionMix = max(target, suppressionMix - parameters.suppressionReleaseStep)
        }
        guard frame.wetValid, suppressionMix > 0 else {
            return (frame.left, frame.right, false)
        }
        let dryMix = 1 - suppressionMix
        let left = frame.left * dryMix + frame.wetLeft * suppressionMix
        let right = frame.right * dryMix + frame.wetRight * suppressionMix
        guard left.isFinite, right.isFinite else { return (0, 0, true) }
        return (left, right, false)
    }

    mutating func reset() {
        suppressionMix = 0
    }
}
