# Modo Turbo / Game — Implementation Plan

> **For agentic workers:** REQUIRED SUB-SKILL: Use superpowers:subagent-driven-development (recommended) or superpowers:executing-plans to implement this plan task-by-task. Steps use checkbox (`- [ ]`) syntax for tracking.

**Goal:** Adicionar um "Modo Turbo / Game" ao Virtual Touch Bar que, num toque, maximiza o desempenho sustentado real do MacBook Pro i9 (ventoinhas no máximo + anti-throttling + fechar apps pesados) e mostra temperatura/watts/pressão de RAM ao vivo.

**Architecture:** Toda a lógica nova fica isolada em `turbo.swift`; `main.swift` só ganha o botão, o mostrador e os itens de menu que chamam essa lógica. As leituras de sensores reaproveitam o helper C `smcfan` (leitura de SMC não exige root) via um novo subcomando `sensors`. Nada do comportamento atual muda.

**Tech Stack:** Swift + Cocoa (AppKit), C + IOKit (helper SMC já existente), APIs Mach (`host_statistics64`) e IOKit.ps pra energia. Build via `swiftc`/`clang` no `build.sh` (sem gerenciador de pacotes).

## Global Constraints

- Plataforma: macOS, `LSMinimumSystemVersion` 11.0; máquina alvo MacBook Pro Intel i9-9880H (chip T2).
- Sem overclock (impossível no macOS) — "boost" = remover teto térmico + anti-throttle + liberar RAM/CPU.
- Bundle ID do app: `com.internal.virtualtouchbar`. Nunca fechar esse app nem processos do sistema.
- Fechar apps só com `NSRunningApplication.terminate()` (educado); nunca `forceTerminate`, nunca AppleScript (evita prompt de Automação por app).
- Leitura de SMC **não** usa root; escrita de ventoinha usa o helper setuid já existente (senha uma vez só).
- Estado do Turbo no launch: **desligado**. Reverter ventoinhas pra Auto e matar `caffeinate` ao sair.
- Textos de UI em português (padrão do projeto).
- **Sem harness de teste unitário no projeto.** Verificação = build + observação em runtime + um modo `--selftest` (adicionado na Task 1) pra funções puras.

---

### Task 1: Build compila `*.swift` + esqueleto `turbo.swift` + gancho `--selftest`

**Files:**
- Modify: `build.sh:39`
- Create: `turbo.swift`
- Modify: `main.swift:676-680` (bloco final que sobe o app)

**Interfaces:**
- Consumes: nada.
- Produces: `func runSelfTestsIfRequested()` — se `--selftest` estiver em `CommandLine.arguments`, roda asserts, imprime `selftest ok` e chama `exit(0)`; senão retorna.

- [ ] **Step 1: Fazer o build compilar todos os `.swift` e linkar IOKit**

Em `build.sh`, trocar a linha 39:

```sh
swiftc -O -framework Cocoa -framework ServiceManagement -framework IOKit *.swift -o "$APP/Contents/MacOS/VirtualTouchBar"
```

- [ ] **Step 2: Criar `turbo.swift` com o gancho de selftest**

```swift
import Cocoa

// MARK: - Self-test (funções puras) — roda com `VirtualTouchBar --selftest`

func runSelfTestsIfRequested() {
    guard CommandLine.arguments.contains("--selftest") else { return }
    // Asserts entram nas tasks seguintes.
    print("selftest ok")
    exit(0)
}
```

- [ ] **Step 3: Chamar o gancho antes de subir o app**

Em `main.swift`, no bloco final, inserir a chamada logo após `let app = NSApplication.shared`:

```swift
let app = NSApplication.shared
runSelfTestsIfRequested()
app.setActivationPolicy(.accessory)
let delegate = AppDelegate()
app.delegate = delegate
app.run()
```

- [ ] **Step 4: Compilar**

Run: `cd /Users/israelesgaib/VirtualTouchBar && ./build.sh`
Expected: termina com `Pronto: .../VirtualTouchBar.app`, sem erro.

- [ ] **Step 5: Rodar o selftest**

Run: `./VirtualTouchBar.app/Contents/MacOS/VirtualTouchBar --selftest`
Expected: imprime `selftest ok` e sai (código 0).

- [ ] **Step 6: (sem git) registrar o marco**

Projeto não é repositório git — pular commit. Se virar repo depois, commitar aqui.

---

### Task 2: Subcomando `sensors` no helper `smcfan.c`

**Files:**
- Modify: `smcfan.c` (adicionar decode/read escalar + `cmd_sensors`; aceitar `sensors` sem root; atualizar usage nas linhas 199 e 209)

**Interfaces:**
- Consumes: funções já existentes `read_key`, `key_info`, `fourcc`, `smc_open`, `fan_count`.
- Produces: comando CLI `smcfan sensors` que imprime em stdout, uma por linha, o que conseguir ler: `temp <float>` (°C) e `power <float>` (W). Não exige root. Sai 0 mesmo se não achar nada.

- [ ] **Step 1: Adicionar leitura escalar genérica**

Inserir antes de `cmd_status` (por volta da linha 170):

```c
// Decodifica um valor escalar do SMC (temperatura, watts) nos tipos comuns.
static int decode_scalar(const SMCKeyData_keyInfo_t *info, const unsigned char *b, double *out) {
    UInt32 t = info->dataType;
    if (t == fourcc("flt ") && info->dataSize == 4) { float f; memcpy(&f, b, 4); *out = f; return 0; }
    if (t == fourcc("sp78") && info->dataSize == 2) { short raw = (short)((b[0] << 8) | b[1]); *out = raw / 256.0; return 0; }
    if (t == fourcc("fpe2")) { *out = ((b[0] << 8) | b[1]) / 4.0; return 0; }
    if (t == fourcc("ui8 ")) { *out = b[0]; return 0; }
    if (t == fourcc("ui16")) { *out = (b[0] << 8) | b[1]; return 0; }
    return -1;
}

static int read_scalar(const char *key, double *out) {
    SMCKeyData_keyInfo_t info;
    unsigned char b[32];
    if (read_key(key, &info, b)) return -1;
    return decode_scalar(&info, b, out);
}

// Imprime temperatura da CPU e watts do pacote. As chaves variam por modelo,
// então testamos candidatas e usamos a primeira que ler um valor plausível.
static int cmd_sensors(void) {
    const char *temps[]  = {"TC0P", "TCXC", "TC0E", "TC0D", "Tp0C", NULL};
    const char *powers[] = {"PCPC", "PC0C", "PSTR", "PPBR", NULL};
    for (int i = 0; temps[i]; i++) {
        double v;
        if (read_scalar(temps[i], &v) == 0 && v > 0 && v < 125) { printf("temp %.1f\n", v); break; }
    }
    for (int i = 0; powers[i]; i++) {
        double v;
        if (read_scalar(powers[i], &v) == 0 && v >= 0 && v < 200) { printf("power %.1f\n", v); break; }
    }
    return 0;
}
```

- [ ] **Step 2: Reconhecer `sensors` como leitura (sem root)**

Em `main()`, trocar a linha que define `is_status` (linha 203) por:

```c
    int is_status = strcmp(mode, "status") == 0;
    int is_sensors = strcmp(mode, "sensors") == 0;
    int is_read = is_status || is_sensors;
```

Atualizar as duas mensagens de uso (linhas 199 e 209) para:

```c
        fprintf(stderr, "uso: smcfan auto|silent|medium|max|status|sensors\n");
```

Na validação de modo inválido (linha 208), trocar `!is_status` por `!is_read`:

```c
    else if (!is_read && strcmp(mode, "auto") != 0) {
```

Na consolidação de privilégio (linha 214), trocar `!is_status` por `!is_read`:

```c
    if (!is_read && geteuid() == 0)
        setuid(0);
```

Antes do bloco `if (is_status) return cmd_status(fans);` (linha 228), adicionar:

```c
    if (is_sensors)
        return cmd_sensors();
```

- [ ] **Step 3: Compilar**

Run: `cd /Users/israelesgaib/VirtualTouchBar && ./build.sh`
Expected: sem erro de compilação do `clang`.

- [ ] **Step 4: Rodar sensors com o binário recém-compilado (sem root)**

Run: `./VirtualTouchBar.app/Contents/Resources/smcfan sensors`
Expected: imprime pelo menos uma linha, ex.: `temp 54.0` e `power 12.3`. (Se alguma métrica não existir no modelo, a linha correspondente some — aceitável.)

- [ ] **Step 5: (sem git) registrar o marco** — pular commit.

---

### Task 3: `SystemMetrics` + pressão de RAM (Swift) com asserts no selftest

**Files:**
- Modify: `turbo.swift` (adicionar métricas)

**Interfaces:**
- Consumes: `smcfan sensors` (bundled), `runSelfTestsIfRequested()` da Task 1.
- Produces:
  - `struct Metrics { let temp: Double?; let watts: Double?; let ram: RAMLevel }`
  - `enum RAMLevel { case ok, tight, pressured; var dot: String }` → `"🟢"` / `"🟡"` / `"🔴"`
  - `func ramLevel(reclaimableRatio: Double, swapUsedBytes: UInt64) -> RAMLevel`
  - `final class SystemMetrics { static let shared; func sample() -> Metrics }` (bloqueante — chamar fora da main thread)

- [ ] **Step 1: Escrever os asserts (falham antes da implementação)**

Em `turbo.swift`, dentro de `runSelfTestsIfRequested()`, antes do `print("selftest ok")`:

```swift
    assert(ramLevel(reclaimableRatio: 0.50, swapUsedBytes: 0) == .ok)
    assert(ramLevel(reclaimableRatio: 0.20, swapUsedBytes: 0) == .tight)
    assert(ramLevel(reclaimableRatio: 0.05, swapUsedBytes: 0) == .pressured)
    assert(ramLevel(reclaimableRatio: 0.50, swapUsedBytes: 2_000_000_000) == .pressured)
    let s = SystemMetrics.shared.sample()
    print("sample: temp=\(String(describing: s.temp)) watts=\(String(describing: s.watts)) ram=\(s.ram.dot)")
```

- [ ] **Step 2: Verificar que não compila ainda**

Run: `./build.sh`
Expected: FALHA com "cannot find 'ramLevel'/'SystemMetrics' in scope".

- [ ] **Step 3: Implementar métricas**

Adicionar em `turbo.swift`:

```swift
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
```

- [ ] **Step 4: Compilar e rodar o selftest**

Run: `./build.sh && ./VirtualTouchBar.app/Contents/MacOS/VirtualTouchBar --selftest`
Expected: imprime uma linha `sample: temp=Optional(...) watts=Optional(...) ram=🟢|🟡|🔴` e depois `selftest ok`, sem abortar por assert.

- [ ] **Step 5: (sem git) registrar o marco** — pular commit.

---

### Task 4: Mostrador ao vivo na barra

**Files:**
- Modify: `main.swift` (novo `NSTextField` no layout de mídia; `Timer` de 2s; atualização a partir de `SystemMetrics`)

**Interfaces:**
- Consumes: `SystemMetrics.shared.sample()`, `Metrics`, `RAMLevel.dot`.
- Produces: nada pra outras tasks (UI interna).

- [ ] **Step 1: Adicionar o campo do mostrador e propriedade no `AppDelegate`**

Em `main.swift`, na classe `AppDelegate`, junto das outras propriedades (perto da linha 316):

```swift
    private var metricsLabel: NSTextField!
    private var metricsTimer: Timer?
```

Adicionar um helper de criação do label logo antes de `// MARK: - Painel` (perto da linha 302), fora da classe:

```swift
func makeMetricsLabel() -> NSTextField {
    let label = NSTextField(labelWithString: "—")
    label.font = NSFont.monospacedDigitSystemFont(ofSize: 12, weight: .medium)
    label.textColor = .white
    label.alignment = .center
    label.translatesAutoresizingMaskIntoConstraints = false
    label.widthAnchor.constraint(equalToConstant: 150).isActive = true
    return label
}
```

- [ ] **Step 2: Inserir o mostrador no layout de mídia**

Em `populateStack()`, dentro do bloco `else` (layout de mídia), logo após a criação dos botões de ventoinha e do `refreshFanSelection()` (perto da linha 459), antes do separador/final:

```swift
            stack.addArrangedSubview(makeSeparator())
            metricsLabel = makeMetricsLabel()
            stack.addArrangedSubview(metricsLabel)
            updateMetricsLabel()
```

- [ ] **Step 3: Timer de 2s com gate de bateria/visibilidade + atualização**

Adicionar métodos na `AppDelegate` (perto da seção de ventoinhas):

```swift
    private func startMetricsTimer() {
        metricsTimer?.invalidate()
        metricsTimer = Timer.scheduledTimer(withTimeInterval: 2.0, repeats: true) { [weak self] _ in
            self?.updateMetricsLabel()
        }
    }

    private func updateMetricsLabel() {
        // Só amostra quando a barra está visível ou o Turbo ligado (economia de bateria).
        guard panel?.isVisible == true || TurboMode.shared.isOn else { return }
        DispatchQueue.global(qos: .utility).async { [weak self] in
            let m = SystemMetrics.shared.sample()
            let temp = m.temp.map { "🌡️ \(Int($0.rounded()))°" } ?? ""
            let watts = m.watts.map { "⚡ \(Int($0.rounded()))W" } ?? ""
            let text = [temp, watts, m.ram.dot].filter { !$0.isEmpty }.joined(separator: "  ")
            DispatchQueue.main.async {
                self?.metricsLabel?.stringValue = text.isEmpty ? "—" : text
            }
        }
    }
```

Chamar `startMetricsTimer()` no fim de `applicationDidFinishLaunching` (perto da linha 325):

```swift
        installFnMonitors()
        startMetricsTimer()
```

- [ ] **Step 4: Compilar e rodar o app**

Run: `./build.sh && open ./VirtualTouchBar.app`
Then: apertar `fn` pra abrir a barra.
Expected: no fim da barra aparece algo como `🌡️ 55°  ⚡ 12W  🟢`, atualizando a cada ~2s. Fechar o app (menu → Sair) ao terminar.

- [ ] **Step 5: (sem git) registrar o marco** — pular commit.

---

### Task 5: `TurboMode` (ventoinhas + caffeinate + aviso de bateria + botão + menu + reverter ao sair + permissão uma vez)

**Files:**
- Modify: `turbo.swift` (classe `TurboMode`, `PowerSource`)
- Modify: `main.swift` (botão ⚡, item de menu, `applicationWillTerminate`, atualização visual)

**Interfaces:**
- Consumes: `FanControl.shared` (`.booster`, `.auto`, `set(_:completion:)`), `SystemMetrics`.
- Produces:
  - `enum PowerSource { static func onAC() -> Bool }`
  - `final class TurboMode { static let shared; private(set) var isOn: Bool; var onChange: (() -> Void)?; func toggle() }`
  - `TurboMode.onAppTerminate()` — mata `caffeinate` (ventoinhas já são revertidas pelo `FanControl.releaseOnQuit()` existente).

- [ ] **Step 1: Implementar `PowerSource` e `TurboMode` (sem fechar apps ainda)**

Adicionar em `turbo.swift`:

```swift
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
```

- [ ] **Step 2: Botão ⚡ na barra**

Em `main.swift`, no `populateStack()`, dentro do bloco `else` (mídia), logo antes do separador do mostrador criado na Task 4:

```swift
            stack.addArrangedSubview(makeSeparator())
            let turboButton = makeButton(symbol: "bolt.fill",
                                         tint: TurboMode.shared.isOn ? .systemYellow : .white,
                                         target: self, action: #selector(pressTurbo))
            turboButton.baseColor = TurboMode.shared.isOn
                ? NSColor.systemOrange.withAlphaComponent(0.85)
                : NSColor(white: 0.28, alpha: 1)
            stack.addArrangedSubview(turboButton)
```

Adicionar a ação e o hook de refresh na `AppDelegate`:

```swift
    @objc private func pressTurbo() {
        TurboMode.shared.toggle()
    }
```

- [ ] **Step 3: Item de menu + fio do `onChange`**

Em `buildStatusItem()`, após o submenu de ventoinhas (perto da linha 632), adicionar:

```swift
        let turboItem = NSMenuItem(title: "Modo Turbo / Game",
                                   action: #selector(pressTurbo), keyEquivalent: "")
        turboItem.state = TurboMode.shared.isOn ? .on : .off
        menu.addItem(turboItem)
        menu.addItem(.separator())
```

Guardar referência pra atualizar o estado. Adicionar propriedade na `AppDelegate` (perto da linha 316):

```swift
    private var turboMenuItem: NSMenuItem?
```

E na criação acima, trocar por `turboMenuItem = turboItem` guardando a referência:

```swift
        turboMenuItem = turboItem
```

Em `applicationDidFinishLaunching`, após `buildStatusItem()`, ligar o callback:

```swift
        TurboMode.shared.onChange = { [weak self] in
            self?.turboMenuItem?.state = TurboMode.shared.isOn ? .on : .off
            if self?.panel.isVisible == true { self?.populateStack() }
            self?.updateMetricsLabel()
        }
```

- [ ] **Step 4: Reverter ao sair**

Em `applicationWillTerminate` (linha 327), acrescentar a parada do caffeinate:

```swift
    func applicationWillTerminate(_ notification: Notification) {
        TurboMode.shared.onAppTerminate()
        FanControl.shared.releaseOnQuit()
    }
```

- [ ] **Step 5: Compilar**

Run: `./build.sh`
Expected: sem erro.

- [ ] **Step 6: Verificar ligar/desligar na tomada**

Run: `open ./VirtualTouchBar.app`, abrir a barra (`fn`), tocar no ⚡.
Expected:
- Primeira vez: aparece o diálogo de introdução; ao confirmar, o macOS pede a senha (instalação do helper) uma vez.
- Botão fica laranja/aceso; item de menu "Modo Turbo / Game" fica com ✓.
- `./VirtualTouchBar.app/Contents/Resources/smcfan status` → ventoinhas em `modo=forçado` no máximo.
- `pgrep caffeinate` → retorna um PID.
- Tocar ⚡ de novo → ventoinhas voltam a `auto`, `pgrep caffeinate` não retorna nada.

- [ ] **Step 7: Verificar reverter ao sair**

Ligar o Turbo, depois menu → Sair.
Run: `./VirtualTouchBar.app/Contents/Resources/smcfan status` e `pgrep caffeinate`
Expected: ventoinhas em `auto`; nenhum `caffeinate` rodando.

- [ ] **Step 8: (sem git) registrar o marco** — pular commit.

---

### Task 6: Fechar apps pesados escolhidos (lista + submenu + confirmação)

**Files:**
- Modify: `turbo.swift` (classe `HeavyApps`; chamada no `enable()`)
- Modify: `main.swift` (submenu "Apps pra fechar no Turbo")

**Interfaces:**
- Consumes: `NSWorkspace.shared.runningApplications`.
- Produces:
  - `final class HeavyApps { static let shared; var bundleIDs: Set<String>; func toggle(_ id: String); func pickableApps() -> [NSRunningApplication]; func closeSelectedWithConfirm() }`
  - Chamada de `HeavyApps.shared.closeSelectedWithConfirm()` dentro do `enable()` do `TurboMode`, após ligar as ventoinhas.

- [ ] **Step 1: Implementar `HeavyApps`**

Adicionar em `turbo.swift`:

```swift
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
```

- [ ] **Step 2: Chamar no `enable()` do `TurboMode`**

Em `turbo.swift`, dentro do `FanControl.shared.set(.booster)` do `enable()`, após `self.startCaffeinate()`:

```swift
            self.startCaffeinate()
            HeavyApps.shared.closeSelectedWithConfirm()
            self.isOn = true
            self.onChange?()
```

- [ ] **Step 3: Submenu "Apps pra fechar no Turbo" no menu de status**

Em `main.swift`, em `buildStatusItem()`, após o item do Turbo (Task 5), adicionar um submenu construído sob demanda. Primeiro, um método na `AppDelegate`:

```swift
    @objc private func rebuildHeavyAppsSubmenu(_ menu: NSMenu) {
        menu.removeAllItems()
        let selected = HeavyApps.shared.bundleIDs
        for app in HeavyApps.shared.pickableApps() {
            guard let id = app.bundleIdentifier else { continue }
            let item = NSMenuItem(title: app.localizedName ?? id,
                                  action: #selector(toggleHeavyApp(_:)), keyEquivalent: "")
            item.representedObject = id
            item.state = selected.contains(id) ? .on : .off
            item.target = self
            menu.addItem(item)
        }
        if menu.items.isEmpty {
            menu.addItem(NSMenuItem(title: "(nenhum app aberto)", action: nil, keyEquivalent: ""))
        }
    }

    @objc private func toggleHeavyApp(_ sender: NSMenuItem) {
        guard let id = sender.representedObject as? String else { return }
        HeavyApps.shared.toggle(id)
        sender.state = HeavyApps.shared.bundleIDs.contains(id) ? .on : .off
    }
```

Fazer o submenu reconstruir ao abrir, via `NSMenuDelegate`. Declarar conformidade na classe (linha 311):

```swift
final class AppDelegate: NSObject, NSApplicationDelegate, NSMenuDelegate {
```

Adicionar o item + submenu logo após o bloco do Turbo em `buildStatusItem()`:

```swift
        let heavyItem = NSMenuItem(title: "Apps pra fechar no Turbo", action: nil, keyEquivalent: "")
        let heavySubmenu = NSMenu()
        heavySubmenu.delegate = self
        menu.setSubmenu(heavySubmenu, for: heavyItem)
        menu.addItem(heavyItem)
        menu.addItem(.separator())
```

Implementar o delegate (reconstrói a lista de apps abertos toda vez que o submenu abre):

```swift
    func menuNeedsUpdate(_ menu: NSMenu) {
        rebuildHeavyAppsSubmenu(menu)
    }
```

- [ ] **Step 4: Compilar**

Run: `./build.sh`
Expected: sem erro.

- [ ] **Step 5: Verificar seleção e fechamento**

Preparação: abrir o TextEdit (`open -a TextEdit`), sem documento não salvo.
Run: `open ./VirtualTouchBar.app` → menu de status (ícone teclado) → "Apps pra fechar no Turbo" → marcar "TextEdit".
Então tocar no ⚡ (ligar Turbo).
Expected: aparece o alerta "Vou pedir pra fechar: TextEdit"; ao confirmar, o TextEdit fecha. Apps não marcados continuam abertos. O próprio Touch Bar nunca aparece na lista.

- [ ] **Step 6: (sem git) registrar o marco** — pular commit.

---

## Verificação final (após todas as tasks)

Rodar o fluxo completo numa sessão, na tomada:
1. `./build.sh` — build limpo.
2. `./VirtualTouchBar.app/Contents/MacOS/VirtualTouchBar --selftest` → `selftest ok`.
3. `open ./VirtualTouchBar.app`, `fn` pra abrir a barra: mostrador `🌡️ … ⚡ … 🟢/🟡/🔴` atualizando.
4. Marcar um app leve no submenu; tocar ⚡: diálogo de 1ª vez → senha (uma vez) → aviso só se na bateria → ventoinhas máx (`smcfan status` = forçado) + `caffeinate` vivo + app marcado fecha.
5. Tocar ⚡ de novo: ventoinhas Auto, `caffeinate` morto.
6. Menu → Sair: ventoinhas Auto, nenhum `caffeinate`.
