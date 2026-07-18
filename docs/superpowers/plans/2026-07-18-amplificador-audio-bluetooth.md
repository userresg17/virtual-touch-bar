# Amplificador de Áudio (Bluetooth) — Implementation Plan

> **For agentic workers:** REQUIRED SUB-SKILL: Use superpowers:subagent-driven-development (recommended) or superpowers:executing-plans to implement this plan task-by-task. Steps use checkbox (`- [ ]`) syntax for tracking.

**Goal:** Adicionar ao Virtual Touch Bar um amplificador de áudio de sistema, acionado por `fn+x`, que aplica ganho + limiter no áudio do sistema para arrancar mais volume no Bluetooth (melhor esforço, sem prometer paridade com o cabo).

**Architecture:** Um arquivo novo `amplifier.swift` com: (1) DSP puro (ganho + limiter, testável); (2) lógica pura do chord `fn+x`; (3) `AudioAmplifier` — motor Core Audio usando *process tap* (macOS 14.4+) + aggregate device + IOProc; (4) `AmplifierPanel` — HUD flutuante. `main.swift` troca o monitor `NSEvent` do `fn` por um `CGEventTap` e conecta tudo.

**Tech Stack:** Swift, CoreAudio (process tap / aggregate device / IOProc), AudioToolbox, Cocoa (NSPanel), CoreGraphics (CGEventTap).

## Global Constraints

- **Plataforma:** o amplificador exige **macOS 14.4+** (API de process tap). O resto do app é macOS 11+. Proteger o código do motor com `if #available(macOS 14.4, *)`.
- **Sem dependências novas.** `build.sh` já linka CoreAudio + AudioToolbox.
- **Padrão do código:** cada recurso é uma `final class` singleton (`.shared`), comentários em português explicando o "porquê", como em `turbo.swift`/`main.swift`.
- **Testes:** funções puras validadas com `assert(...)` dentro de `runSelfTestsIfRequested()` (em `turbo.swift`), rodadas com `./VirtualTouchBar.app/Contents/MacOS/VirtualTouchBar --selftest`.
- **Teto de ganho:** +12 dB (linear 4.0x). Limiter sempre ligado. Ramp de ganho ~30 ms.
- **Falha segura:** qualquer erro de Core Audio → boost desligado + áudio restaurado. Nunca deixar o sistema mudo ou roteado ao sair.
- **Build/selftest a cada tarefa:** `./build.sh` deve compilar sem erro; onde houver teste, rodar `--selftest` e ver `selftest ok`.

---

## File Structure

- **Create `amplifier.swift`** — DSP puro, `ChordState` (lógica pura do fn+x), `AudioAmplifier` (motor), `AmplifierPanel` (HUD), enum `AmplifierPreset`.
- **Modify `main.swift`** — remover `installFnMonitors()`; instalar `CGEventTap` (via nova classe `InputMonitor`); adicionar botão 🔊+ no `populateStack()`; conectar `fn+x` → HUD; teardown no `applicationWillTerminate`.
- **Modify `turbo.swift`** — acrescentar `assert`s do DSP e do `ChordState` em `runSelfTestsIfRequested()`.
- **Modify `build.sh`** — adicionar `NSAudioCaptureUsageDescription` ao `Info.plist`.

---

## Task 1: DSP puro — ganho + limiter

**Files:**
- Create: `amplifier.swift`
- Test: `turbo.swift` (dentro de `runSelfTestsIfRequested`)

**Interfaces:**
- Produces:
  - `func gainMultiplier(percent: Int) -> Float` — 100 → 1.0, 400 → 4.0, clamp em [100, 400].
  - `struct Limiter { var threshold: Float; mutating func process(_ x: Float) -> Float }` — limiter feed-forward; garante `|saída| <= threshold`.
  - `func rampedGain(current: Float, target: Float, step: Float) -> Float` — aproxima `current` de `target` no máximo `step` por chamada.

- [ ] **Step 1: Escrever o teste que falha** (em `turbo.swift`, dentro de `runSelfTestsIfRequested`, antes de `print("selftest ok")`)

```swift
// --- Amplificador: DSP puro ---
assert(gainMultiplier(percent: 100) == 1.0)
assert(gainMultiplier(percent: 400) == 4.0)
assert(gainMultiplier(percent: 50) == 1.0, "clamp mínimo")      // clampa pra 100%
assert(gainMultiplier(percent: 999) == 4.0, "clamp máximo")     // clampa pra 400%

var lim = Limiter(threshold: 0.9)
assert(lim.process(0.5) == 0.5, "abaixo do teto passa igual")
let loud = lim.process(3.0)                                      // sinal estourado
assert(loud <= 0.9 + 1e-6 && loud > 0, "limiter segura no teto: \(loud)")
let neg = lim.process(-3.0)
assert(neg >= -0.9 - 1e-6 && neg < 0, "limiter segura no teto negativo: \(neg)")

assert(rampedGain(current: 1.0, target: 4.0, step: 0.5) == 1.5, "sobe no máximo step")
assert(rampedGain(current: 1.0, target: 1.2, step: 0.5) == 1.2, "chega no alvo se perto")
assert(rampedGain(current: 4.0, target: 1.0, step: 0.5) == 3.5, "desce no máximo step")
```

- [ ] **Step 2: Rodar e ver falhar**

Run: `./build.sh 2>&1 | tail -5`
Expected: FAIL na compilação — `cannot find 'gainMultiplier' in scope` (etc.).

- [ ] **Step 3: Implementação mínima** (criar `amplifier.swift`)

```swift
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
```

- [ ] **Step 4: Rodar e ver passar**

Run: `./build.sh && ./VirtualTouchBar.app/Contents/MacOS/VirtualTouchBar --selftest`
Expected: imprime `selftest ok`.

- [ ] **Step 5: Commit**

```bash
git add amplifier.swift turbo.swift
git commit -m "feat(amp): DSP puro de ganho + limiter com testes"
```

---

## Task 2: Lógica pura do chord `fn+x` + CGEventTap

**Files:**
- Modify: `amplifier.swift` (adicionar `ChordState` e `InputMonitor`)
- Modify: `main.swift` (remover `installFnMonitors`, instalar `InputMonitor`)
- Test: `turbo.swift`

**Interfaces:**
- Produces:
  - `struct ChordState { mutating func onFnChanged(down: Bool) -> Bool /*deveToggleBar*/; mutating func onKeyX() -> Bool /*éChord*/ }`
  - `final class InputMonitor { var onFnTap: (() -> Void)?; var onAmplifierChord: (() -> Void)?; func start() }`

**Regras do `ChordState`:**
- `onFnChanged(down: true)` → marca fn pressionado, zera "consumido"; retorna `false`.
- `onKeyX()` → se fn está pressionado: marca consumido, retorna `true` (é chord, engole o x). Senão `false`.
- `onFnChanged(down: false)` → se fn estava pressionado e **não** foi consumido, retorna `true` (tap simples = alterna a barra). Senão `false`.

- [ ] **Step 1: Escrever o teste que falha** (em `turbo.swift`, dentro de `runSelfTestsIfRequested`)

```swift
// --- Amplificador: lógica do chord fn+x ---
var c1 = ChordState()
_ = c1.onFnChanged(down: true)
assert(c1.onFnChanged(down: false) == true, "fn sozinho = alterna a barra")

var c2 = ChordState()
_ = c2.onFnChanged(down: true)
assert(c2.onKeyX() == true, "fn+x = é chord (engole o x)")
assert(c2.onFnChanged(down: false) == false, "após chord, soltar fn NÃO alterna a barra")

var c3 = ChordState()
assert(c3.onKeyX() == false, "x sem fn = não é chord")
```

- [ ] **Step 2: Rodar e ver falhar**

Run: `./build.sh 2>&1 | tail -5`
Expected: FAIL — `cannot find 'ChordState' in scope`.

- [ ] **Step 3: Implementar `ChordState` e `InputMonitor`** (append em `amplifier.swift`)

```swift
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
```

- [ ] **Step 4: Trocar o monitor do fn em `main.swift`**

Remover o corpo antigo de `installFnMonitors()` (linhas do `NSEvent.addGlobalMonitorForEvents`/`addLocalMonitorForEvents`) e substituir por:

```swift
    private let inputMonitor = InputMonitor()

    private func installFnMonitors() {
        inputMonitor.onFnTap = { [weak self] in self?.togglePanel() }
        inputMonitor.onAmplifierChord = { [weak self] in self?.toggleAmplifier() }
        inputMonitor.start()
    }

    @objc private func toggleAmplifier() {
        NSSound.beep()   // placeholder: Task 5 abre o HUD aqui
    }
```

(Manter a chamada `installFnMonitors()` em `applicationDidFinishLaunching`. Declarar `inputMonitor` como propriedade do `AppDelegate`.)

- [ ] **Step 5: Rodar selftest + verificar manualmente**

Run: `./build.sh && ./VirtualTouchBar.app/Contents/MacOS/VirtualTouchBar --selftest`
Expected: `selftest ok`.

Verificação manual (recarregar o app): `pkill -f VirtualTouchBar; open VirtualTouchBar.app`
- Apertar `fn` sozinho → a barra abre/fecha (agora ao soltar; imperceptível).
- Segurar `fn` e apertar `x` → ouve um beep e **não** digita "x" no app em foco; a barra não pisca.

- [ ] **Step 6: Commit**

```bash
git add amplifier.swift main.swift turbo.swift
git commit -m "feat(amp): gatilho fn+x via CGEventTap sem quebrar o fn"
```

---

## Task 3: Motor Core Audio — `AudioAmplifier` (process tap + aggregate + IOProc)

**Files:**
- Modify: `amplifier.swift` (adicionar `AudioAmplifier`)
- Test: `turbo.swift` (smoke test de criação/destruição)

**Interfaces:**
- Consumes: `gainMultiplier`, `Limiter`, `rampedGain` (Task 1).
- Produces:
  - `final class AudioAmplifier { static let shared: AudioAmplifier; var isOn: Bool; var percent: Int; func start() -> Bool; func stop(); func setPercent(_ p: Int); func currentOutputName() -> String; func smokeTestCreateDestroy() -> Bool }`

**Nota de risco:** esta é a tarefa de maior risco (roteamento/mute de dispositivo). O caminho principal usa **tap global mudo + aggregate privado (dispositivo real + tap) + IOProc**. Se na verificação manual o áudio sair **dobrado**, aplicar o fallback documentado no Step 5.

- [ ] **Step 1: Escrever o smoke test que falha** (em `turbo.swift`)

```swift
// --- Amplificador: smoke test do motor Core Audio (cria e destrói) ---
if #available(macOS 14.4, *) {
    assert(AudioAmplifier.shared.smokeTestCreateDestroy(),
           "não criou/destruiu tap+aggregate")
    print("amp smoke ok")
} else {
    print("amp smoke: macOS < 14.4, pulando")
}
```

- [ ] **Step 2: Rodar e ver falhar**

Run: `./build.sh 2>&1 | tail -5`
Expected: FAIL — `cannot find 'AudioAmplifier' in scope`.

- [ ] **Step 3: Implementar `AudioAmplifier`** (append em `amplifier.swift`)

```swift
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
    }

    /// Smoke test para o --selftest: prova que o grafo cria e destrói sem crashar.
    func smokeTestCreateDestroy() -> Bool {
        let ok = buildGraph()
        destroyGraph()
        return ok
    }
}
```

- [ ] **Step 4: Rodar smoke test**

Run: `./build.sh && ./VirtualTouchBar.app/Contents/MacOS/VirtualTouchBar --selftest`
Expected: imprime `amp smoke ok` e `selftest ok`. (Se aparecer o prompt de permissão de captura de áudio, aceitar — ver Task 5 sobre o `Info.plist`.)

- [ ] **Step 5: Verificação manual com áudio real + decisão de fallback**

Teste temporário: no `applicationDidFinishLaunching`, após `installFnMonitors()`, adicionar provisoriamente:
```swift
if #available(macOS 14.4, *) {
    AudioAmplifier.shared.setPercent(300)
    _ = AudioAmplifier.shared.start()
}
```
Recarregar com a soundbar no BT tocando música.
- **Esperado:** o volume sobe perceptivelmente, sem chiado grosseiro no limite.
- **Se o áudio sair DOBRADO / com eco:** o mute do tap não segurou. Fallback: trocar, em `buildGraph`, `tapDesc.muteBehavior = .mutedWhenTapped` por `.muted`; e, se ainda dobrar, definir o default output do sistema para o aggregate ao ligar (guardar o device anterior e restaurar no `stop`) usando o mesmo padrão de `AudioObjectSetPropertyData` com `kAudioHardwarePropertyDefaultOutputDevice`.
- **Remover o trecho provisório** depois do teste.

- [ ] **Step 6: Commit**

```bash
git add amplifier.swift turbo.swift
git commit -m "feat(amp): motor Core Audio (process tap + aggregate + limiter)"
```

---

## Task 4: Robustez a mudança de dispositivo + memória por dispositivo

**Files:**
- Modify: `amplifier.swift` (`AudioAmplifier`)

**Interfaces:**
- Consumes: `AudioAmplifier` (Task 3).
- Produces (adições em `AudioAmplifier`): observação do dispositivo padrão; `restoreForCurrentDevice()`; persistência `deviceUID → percent` em `UserDefaults`.

- [ ] **Step 1: Adicionar memória por dispositivo** (em `AudioAmplifier`)

```swift
    // MARK: Memória por dispositivo (UserDefaults)
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
```

Chamar `savePercentForCurrentDevice()` no fim de `setPercent(_:)`.

- [ ] **Step 2: Observar troca/queda do dispositivo padrão** (em `AudioAmplifier`)

```swift
    // MARK: Observação de mudança de dispositivo
    private var listenerBlock: AudioObjectPropertyListenerBlock?

    func startDeviceObserver() {
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
```

Chamar `startDeviceObserver()` uma vez (ex.: no primeiro `start()` ou no wiring do `AppDelegate` da Task 5).

- [ ] **Step 3: Build + smoke selftest** (sem novos asserts; garantir que compila)

Run: `./build.sh && ./VirtualTouchBar.app/Contents/MacOS/VirtualTouchBar --selftest`
Expected: `selftest ok`.

- [ ] **Step 4: Verificação manual**

Com boost ligado tocando no BT, desconectar a soundbar → o áudio deve **restaurar sozinho** (sem travar/mudo). Reconectar → o ganho salvo daquele dispositivo volta.

- [ ] **Step 5: Commit**

```bash
git add amplifier.swift
git commit -m "feat(amp): memória por dispositivo e restauração ao trocar/cair a saída"
```

---

## Task 5: HUD (`AmplifierPanel`) + integração final

**Files:**
- Modify: `amplifier.swift` (adicionar `AmplifierPanel`, enum `AmplifierPreset`)
- Modify: `main.swift` (conectar `toggleAmplifier` ao HUD, botão 🔊+, teardown)
- Modify: `build.sh` (`NSAudioCaptureUsageDescription`)

**Interfaces:**
- Consumes: `AudioAmplifier` (Tasks 3–4).
- Produces: `final class AmplifierPanel { static let shared: AmplifierPanel; func toggle() }`.

- [ ] **Step 1: Implementar o HUD** (append em `amplifier.swift`)

```swift
// MARK: - HUD do amplificador

enum AmplifierPreset: Int, CaseIterable {
    case off = 100, boost = 200, max = 400
    var label: String {
        switch self {
        case .off: return "Off"
        case .boost: return "Boost"
        case .max: return "Máx"
        }
    }
}

@available(macOS 14.4, *)
final class AmplifierPanel {
    static let shared = AmplifierPanel()
    private var panel: NSPanel?
    private var slider: NSSlider?
    private var readout: NSTextField?
    private var deviceLabel: NSTextField?

    func toggle() {
        if let p = panel, p.isVisible { p.orderOut(nil); return }
        if panel == nil { build() }
        refresh()
        position()
        panel?.orderFrontRegardless()
    }

    private func build() {
        let p = NSPanel(contentRect: NSRect(x: 0, y: 0, width: 280, height: 132),
                        styleMask: [.borderless, .nonactivatingPanel],
                        backing: .buffered, defer: false)
        p.level = .statusBar
        p.isFloatingPanel = true
        p.hidesOnDeactivate = false
        p.isOpaque = false
        p.backgroundColor = .clear
        p.collectionBehavior = [.canJoinAllSpaces, .fullScreenAuxiliary, .stationary]

        let container = NSView()
        container.wantsLayer = true
        container.layer?.backgroundColor = NSColor(white: 0.06, alpha: 0.85).cgColor
        container.layer?.cornerRadius = Layout.panelCornerRadius
        p.contentView = container

        let dev = NSTextField(labelWithString: "—")
        dev.font = NSFont.systemFont(ofSize: 11, weight: .medium)
        dev.textColor = NSColor(white: 0.8, alpha: 1)
        deviceLabel = dev

        let read = NSTextField(labelWithString: "100%  ·  0 dB")
        read.font = NSFont.monospacedDigitSystemFont(ofSize: 13, weight: .semibold)
        read.textColor = .white
        readout = read

        let s = NSSlider(value: 100, minValue: 100, maxValue: 400,
                         target: self, action: #selector(sliderMoved(_:)))
        slider = s

        let presets = NSStackView(views: AmplifierPreset.allCases.map { preset in
            let b = makeButton(title: preset.label, width: 74,
                               target: self, action: #selector(presetTapped(_:)), tag: preset.rawValue)
            return b
        })
        presets.spacing = 6

        let v = NSStackView(views: [dev, read, s, presets])
        v.orientation = .vertical
        v.alignment = .leading
        v.spacing = 8
        v.translatesAutoresizingMaskIntoConstraints = false
        container.addSubview(v)
        NSLayoutConstraint.activate([
            v.leadingAnchor.constraint(equalTo: container.leadingAnchor, constant: 14),
            v.trailingAnchor.constraint(equalTo: container.trailingAnchor, constant: -14),
            v.topAnchor.constraint(equalTo: container.topAnchor, constant: 12),
            s.widthAnchor.constraint(equalToConstant: 252),
        ])
        panel = p
    }

    private func refresh() {
        let amp = AudioAmplifier.shared
        deviceLabel?.stringValue = "🔊 " + amp.currentOutputName()
        slider?.doubleValue = Double(amp.percent)
        updateReadout(amp.percent)
    }

    private func updateReadout(_ percent: Int) {
        let db = 20.0 * log10(Double(percent) / 100.0)
        readout?.stringValue = String(format: "%d%%  ·  %+.0f dB", percent, db)
    }

    @objc private func sliderMoved(_ sender: NSSlider) {
        let p = Int(sender.doubleValue)
        applyPercent(p)
    }

    @objc private func presetTapped(_ sender: NSButton) {
        applyPercent(sender.tag)
        slider?.doubleValue = Double(sender.tag)
    }

    private func applyPercent(_ percent: Int) {
        let amp = AudioAmplifier.shared
        updateReadout(percent)
        if percent <= 100 {
            amp.stop()
        } else {
            if !amp.isOn { _ = amp.start() }
            amp.setPercent(percent)
        }
    }

    private func position() {
        guard let p = panel,
              let screen = NSScreen.main else { return }
        let f = screen.visibleFrame
        p.setFrameOrigin(NSPoint(x: f.midX - p.frame.width / 2, y: f.minY + 70))
    }
}
```

- [ ] **Step 2: Conectar `fn+x` ao HUD e adicionar o botão 🔊+** (em `main.swift`)

Trocar o placeholder `toggleAmplifier`:
```swift
    @objc private func toggleAmplifier() {
        if #available(macOS 14.4, *) {
            AmplifierPanel.shared.toggle()
        } else {
            NSSound.beep()   // amplificador exige macOS 14.4+
        }
    }
```

No `populateStack()`, após o bloco de volume (depois do botão `speaker.wave.3.fill`), adicionar:
```swift
            if #available(macOS 14.4, *) {
                stack.addArrangedSubview(makeButton(symbol: "waveform.badge.plus",
                                                    target: self, action: #selector(toggleAmplifier)))
            }
```

- [ ] **Step 3: Teardown seguro ao sair** (em `main.swift`, `applicationWillTerminate`)

Adicionar antes do `FanControl.shared.releaseOnQuit()`:
```swift
        if #available(macOS 14.4, *) { AudioAmplifier.shared.stop() }
```

- [ ] **Step 4: Adicionar a chave de permissão no `Info.plist`** (em `build.sh`, dentro do heredoc do plist, antes de `</dict>`)

```xml
    <key>NSAudioCaptureUsageDescription</key>
    <string>O amplificador aplica ganho ao áudio do sistema para aumentar o volume na saída Bluetooth.</string>
```

- [ ] **Step 5: Build + selftest + verificação manual completa**

Run: `./build.sh && ./VirtualTouchBar.app/Contents/MacOS/VirtualTouchBar --selftest`
Expected: `amp smoke ok`, `selftest ok`.

Recarregar (`pkill -f VirtualTouchBar; open VirtualTouchBar.app`) e verificar o fluxo real:
1. Soundbar no BT tocando → `fn+x` abre o HUD mostrando o nome da saída.
2. Arrastar o slider / tocar `Boost`/`Máx` → volume sobe, sem distorção grosseira; `Off` volta ao normal.
3. `fn` sozinho ainda abre/fecha a barra; `fn+x` não digita "x".
4. Botão 🔊+ na barra abre o mesmo HUD.
5. Sair do app com boost ligado → áudio volta ao normal.

- [ ] **Step 6: Commit + push**

```bash
git add amplifier.swift main.swift build.sh
git commit -m "feat(amp): HUD do amplificador, botão na barra e integração fn+x"
git push
```

---

## Self-Review (checagem do plano contra o spec)

- **Gatilho fn+x (spec §1)** → Task 2 (CGEventTap + ChordState). ✓
- **Motor process tap + aggregate + ganho/limiter (spec §2)** → Task 3. ✓ (com fallback de mute/troca de device documentado no Step 5)
- **Robustez a mudança de dispositivo (spec §2)** → Task 4. ✓
- **Memória por dispositivo (spec §4)** → Task 4. ✓
- **HUD: slider, presets, dispositivo, dB (spec §3)** → Task 5. ✓ (medidor de nível/LED de limiter: ver nota abaixo)
- **Permissão NSAudioCaptureUsageDescription (spec §2)** → Task 5, Step 4. ✓
- **Teardown seguro ao sair (spec "onde encaixa")** → Task 5, Step 3. ✓
- **Botão 🔊+ na barra (spec §3)** → Task 5, Step 2. ✓
- **Teto +12 dB / limiter sempre ligado (Global Constraints)** → Task 1 (clamp 400% + Limiter) e Task 3. ✓

**Ajuste de escopo (YAGNI):** o **medidor de nível ao vivo + LED de limiter** do spec §3 foi deixado de fora do MVP para não acoplar o HUD à thread de áudio (exigiria publicar picos da thread de áudio de forma thread-safe, com custo/risco). O readout de %/dB já dá o feedback essencial. Anotado como melhoria futura (issue no GitHub), não como pendência bloqueante.
