import Cocoa
import CoreAudio
import AudioToolbox

// MARK: - DSP puro (ganho + limiter)
// Funções puras, testáveis via --selftest, sem tocar em hardware.

/// Converte porcentagem (100–400) em multiplicador linear (1.0–4.0).
/// 400% = +12 dB, o teto de segurança combinado.
func gainMultiplier(percent: Int) -> Float {
    let clamped = max(100, min(400, percent))
    return Float(clamped) / 100.0
}

/// Limiter feed-forward simples: nunca deixa a amostra passar do threshold,
/// preservando o sinal. Estado de envelope suaviza a redução (ataque/release).
struct Limiter {
    var threshold: Float = 0.9
    private var envelope: Float = 1.0        // ganho de redução atual (1 = sem redução)
    private let attack: Float = 0.4          // quão rápido segura (0–1 por amostra)
    private let release: Float = 0.002       // quão devagar solta

    init(threshold: Float = 0.9) {
        self.threshold = threshold
    }

    mutating func process(_ x: Float) -> Float {
        let peak = abs(x)
        // ganho de redução desejado pra manter |x*g| <= threshold
        let desired = peak > threshold ? threshold / peak : 1.0
        // ataca rápido (desce o envelope), solta devagar (sobe)
        if desired < envelope {
            envelope += (desired - envelope) * attack
        } else {
            envelope += (desired - envelope) * release
        }
        let out = x * envelope
        // trava dura de segurança contra qualquer overshoot numérico
        return max(-threshold, min(threshold, out))
    }
}

/// Aproxima `current` de `target` em no máximo `step` por chamada (ramp anti-"pop").
func rampedGain(current: Float, target: Float, step: Float) -> Float {
    if abs(target - current) <= step { return target }
    return current + (target > current ? step : -step)
}
