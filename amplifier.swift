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

// MARK: - Motor de amplificação (Core Audio process tap, macOS 14.4+)

@available(macOS 14.4, *)
final class AudioAmplifier {
    static let shared = AudioAmplifier()

    private(set) var isOn = false
    private(set) var percent = 100

    private var tapID = AudioObjectID(kAudioObjectUnknown)
    private var aggregateID = AudioObjectID(kAudioObjectUnknown)
    private var ioProcID: AudioDeviceIOProcID?
    private var aggregateUID = ""

    // Estado de DSP (usado dentro do IOProc, na thread de áudio).
    private var currentGain: Float = 1.0
    private var targetGain: Float = 1.0
    private var limiterL = Limiter(threshold: 0.98)
    private var limiterR = Limiter(threshold: 0.98)
    private let rampStep: Float = 0.0015   // ~30 ms a 48 kHz por bloco

    private let mainElement = AudioObjectPropertyElement(kAudioObjectPropertyElementMain)

    // MARK: Memória por dispositivo (UserDefaults)
    // Cada dispositivo de saída (identificado pelo UID, estável entre reconexões)
    // guarda seu próprio ganho preferido — útil pra BT, que costuma precisar de
    // mais boost que os alto-falantes internos.
    private let memoryKey = "amplifierGainByDevice"

    private func savePercentForCurrentDevice() {
        guard let dev = defaultOutputDevice(), let uid = deviceUID(dev) else { return }
        var map = UserDefaults.standard.dictionary(forKey: memoryKey) as? [String: Int] ?? [:]
        map[uid] = percent
        UserDefaults.standard.set(map, forKey: memoryKey)
    }

    private func savedPercentForCurrentDevice() -> Int? {
        guard let dev = defaultOutputDevice(), let uid = deviceUID(dev) else { return nil }
        let map = UserDefaults.standard.dictionary(forKey: memoryKey) as? [String: Int] ?? [:]
        return map[uid]
    }

    // MARK: Observação de mudança de dispositivo
    // Se a saída padrão cai (ex.: soundbar BT desconecta) ou troca enquanto o
    // boost está ligado, o grafo antigo aponta pro dispositivo errado/morto —
    // é preciso derrubar e remontar no dispositivo novo, sem travar o áudio.
    private var listenerBlock: AudioObjectPropertyListenerBlock?
    private var deviceObserverStarted = false   // evita registrar o listener mais de uma vez

    private func startDeviceObserver() {
        guard !deviceObserverStarted else { return }
        deviceObserverStarted = true
        var addr = AudioObjectPropertyAddress(
            mSelector: kAudioHardwarePropertyDefaultOutputDevice,
            mScope: kAudioObjectPropertyScopeGlobal, mElement: mainElement)
        let block: AudioObjectPropertyListenerBlock = { [weak self] _, _ in
            DispatchQueue.main.async { self?.handleDeviceChange() }
        }
        listenerBlock = block
        AudioObjectAddPropertyListenerBlock(
            AudioObjectID(kAudioObjectSystemObject), &addr, DispatchQueue.main, block)
    }

    // A saída mudou (ex.: soundbar BT caiu). Derruba o grafo com segurança e,
    // se o boost estava ligado, remonta no novo dispositivo aplicando a memória.
    private func handleDeviceChange() {
        let wasOn = isOn
        if wasOn { destroyGraph(); isOn = false }
        if let saved = savedPercentForCurrentDevice() { percent = saved; targetGain = gainMultiplier(percent: percent) }
        if wasOn {
            currentGain = 1.0
            _ = start()
        }
    }

    // MARK: Dispositivo de saída atual

    private func defaultOutputDevice() -> AudioObjectID? {
        var device = AudioObjectID(0)
        var size = UInt32(MemoryLayout<AudioObjectID>.size)
        var addr = AudioObjectPropertyAddress(
            mSelector: kAudioHardwarePropertyDefaultOutputDevice,
            mScope: kAudioObjectPropertyScopeGlobal, mElement: mainElement)
        let ok = AudioObjectGetPropertyData(
            AudioObjectID(kAudioObjectSystemObject), &addr, 0, nil, &size, &device)
        return ok == noErr ? device : nil
    }

    private func deviceUID(_ device: AudioObjectID) -> String? {
        var addr = AudioObjectPropertyAddress(
            mSelector: kAudioDevicePropertyDeviceUID,
            mScope: kAudioObjectPropertyScopeGlobal, mElement: mainElement)
        var uid: CFString = "" as CFString
        var size = UInt32(MemoryLayout<CFString>.size)
        let ok = AudioObjectGetPropertyData(device, &addr, 0, nil, &size, &uid)
        return ok == noErr ? (uid as String) : nil
    }

    func currentOutputName() -> String {
        guard let dev = defaultOutputDevice() else { return "saída desconhecida" }
        var addr = AudioObjectPropertyAddress(
            mSelector: kAudioObjectPropertyName,
            mScope: kAudioObjectPropertyScopeGlobal, mElement: mainElement)
        var name: CFString = "" as CFString
        var size = UInt32(MemoryLayout<CFString>.size)
        guard AudioObjectGetPropertyData(dev, &addr, 0, nil, &size, &name) == noErr else {
            return "saída"
        }
        return name as String
    }

    // MARK: Montagem do tap + aggregate

    /// Cria o tap global mudo e um aggregate privado (dispositivo real + tap).
    /// Retorna false (e limpa tudo) em qualquer erro.
    private func buildGraph() -> Bool {
        guard let outDev = defaultOutputDevice(), let outUID = deviceUID(outDev) else { return false }

        // 1) Tap global (todos os processos), estéreo, mudo no caminho original.
        let tapDesc = CATapDescription(stereoGlobalTapButExcludeProcesses: [])
        tapDesc.name = "VirtualTouchBar Amplifier"
        tapDesc.isPrivate = true
        tapDesc.muteBehavior = .mutedWhenTapped
        var newTap = AudioObjectID(kAudioObjectUnknown)
        guard AudioHardwareCreateProcessTap(tapDesc, &newTap) == noErr,
              newTap != kAudioObjectUnknown else { return false }
        tapID = newTap
        let tapUUID = tapDesc.uuid.uuidString

        // 2) Aggregate privado: sub-device = dispositivo real; tap = nosso tap.
        aggregateUID = "com.internal.virtualtouchbar.amp"
        let desc: [String: Any] = [
            kAudioAggregateDeviceUIDKey as String: aggregateUID,
            kAudioAggregateDeviceNameKey as String: "Amplificador (VTB)",
            kAudioAggregateDeviceIsPrivateKey as String: true,
            kAudioAggregateDeviceIsStackedKey as String: false,
            kAudioAggregateDeviceMainSubDeviceKey as String: outUID,
            kAudioAggregateDeviceSubDeviceListKey as String: [
                [kAudioSubDeviceUIDKey as String: outUID]
            ],
            kAudioAggregateDeviceTapListKey as String: [
                [
                    kAudioSubTapUIDKey as String: tapUUID,
                    kAudioSubTapDriftCompensationKey as String: true
                ]
            ],
        ]
        var newAgg = AudioObjectID(kAudioObjectUnknown)
        guard AudioHardwareCreateAggregateDevice(desc as CFDictionary, &newAgg) == noErr,
              newAgg != kAudioObjectUnknown else {
            AudioHardwareDestroyProcessTap(tapID); tapID = kAudioObjectUnknown
            return false
        }
        aggregateID = newAgg
        return true
    }

    private func destroyGraph() {
        if let proc = ioProcID {
            AudioDeviceStop(aggregateID, proc)
            AudioDeviceDestroyIOProcID(aggregateID, proc)
            ioProcID = nil
        }
        if aggregateID != kAudioObjectUnknown {
            AudioHardwareDestroyAggregateDevice(aggregateID)
            aggregateID = kAudioObjectUnknown
        }
        if tapID != kAudioObjectUnknown {
            AudioHardwareDestroyProcessTap(tapID)
            tapID = kAudioObjectUnknown
        }
    }

    // MARK: IOProc (thread de áudio) — aplica ganho + limiter

    private func installIOProc() -> Bool {
        let status = AudioDeviceCreateIOProcIDWithBlock(&ioProcID, aggregateID, nil) {
            [weak self] _, inInput, _, outOutput, _ in
            guard let self = self else { return }

            let inList = UnsafeMutableAudioBufferListPointer(
                UnsafeMutablePointer(mutating: inInput))
            let outList = UnsafeMutableAudioBufferListPointer(outOutput)
            let pairs = min(inList.count, outList.count)

            for i in 0..<pairs {
                let inBuf = inList[i]
                let outBuf = outList[i]
                guard let inData = inBuf.mData, let outData = outBuf.mData else { continue }
                let frames = Int(min(inBuf.mDataByteSize, outBuf.mDataByteSize))
                    / MemoryLayout<Float>.size
                let src = inData.assumingMemoryBound(to: Float.self)
                let dst = outData.assumingMemoryBound(to: Float.self)
                let channels = Int(inBuf.mNumberChannels)

                var f = 0
                while f < frames {
                    self.currentGain = rampedGain(current: self.currentGain,
                                                  target: self.targetGain, step: self.rampStep)
                    if channels >= 2 {
                        dst[f]   = self.limiterL.process(src[f]   * self.currentGain)
                        dst[f+1] = self.limiterR.process(src[f+1] * self.currentGain)
                        f += 2
                    } else {
                        dst[f] = self.limiterL.process(src[f] * self.currentGain)
                        f += 1
                    }
                }
            }
        }
        guard status == noErr, ioProcID != nil else { return false }
        return AudioDeviceStart(aggregateID, ioProcID) == noErr
    }

    // MARK: API pública

    @discardableResult
    func start() -> Bool {
        startDeviceObserver()   // garante que trocas de saída sejam observadas mesmo no primeiro start
        guard !isOn else { return true }
        guard buildGraph() else { destroyGraph(); return false }
        guard installIOProc() else { destroyGraph(); return false }
        isOn = true
        return true
    }

    func stop() {
        guard isOn else { return }
        destroyGraph()
        isOn = false
    }

    func setPercent(_ p: Int) {
        percent = max(100, min(400, p))
        targetGain = gainMultiplier(percent: percent)   // lido pela thread de áudio (ramp suaviza)
        savePercentForCurrentDevice()   // lembra o ganho preferido deste dispositivo pra próxima vez
    }

    /// Smoke test para o --selftest: prova que o grafo cria e destrói sem crashar.
    func smokeTestCreateDestroy() -> Bool {
        let ok = buildGraph()
        destroyGraph()
        return ok
    }
}
