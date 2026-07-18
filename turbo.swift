import Cocoa

// MARK: - Self-test (funções puras) — roda com `VirtualTouchBar --selftest`

func runSelfTestsIfRequested() {
    guard CommandLine.arguments.contains("--selftest") else { return }
    precondition(ramLevel(reclaimableRatio: 0.50, swapUsedBytes: 0) == .ok)
    precondition(ramLevel(reclaimableRatio: 0.20, swapUsedBytes: 0) == .tight)
    precondition(ramLevel(reclaimableRatio: 0.05, swapUsedBytes: 0) == .pressured)
    precondition(ramLevel(reclaimableRatio: 0.50, swapUsedBytes: 2_000_000_000) == .pressured)
    let s = SystemMetrics.shared.sample()
    print("sample: temp=\(String(describing: s.temp)) watts=\(String(describing: s.watts)) ram=\(s.ram.dot)")

    // Volume via CoreAudio: escrever e ler de volta prova que o controle funciona
    // sem depender de eventos de tecla de mídia (que o T2 ignora).
    if let v0 = SystemVolume.shared.getVolume() {
        SystemVolume.shared.setVolume(0.42)
        let v1 = SystemVolume.shared.getVolume() ?? -1
        precondition(abs(v1 - 0.42) < 0.05, "volume não mudou via CoreAudio: \(v1)")
        SystemVolume.shared.setVolume(v0) // restaura
        print("volume ok: \(v0) -> \(v1) -> restaurado para \(v0)")
    } else {
        print("volume: dispositivo de saída sem controle ajustável (pulando)")
    }

    // --- Amplificador: DSP puro ---
    precondition(gainMultiplier(percent: 100) == 1.0)
    precondition(gainMultiplier(percent: 400) == 4.0)
    precondition(gainMultiplier(percent: 50) == 1.0, "clamp mínimo")      // clampa pra 100%
    precondition(gainMultiplier(percent: 999) == 4.0, "clamp máximo")     // clampa pra 400%

    var lim = Limiter(threshold: 0.9)
    precondition(lim.process(0.5) == 0.5, "abaixo do teto passa igual")
    let loud = lim.process(3.0)                                      // sinal estourado
    precondition(loud <= 0.9 + 1e-6 && loud > 0, "limiter segura no teto: \(loud)")
    let neg = lim.process(-3.0)
    precondition(neg >= -0.9 - 1e-6 && neg < 0, "limiter segura no teto negativo: \(neg)")

    precondition(rampedGain(current: 1.0, target: 4.0, step: 0.5) == 1.5, "sobe no máximo step")
    precondition(rampedGain(current: 1.0, target: 1.2, step: 0.5) == 1.2, "chega no alvo se perto")
    precondition(rampedGain(current: 4.0, target: 1.0, step: 0.5) == 3.5, "desce no máximo step")

    // --- Amplificador: lógica do chord fn+x ---
    var c1 = ChordState()
    _ = c1.onFnChanged(down: true)
    precondition(c1.onFnChanged(down: false) == true, "fn sozinho = alterna a barra")

    var c2 = ChordState()
    _ = c2.onFnChanged(down: true)
    precondition(c2.onKeyX() == true, "fn+x = é chord (engole o x)")
    precondition(c2.onFnChanged(down: false) == false, "após chord, soltar fn NÃO alterna a barra")

    var c3 = ChordState()
    precondition(c3.onKeyX() == false, "x sem fn = não é chord")

    print("selftest ok")
    exit(0)
}

import Darwin

// MARK: - Métricas do sistema (sem root)

enum RAMLevel {
    case ok, tight, pressured
    var dot: String {
        switch self {
        case .ok: return "🟢"
        case .tight: return "🟡"
        case .pressured: return "🔴"
        }
    }
}

struct Metrics {
    let temp: Double?
    let watts: Double?
    let ram: RAMLevel
}

// Regra pura: muito swap em uso, ou pouca RAM recuperável, = pressão.
func ramLevel(reclaimableRatio: Double, swapUsedBytes: UInt64) -> RAMLevel {
    if swapUsedBytes > 1_000_000_000 { return .pressured }
    if reclaimableRatio < 0.10 { return .pressured }
    if reclaimableRatio < 0.25 { return .tight }
    return .ok
}

final class SystemMetrics {
    static let shared = SystemMetrics()

    // Caminho do helper embutido (leitura de SMC não precisa do setuid instalado).
    private var helperPath: String? {
        Bundle.main.path(forResource: "smcfan", ofType: nil)
    }

    func sample() -> Metrics {
        let (temp, watts) = readSensors()
        return Metrics(temp: temp, watts: watts, ram: readRAM())
    }

    // Roda `smcfan sensors` e parseia "temp <n>" / "power <n>".
    private func readSensors() -> (Double?, Double?) {
        guard let path = helperPath else { return (nil, nil) }
        let process = Process()
        process.executableURL = URL(fileURLWithPath: path)
        process.arguments = ["sensors"]
        let pipe = Pipe()
        process.standardOutput = pipe
        do { try process.run() } catch { return (nil, nil) }
        let data = pipe.fileHandleForReading.readDataToEndOfFile()
        process.waitUntilExit()
        var temp: Double?
        var watts: Double?
        for line in (String(data: data, encoding: .utf8) ?? "").split(separator: "\n") {
            let parts = line.split(separator: " ")
            guard parts.count == 2, let value = Double(parts[1]) else { continue }
            if parts[0] == "temp" { temp = value }
            if parts[0] == "power" { watts = value }
        }
        return (temp, watts)
    }

    private func readRAM() -> RAMLevel {
        let total = ProcessInfo.processInfo.physicalMemory
        guard total > 0 else { return .ok }

        var stats = vm_statistics64()
        var count = mach_msg_type_number_t(
            MemoryLayout<vm_statistics64_data_t>.size / MemoryLayout<integer_t>.size)
        let kr = withUnsafeMutablePointer(to: &stats) {
            $0.withMemoryRebound(to: integer_t.self, capacity: Int(count)) {
                host_statistics64(mach_host_self(), HOST_VM_INFO64, $0, &count)
            }
        }
        guard kr == KERN_SUCCESS else { return .ok }

        let page = UInt64(vm_kernel_page_size)
        // Recuperável ≈ livre + inativo + purgeable + cache de arquivo (external).
        let reclaimablePages = UInt64(stats.free_count) + UInt64(stats.inactive_count)
            + UInt64(stats.purgeable_count) + UInt64(stats.external_page_count)
        let ratio = Double(reclaimablePages * page) / Double(total)
        return ramLevel(reclaimableRatio: ratio, swapUsedBytes: swapUsedBytes())
    }

    private func swapUsedBytes() -> UInt64 {
        var xsw = xsw_usage()
        var size = MemoryLayout<xsw_usage>.size
        return sysctlbyname("vm.swapusage", &xsw, &size, nil, 0) == 0 ? xsw.xsu_used : 0
    }
}

import IOKit.ps

enum PowerSource {
    static func onAC() -> Bool {
        guard let blob = IOPSCopyPowerSourcesInfo()?.takeRetainedValue(),
              let type = IOPSGetProvidingPowerSourceType(blob)?.takeRetainedValue() as String?
        else { return true } // na dúvida, assume tomada (não bloqueia)
        return type == kIOPSACPowerValue
    }
}

// MARK: - Modo Turbo / Game

final class TurboMode {
    static let shared = TurboMode()
    private(set) var isOn = false
    var onChange: (() -> Void)?

    private var caffeinate: Process?
    private let setupKey = "turboSetupDone"

    func toggle() {
        isOn ? disable() : enable()
    }

    private func enable() {
        NSApp.activate(ignoringOtherApps: true)

        if !UserDefaults.standard.bool(forKey: setupKey) {
            let intro = NSAlert()
            intro.messageText = "Ligar o Modo Turbo / Game"
            intro.informativeText = """
                Ao ligar, o Turbo vai:
                • jogar as ventoinhas no máximo (pode pedir sua senha só nesta primeira vez);
                • impedir o Mac de dar App Nap / dormir enquanto joga.

                Depois disso não pergunto mais.
                """
            intro.addButton(withTitle: "Ligar")
            intro.addButton(withTitle: "Cancelar")
            guard intro.runModal() == .alertFirstButtonReturn else { return }
            UserDefaults.standard.set(true, forKey: setupKey)
        }

        if !PowerSource.onAC() {
            let warn = NSAlert()
            warn.messageText = "Você está na bateria"
            warn.informativeText = "Na bateria o ganho é limitado (o i9 se segura fora da tomada). Ligar mesmo assim?"
            warn.addButton(withTitle: "Ligar mesmo assim")
            warn.addButton(withTitle: "Cancelar")
            guard warn.runModal() == .alertFirstButtonReturn else { return }
        }

        FanControl.shared.set(.booster) { [weak self] ok in
            guard let self = self else { return }
            guard ok else { return } // FanControl já dá beep no erro
            self.startCaffeinate()
            HeavyApps.shared.closeSelectedWithConfirm()
            self.isOn = true
            self.onChange?()
        }
    }

    private func disable() {
        FanControl.shared.set(.auto) { [weak self] _ in
            self?.stopCaffeinate()
            self?.isOn = false
            self?.onChange?()
        }
    }

    private func startCaffeinate() {
        stopCaffeinate()
        let process = Process()
        process.executableURL = URL(fileURLWithPath: "/usr/bin/caffeinate")
        process.arguments = ["-di"] // impede sono de tela e ocioso
        do { try process.run(); caffeinate = process } catch { NSSound.beep() }
    }

    private func stopCaffeinate() {
        caffeinate?.terminate()
        caffeinate = nil
    }

    func onAppTerminate() {
        stopCaffeinate()
    }
}

// MARK: - Apps pesados pra fechar no Turbo

final class HeavyApps {
    static let shared = HeavyApps()
    private let key = "turboHeavyApps"
    private let protectedIDs: Set<String> = ["com.internal.virtualtouchbar", "com.apple.finder"]

    var bundleIDs: Set<String> {
        get { Set(UserDefaults.standard.stringArray(forKey: key) ?? []) }
        set { UserDefaults.standard.set(Array(newValue), forKey: key) }
    }

    func toggle(_ id: String) {
        var ids = bundleIDs
        if ids.contains(id) { ids.remove(id) } else { ids.insert(id) }
        bundleIDs = ids
    }

    // Apps comuns (com janela/dock), fora os protegidos — candidatos da lista.
    func pickableApps() -> [NSRunningApplication] {
        NSWorkspace.shared.runningApplications
            .filter { $0.activationPolicy == .regular }
            .filter { !protectedIDs.contains($0.bundleIdentifier ?? "") }
            .sorted { ($0.localizedName ?? "") < ($1.localizedName ?? "") }
    }

    // Fecha (educado) os apps marcados que estão abertos, após confirmação.
    func closeSelectedWithConfirm() {
        let ids = bundleIDs
        let targets = NSWorkspace.shared.runningApplications.filter {
            guard let id = $0.bundleIdentifier else { return false }
            return ids.contains(id) && !protectedIDs.contains(id)
        }
        guard !targets.isEmpty else { return }

        let names = targets.map { $0.localizedName ?? "app" }.joined(separator: ", ")
        NSApp.activate(ignoringOtherApps: true)
        let alert = NSAlert()
        alert.messageText = "Fechar apps pra liberar memória?"
        alert.informativeText = "Vou pedir pra fechar: \(names)"
        alert.addButton(withTitle: "Fechar")
        alert.addButton(withTitle: "Agora não")
        guard alert.runModal() == .alertFirstButtonReturn else { return }
        targets.forEach { $0.terminate() } // educado; nunca forceTerminate
    }
}
