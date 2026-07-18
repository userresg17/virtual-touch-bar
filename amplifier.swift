import Cocoa
import CoreAudio
import AudioToolbox
import IOKit.hid

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

// MARK: - Lógica pura do chord fn+x

/// Distingue um "tap" de fn (alterna a barra) de "fn segurado + x" (amplificador),
/// sem que o fn+x faça a barra piscar. Estado puro, testável.
struct ChordState {
    private var fnDown = false
    private var consumed = false

    /// Retorna true quando o soltar do fn deve alternar a barra (tap simples).
    mutating func onFnChanged(down: Bool) -> Bool {
        if down {
            fnDown = true
            consumed = false
            return false
        } else {
            let wasTap = fnDown && !consumed
            fnDown = false
            return wasTap
        }
    }

    /// Retorna true se o x deve ser tratado como chord (e engolido).
    mutating func onKeyX() -> Bool {
        guard fnDown else { return false }
        consumed = true
        return true
    }
}

// MARK: - Monitor de teclado (CGEventTap)
// Substitui o monitor NSEvent do fn: o event tap consegue ENGOLIR o x
// do chord (o NSEvent global só observa). Requer permissão de Acessibilidade,
// que o app já solicita.

final class InputMonitor {
    var onFnTap: (() -> Void)?
    var onAmplifierChord: (() -> Void)?

    private var state = ChordState()
    private var tap: CFMachPort?
    private static let keyCodeX: Int64 = 7   // tecla "x"

    func start() {
        // O CGEventTap de teclado exige a permissão de "Monitorização de Entrada"
        // (Input Monitoring), que é SEPARADA da Acessibilidade. Sem ela o tap é
        // criado mas nunca recebe eventos. Este pedido dispara o prompt do sistema.
        IOHIDRequestAccess(kIOHIDRequestTypeListenEvent)

        let mask = (1 << CGEventType.flagsChanged.rawValue) | (1 << CGEventType.keyDown.rawValue)
        let refcon = Unmanaged.passUnretained(self).toOpaque()

        guard let tap = CGEvent.tapCreate(
            tap: .cgSessionEventTap,
            place: .headInsertEventTap,
            options: .defaultTap,                 // pode alterar/descartar eventos
            eventsOfInterest: CGEventMask(mask),
            callback: { _, type, event, refcon in
                let monitor = Unmanaged<InputMonitor>.fromOpaque(refcon!).takeUnretainedValue()
                return monitor.handle(type: type, event: event)
            },
            userInfo: refcon
        ) else {
            NSLog("Amplificador: falha ao criar CGEventTap (Acessibilidade?)")
            return
        }
        self.tap = tap
        let source = CFMachPortCreateRunLoopSource(kCFAllocatorDefault, tap, 0)
        CFRunLoopAddSource(CFRunLoopGetCurrent(), source, .commonModes)
        CGEvent.tapEnable(tap: tap, enable: true)
    }

    private func handle(type: CGEventType, event: CGEvent) -> Unmanaged<CGEvent>? {
        // Reabilita o tap se o sistema o desligar por timeout.
        if type == .tapDisabledByTimeout || type == .tapDisabledByUserInput {
            if let tap = tap { CGEvent.tapEnable(tap: tap, enable: true) }
            return Unmanaged.passUnretained(event)
        }

        let fnDown = event.flags.contains(.maskSecondaryFn)

        if type == .flagsChanged {
            // Só reage à transição do próprio fn (keyCode 63); ignora outros modificadores.
            if event.getIntegerValueField(.keyboardEventKeycode) == 63 {
                if state.onFnChanged(down: fnDown) {
                    DispatchQueue.main.async { [weak self] in self?.onFnTap?() }
                }
            }
            return Unmanaged.passUnretained(event)
        }

        if type == .keyDown,
           event.getIntegerValueField(.keyboardEventKeycode) == InputMonitor.keyCodeX,
           state.onKeyX() {
            DispatchQueue.main.async { [weak self] in self?.onAmplifierChord?() }
            return nil   // engole o x pra não digitar "x"
        }

        return Unmanaged.passUnretained(event)
    }
}
