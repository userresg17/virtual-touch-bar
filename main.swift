import Cocoa
import ServiceManagement
import CoreAudio
import AudioToolbox

// MARK: - Dimensões da barra
// Tudo que define o tamanho da barra fica aqui, pra afinar num lugar só.
// Valores compactos: a barra fica rasa, na proporção do Dock, com botões pequenos.

enum Layout {
    static let buttonHeight: CGFloat = 28      // altura de todos os botões
    static let buttonWidth: CGFloat = 40       // largura padrão dos botões de ícone
    static let escWidth: CGFloat = 44
    static let fKeyWidth: CGFloat = 34
    static let fanWidthNarrow: CGFloat = 42    // "Auto"
    static let fanWidth: CGFloat = 58          // Silêncio / Médio / Booster
    static let toggleWidth: CGFloat = 40       // botão fn / 🎛

    static let symbolPointSize: CGFloat = 13   // tamanho dos ícones SF Symbols
    static let titleFontSize: CGFloat = 12     // tamanho do texto dos botões
    static let cornerRadius: CGFloat = 5

    static let stackSpacing: CGFloat = 4       // espaço entre botões
    static let edgeInset: CGFloat = 5          // respiro interno da barra
    static let separatorHeight: CGFloat = 18

    static let metricsFontSize: CGFloat = 11
    static let metricsWidth: CGFloat = 124

    static let panelCornerRadius: CGFloat = 8
    static let bottomMargin: CGFloat = 8       // distância da barra até a base da tela
}

// MARK: - Envio de teclas de mídia (brilho, volume, play etc.)

enum AuxKey: Int32 {
    case soundUp = 0
    case soundDown = 1
    case brightnessUp = 2
    case brightnessDown = 3
    case mute = 7
    case play = 16
    case next = 17
    case previous = 18
    case illuminationUp = 21
    case illuminationDown = 22
}

func postAuxKey(_ key: AuxKey) {
    func send(down: Bool) {
        let flags: UInt = down ? 0xA00 : 0xB00
        let data1 = Int((Int32(key.rawValue) << 16) | Int32(flags))
        let event = NSEvent.otherEvent(
            with: .systemDefined,
            location: .zero,
            modifierFlags: NSEvent.ModifierFlags(rawValue: flags),
            timestamp: ProcessInfo.processInfo.systemUptime,
            windowNumber: 0,
            context: nil,
            subtype: 8,
            data1: data1,
            data2: -1
        )
        event?.cgEvent?.post(tap: .cghidEventTap)
    }
    send(down: true)
    send(down: false)
}

// MARK: - Brilho da tela (DisplayServices)
// Nos Macs mais novos, as aux keys de brilho param de funcionar; a API
// DisplayServicesSet/GetBrightness controla o painel interno diretamente.

final class ScreenBrightness {
    static let shared = ScreenBrightness()
    private typealias GetFn = @convention(c) (CGDirectDisplayID, UnsafeMutablePointer<Float>) -> Int32
    private typealias SetFn = @convention(c) (CGDirectDisplayID, Float) -> Int32
    private var getFn: GetFn?
    private var setFn: SetFn?

    private init() {
        guard let handle = dlopen(
            "/System/Library/PrivateFrameworks/DisplayServices.framework/DisplayServices", RTLD_NOW
        ) else { return }
        if let sym = dlsym(handle, "DisplayServicesGetBrightness") {
            getFn = unsafeBitCast(sym, to: GetFn.self)
        }
        if let sym = dlsym(handle, "DisplayServicesSetBrightness") {
            setFn = unsafeBitCast(sym, to: SetFn.self)
        }
    }

    func step(up: Bool) {
        guard let getFn = getFn, let setFn = setFn else {
            postAuxKey(up ? .brightnessUp : .brightnessDown)
            return
        }
        let display = CGMainDisplayID()
        var current: Float = 0.5
        _ = getFn(display, &current)
        let delta: Float = up ? 1.0 / 16.0 : -1.0 / 16.0
        _ = setFn(display, max(0, min(1, current + delta)))
    }
}

// MARK: - Retroiluminação do teclado (CoreBrightness)
// Nos Macs com chip T2/Apple Silicon as teclas antigas de iluminação (aux keys 21/22)
// não funcionam mais; é preciso falar direto com o KeyboardBrightnessClient.

final class KeyboardBacklight {
    static let shared = KeyboardBacklight()
    private var client: NSObject?
    private var keyboardID: UInt64 = 1

    private init() {
        guard let bundle = Bundle(path: "/System/Library/PrivateFrameworks/CoreBrightness.framework"),
              bundle.load(),
              let cls = NSClassFromString("KeyboardBrightnessClient") as? NSObject.Type else { return }
        let instance = cls.init()
        client = instance

        let sel = NSSelectorFromString("copyKeyboardBacklightIDs")
        if instance.responds(to: sel),
           let ids = instance.perform(sel)?.takeRetainedValue() as? [NSNumber],
           let first = ids.first {
            keyboardID = first.uint64Value
        }
    }

    private func currentBrightness() -> Float {
        guard let client = client else { return -1 }
        let sel = NSSelectorFromString("brightnessForKeyboard:")
        guard client.responds(to: sel) else { return -1 }
        typealias Fn = @convention(c) (AnyObject, Selector, UInt64) -> Float
        return unsafeBitCast(client.method(for: sel), to: Fn.self)(client, sel, keyboardID)
    }

    func step(up: Bool) {
        guard let client = client else {
            postAuxKey(up ? .illuminationUp : .illuminationDown)
            return
        }
        let sel = NSSelectorFromString("setBrightness:forKeyboard:")
        guard client.responds(to: sel) else { return }
        typealias Fn = @convention(c) (AnyObject, Selector, Float, UInt64) -> Bool

        // Em Macs com T2 a leitura retorna -1 (bloqueada); nesse caso usamos
        // o último nível que este app aplicou, guardado nas preferências.
        let real = currentBrightness()
        let stored = UserDefaults.standard.object(forKey: "kbBrightnessLevel") as? Float
        let current = real >= 0 ? real : (stored ?? 0.5)

        let delta: Float = up ? 1.0 / 16.0 : -1.0 / 16.0
        let newValue = max(0, min(1, current + delta))
        let ok = unsafeBitCast(client.method(for: sel), to: Fn.self)(client, sel, newValue, keyboardID)
        if ok { UserDefaults.standard.set(newValue, forKey: "kbBrightnessLevel") }
    }
}

// MARK: - Volume do sistema (CoreAudio)
// Nos Macs com T2 as aux keys de som (0/1/7) não mexem mais no volume do
// sistema; é preciso falar direto com o dispositivo de saída padrão via CoreAudio.

final class SystemVolume {
    static let shared = SystemVolume()
    private let mainElement = AudioObjectPropertyElement(kAudioObjectPropertyElementMain)

    private func defaultOutputDevice() -> AudioDeviceID? {
        var device = AudioDeviceID(0)
        var size = UInt32(MemoryLayout<AudioDeviceID>.size)
        var addr = AudioObjectPropertyAddress(
            mSelector: kAudioHardwarePropertyDefaultOutputDevice,
            mScope: kAudioObjectPropertyScopeGlobal,
            mElement: mainElement)
        let status = AudioObjectGetPropertyData(
            AudioObjectID(kAudioObjectSystemObject), &addr, 0, nil, &size, &device)
        return status == noErr ? device : nil
    }

    private func volumeAddress() -> AudioObjectPropertyAddress {
        AudioObjectPropertyAddress(
            mSelector: kAudioHardwareServiceDeviceProperty_VirtualMainVolume,
            mScope: kAudioDevicePropertyScopeOutput,
            mElement: mainElement)
    }

    private func muteAddress() -> AudioObjectPropertyAddress {
        AudioObjectPropertyAddress(
            mSelector: kAudioDevicePropertyMute,
            mScope: kAudioDevicePropertyScopeOutput,
            mElement: mainElement)
    }

    func getVolume() -> Float? {
        guard let device = defaultOutputDevice() else { return nil }
        var addr = volumeAddress()
        guard AudioObjectHasProperty(device, &addr) else { return nil }
        var volume = Float(0)
        var size = UInt32(MemoryLayout<Float>.size)
        let status = AudioObjectGetPropertyData(device, &addr, 0, nil, &size, &volume)
        return status == noErr ? volume : nil
    }

    func setVolume(_ value: Float) {
        guard let device = defaultOutputDevice() else { return }
        var addr = volumeAddress()
        var settable = DarwinBoolean(false)
        guard AudioObjectHasProperty(device, &addr),
              AudioObjectIsPropertySettable(device, &addr, &settable) == noErr,
              settable.boolValue else { return }
        var volume = max(0, min(1, value))
        AudioObjectSetPropertyData(
            device, &addr, 0, nil, UInt32(MemoryLayout<Float>.size), &volume)
    }

    func step(up: Bool) {
        if up { setMuted(false) } // subir volume tira o mudo, como na tecla física
        let current = getVolume() ?? 0.5
        let delta: Float = up ? 1.0 / 16.0 : -1.0 / 16.0
        setVolume(current + delta)
    }

    func isMuted() -> Bool {
        guard let device = defaultOutputDevice() else { return false }
        var addr = muteAddress()
        guard AudioObjectHasProperty(device, &addr) else { return false }
        var muted = UInt32(0)
        var size = UInt32(MemoryLayout<UInt32>.size)
        let status = AudioObjectGetPropertyData(device, &addr, 0, nil, &size, &muted)
        return status == noErr && muted != 0
    }

    func setMuted(_ muted: Bool) {
        guard let device = defaultOutputDevice() else { return }
        var addr = muteAddress()
        var settable = DarwinBoolean(false)
        guard AudioObjectHasProperty(device, &addr),
              AudioObjectIsPropertySettable(device, &addr, &settable) == noErr,
              settable.boolValue else { return }
        var value = UInt32(muted ? 1 : 0)
        AudioObjectSetPropertyData(
            device, &addr, 0, nil, UInt32(MemoryLayout<UInt32>.size), &value)
    }

    func toggleMute() {
        setMuted(!isMuted())
    }
}

// MARK: - Ventoinhas (SMC via helper privilegiado)
// Escrever a velocidade das ventoinhas no SMC exige root; o app instala uma
// única vez o helper `smcfan` (setuid root, só aceita os modos fixos) e
// depois o chama direto, sem pedir senha de novo.

enum FanMode: String, CaseIterable {
    case auto
    case silencioso = "silent"
    case medio = "medium"
    case booster = "max"

    var label: String {
        switch self {
        case .auto: return "Auto"
        case .silencioso: return "Silêncio"
        case .medio: return "Médio"
        case .booster: return "Booster"
        }
    }
}

final class FanControl {
    static let shared = FanControl()
    private let helperPath = "/usr/local/libexec/smcfan"

    private(set) var mode: FanMode =
        FanMode(rawValue: UserDefaults.standard.string(forKey: "fanMode") ?? "") ?? .auto

    private var bundledHelper: String? {
        Bundle.main.path(forResource: "smcfan", ofType: nil)
    }

    // Helper instalado e idêntico ao do bundle (reinstala sozinho após updates).
    private var helperReady: Bool {
        guard let bundled = bundledHelper,
              FileManager.default.isExecutableFile(atPath: helperPath) else { return false }
        return FileManager.default.contentsEqual(atPath: helperPath, andPath: bundled)
    }

    private func installHelper() -> Bool {
        guard let bundled = bundledHelper else { return false }
        let shell = "mkdir -p /usr/local/libexec && cp -f '\(bundled)' '\(helperPath)'"
            + " && chown root:wheel '\(helperPath)' && chmod 4755 '\(helperPath)'"
        let process = Process()
        process.executableURL = URL(fileURLWithPath: "/usr/bin/osascript")
        process.arguments = ["-e", "do shell script \"\(shell)\" with administrator privileges"]
        do { try process.run() } catch { return false }
        process.waitUntilExit()
        return process.terminationStatus == 0
    }

    private func runHelper(_ mode: FanMode) -> Bool {
        let process = Process()
        process.executableURL = URL(fileURLWithPath: helperPath)
        process.arguments = [mode.rawValue]
        do { try process.run() } catch { return false }
        process.waitUntilExit()
        return process.terminationStatus == 0
    }

    func set(_ newMode: FanMode, completion: @escaping (Bool) -> Void) {
        DispatchQueue.global().async { [self] in
            let ok = (helperReady || installHelper()) && runHelper(newMode)
            DispatchQueue.main.async {
                if ok {
                    self.mode = newMode
                    UserDefaults.standard.set(newMode.rawValue, forKey: "fanMode")
                } else {
                    NSSound.beep()
                }
                completion(ok)
            }
        }
    }

    // Devolve o controle ao sistema ao sair, pra não deixar ventoinha travada.
    func releaseOnQuit() {
        guard mode != .auto, FileManager.default.isExecutableFile(atPath: helperPath) else { return }
        if runHelper(.auto) {
            UserDefaults.standard.set(FanMode.auto.rawValue, forKey: "fanMode")
        }
    }
}

// MARK: - Envio de teclas F e esc para o app em foco

func postKeyCode(_ keyCode: CGKeyCode) {
    let source = CGEventSource(stateID: .hidSystemState)
    CGEvent(keyboardEventSource: source, virtualKey: keyCode, keyDown: true)?.post(tap: .cghidEventTap)
    CGEvent(keyboardEventSource: source, virtualKey: keyCode, keyDown: false)?.post(tap: .cghidEventTap)
}

let escKeyCode: CGKeyCode = 53
let fKeyCodes: [CGKeyCode] = [122, 120, 99, 118, 96, 97, 98, 100, 101, 109, 103, 111] // F1...F12

// MARK: - Botão que funciona sem roubar o foco do app ativo

final class BarButton: NSButton {
    override var acceptsFirstResponder: Bool { false }
    override func acceptsFirstMouse(for event: NSEvent?) -> Bool { true }

    // Cor de fundo "em repouso"; muda quando o botão vira o modo selecionado.
    var baseColor = NSColor(white: 0.28, alpha: 0.7) {
        didSet { layer?.backgroundColor = baseColor.cgColor }
    }

    private var trackingArea: NSTrackingArea?

    override func updateTrackingAreas() {
        super.updateTrackingAreas()
        if let area = trackingArea { removeTrackingArea(area) }
        let area = NSTrackingArea(rect: bounds,
                                  options: [.mouseEnteredAndExited, .activeAlways],
                                  owner: self, userInfo: nil)
        addTrackingArea(area)
        trackingArea = area
    }

    override func mouseEntered(with event: NSEvent) {
        let hover = baseColor.blended(withFraction: 0.3, of: .white) ?? baseColor
        layer?.backgroundColor = hover.cgColor
    }

    override func mouseExited(with event: NSEvent) {
        layer?.backgroundColor = baseColor.cgColor
    }
}

func makeSeparator() -> NSView {
    let separator = NSView()
    separator.wantsLayer = true
    separator.layer?.backgroundColor = NSColor(white: 0.45, alpha: 1).cgColor
    separator.translatesAutoresizingMaskIntoConstraints = false
    separator.widthAnchor.constraint(equalToConstant: 1).isActive = true
    separator.heightAnchor.constraint(equalToConstant: Layout.separatorHeight).isActive = true
    return separator
}

func makeButton(symbol: String? = nil, title: String? = nil, width: CGFloat = Layout.buttonWidth,
                tint: NSColor = .white,
                target: AnyObject, action: Selector, tag: Int = 0) -> BarButton {
    let button = BarButton(frame: .zero)
    button.isBordered = false
    button.wantsLayer = true
    button.layer?.backgroundColor = NSColor(white: 0.28, alpha: 0.7).cgColor
    button.layer?.cornerRadius = Layout.cornerRadius
    button.target = target
    button.action = action
    button.tag = tag
    button.imagePosition = .imageOnly

    if let symbol = symbol,
       let image = NSImage(systemSymbolName: symbol, accessibilityDescription: symbol) {
        let config = NSImage.SymbolConfiguration(pointSize: Layout.symbolPointSize, weight: .medium)
        button.image = image.withSymbolConfiguration(config)
        button.contentTintColor = tint
    } else if let title = title {
        button.attributedTitle = NSAttributedString(
            string: title,
            attributes: [
                .foregroundColor: NSColor.white,
                .font: NSFont.systemFont(ofSize: Layout.titleFontSize, weight: .medium)
            ])
        button.imagePosition = .noImage
    }

    button.translatesAutoresizingMaskIntoConstraints = false
    button.widthAnchor.constraint(equalToConstant: width).isActive = true
    button.heightAnchor.constraint(equalToConstant: Layout.buttonHeight).isActive = true
    return button
}

func makeMetricsLabel() -> NSTextField {
    let label = NSTextField(labelWithString: "—")
    label.font = NSFont.monospacedDigitSystemFont(ofSize: Layout.metricsFontSize, weight: .medium)
    label.textColor = .white
    label.alignment = .center
    label.translatesAutoresizingMaskIntoConstraints = false
    label.widthAnchor.constraint(equalToConstant: Layout.metricsWidth).isActive = true
    return label
}

// MARK: - Painel flutuante (a "Touch Bar")

final class TouchBarPanel: NSPanel {
    override var canBecomeKey: Bool { false }
    override var canBecomeMain: Bool { false }
}

// MARK: - App

final class AppDelegate: NSObject, NSApplicationDelegate, NSMenuDelegate {
    private var panel: TouchBarPanel!
    private var stack: NSStackView!
    private var statusItem: NSStatusItem!
    private var showingFKeys = false
    private var fanButtons: [FanMode: BarButton] = [:]
    private var fanMenuItems: [FanMode: NSMenuItem] = [:]
    private var metricsLabel: NSTextField!
    private var metricsTimer: Timer?
    private var turboMenuItem: NSMenuItem?
    private let inputMonitor = InputMonitor()

    func applicationDidFinishLaunching(_ notification: Notification) {
        requestAccessibilityIfNeeded()
        registerLoginItemOnce()
        buildPanel()
        buildStatusItem()
        installFnMonitors()
        startMetricsTimer()

        TurboMode.shared.onChange = { [weak self] in
            self?.turboMenuItem?.state = TurboMode.shared.isOn ? .on : .off
            if self?.panel.isVisible == true { self?.populateStack() }
            self?.updateMetricsLabel()
        }
    }

    func applicationWillTerminate(_ notification: Notification) {
        TurboMode.shared.onAppTerminate()
        if #available(macOS 14.4, *) { AudioAmplifier.shared.stop() }
        FanControl.shared.releaseOnQuit()
    }

    // Registra o app pra abrir junto com o Mac (só na primeira vez,
    // pra respeitar se o usuário desativar depois pelo menu).
    private func registerLoginItemOnce() {
        guard #available(macOS 13.0, *) else { return }
        let key = "didAutoRegisterLoginItem"
        guard !UserDefaults.standard.bool(forKey: key) else { return }
        UserDefaults.standard.set(true, forKey: key)
        if SMAppService.mainApp.status != .enabled {
            try? SMAppService.mainApp.register()
        }
    }

    // Pede a permissão de Acessibilidade (necessária pra detectar o fn
    // e pra enviar as teclas pro sistema).
    private func requestAccessibilityIfNeeded() {
        let options = [kAXTrustedCheckOptionPrompt.takeUnretainedValue() as String: true] as CFDictionary
        AXIsProcessTrustedWithOptions(options)
    }

    // MARK: Painel

    private func buildPanel() {
        panel = TouchBarPanel(
            contentRect: NSRect(x: 0, y: 0, width: 800, height: 60),
            styleMask: [.borderless, .nonactivatingPanel],
            backing: .buffered,
            defer: false
        )
        panel.level = .statusBar
        panel.isFloatingPanel = true
        panel.hidesOnDeactivate = false
        panel.isOpaque = false
        panel.backgroundColor = .clear
        panel.hasShadow = true
        panel.collectionBehavior = [.canJoinAllSpaces, .fullScreenAuxiliary, .stationary]
        panel.isMovableByWindowBackground = true

        let container = NSView()
        container.wantsLayer = true
        container.layer?.backgroundColor = NSColor(white: 0.06, alpha: 0.6).cgColor
        container.layer?.cornerRadius = Layout.panelCornerRadius

        stack = NSStackView()
        stack.orientation = .horizontal
        stack.spacing = Layout.stackSpacing
        stack.edgeInsets = NSEdgeInsets(top: Layout.edgeInset, left: Layout.edgeInset,
                                        bottom: Layout.edgeInset, right: Layout.edgeInset)
        stack.translatesAutoresizingMaskIntoConstraints = false

        container.addSubview(stack)
        NSLayoutConstraint.activate([
            stack.topAnchor.constraint(equalTo: container.topAnchor),
            stack.bottomAnchor.constraint(equalTo: container.bottomAnchor),
            stack.leadingAnchor.constraint(equalTo: container.leadingAnchor),
            stack.trailingAnchor.constraint(equalTo: container.trailingAnchor),
        ])

        panel.contentView = container
        populateStack()
    }

    private func populateStack() {
        stack.arrangedSubviews.forEach { view in
            stack.removeArrangedSubview(view)
            view.removeFromSuperview()
        }

        // esc sempre presente, como na Touch Bar real
        stack.addArrangedSubview(makeButton(title: "esc", width: Layout.escWidth,
                                            target: self, action: #selector(pressEsc)))

        if showingFKeys {
            for (index, _) in fKeyCodes.enumerated() {
                stack.addArrangedSubview(makeButton(title: "F\(index + 1)", width: Layout.fKeyWidth,
                                                    target: self, action: #selector(pressFKey(_:)),
                                                    tag: index))
            }
        } else {
            // Brilho da tela via DisplayServices (tag 0 = diminuir, 1 = aumentar)
            stack.addArrangedSubview(makeButton(symbol: "sun.min.fill",
                                                target: self, action: #selector(pressScreenBrightness(_:)), tag: 0))
            stack.addArrangedSubview(makeButton(symbol: "sun.max.fill",
                                                target: self, action: #selector(pressScreenBrightness(_:)), tag: 1))

            // Retroiluminação do teclado via CoreBrightness (tag 0 = diminuir, 1 = aumentar)
            stack.addArrangedSubview(makeButton(symbol: "light.min",
                                                target: self, action: #selector(pressBacklight(_:)), tag: 0))
            stack.addArrangedSubview(makeButton(symbol: "light.max",
                                                target: self, action: #selector(pressBacklight(_:)), tag: 1))

            // Mídia (play/pause/avançar) via aux keys — vão pro app de mídia e funcionam.
            let mediaKeys: [(String, AuxKey)] = [
                ("backward.fill", .previous),
                ("playpause.fill", .play),
                ("forward.fill", .next),
            ]
            for (symbol, key) in mediaKeys {
                stack.addArrangedSubview(makeButton(symbol: symbol,
                                                    target: self, action: #selector(pressAuxKey(_:)),
                                                    tag: Int(key.rawValue)))
            }

            // Volume via CoreAudio direto (as aux keys de som não funcionam no T2).
            stack.addArrangedSubview(makeButton(symbol: "speaker.slash.fill",
                                                target: self, action: #selector(pressMute)))
            stack.addArrangedSubview(makeButton(symbol: "speaker.wave.1.fill",
                                                target: self, action: #selector(pressVolume(_:)), tag: 0))
            stack.addArrangedSubview(makeButton(symbol: "speaker.wave.3.fill",
                                                target: self, action: #selector(pressVolume(_:)), tag: 1))

            if #available(macOS 14.4, *) {
                stack.addArrangedSubview(makeButton(symbol: "waveform.badge.plus",
                                                    target: self, action: #selector(toggleAmplifier)))
            }

            stack.addArrangedSubview(makeSeparator())

            // Captura de tela: tela inteira, janela, seleção e gravação
            stack.addArrangedSubview(makeButton(symbol: "display",
                                                target: self, action: #selector(captureFullScreen)))
            stack.addArrangedSubview(makeButton(symbol: "macwindow",
                                                target: self, action: #selector(captureWindow)))
            stack.addArrangedSubview(makeButton(symbol: "rectangle.dashed",
                                                target: self, action: #selector(captureSelection)))
            stack.addArrangedSubview(makeButton(symbol: "record.circle",
                                                tint: .systemRed,
                                                target: self, action: #selector(startRecording)))

            stack.addArrangedSubview(makeSeparator())

            // Ventoinhas: seletor Auto / Silêncio / Médio / Booster
            fanButtons.removeAll()
            for (index, mode) in FanMode.allCases.enumerated() {
                let button = makeButton(title: mode.label,
                                        width: mode == .auto ? Layout.fanWidthNarrow : Layout.fanWidth,
                                        target: self, action: #selector(pressFanMode(_:)),
                                        tag: index)
                fanButtons[mode] = button
                stack.addArrangedSubview(button)
            }
            refreshFanSelection()

            stack.addArrangedSubview(makeSeparator())
            let turboButton = makeButton(symbol: "bolt.fill",
                                         tint: TurboMode.shared.isOn ? .systemYellow : .white,
                                         target: self, action: #selector(pressTurbo))
            turboButton.baseColor = TurboMode.shared.isOn
                ? NSColor.systemOrange.withAlphaComponent(0.85)
                : NSColor(white: 0.28, alpha: 0.7)
            stack.addArrangedSubview(turboButton)

            stack.addArrangedSubview(makeSeparator())
            metricsLabel = makeMetricsLabel()
            stack.addArrangedSubview(metricsLabel)
            updateMetricsLabel()
        }

        // Botão que alterna entre teclas de mídia e F1–F12
        let toggleTitle = showingFKeys ? "🎛" : "Fn"
        stack.addArrangedSubview(makeButton(title: toggleTitle, width: Layout.toggleWidth,
                                            target: self, action: #selector(toggleLayout)))

        stack.layoutSubtreeIfNeeded()
        let size = stack.fittingSize
        resizePanel(to: size)
    }

    private func resizePanel(to size: NSSize) {
        let screen = screenWithMouse()
        let frame = screen.visibleFrame
        let x = frame.midX - size.width / 2
        let y = frame.minY + Layout.bottomMargin
        panel.setFrame(NSRect(x: x, y: y, width: size.width, height: size.height), display: true)
    }

    private func screenWithMouse() -> NSScreen {
        let mouse = NSEvent.mouseLocation
        return NSScreen.screens.first { NSMouseInRect(mouse, $0.frame, false) }
            ?? NSScreen.main
            ?? NSScreen.screens[0]
    }

    // MARK: Monitor da tecla fn
    // Usa CGEventTap (via InputMonitor) em vez de NSEvent: só o event tap
    // consegue ENGOLIR o "x" do chord fn+x (o NSEvent global só observa,
    // deixaria o "x" vazar pro app em foco).

    private func installFnMonitors() {
        inputMonitor.onFnTap = { [weak self] in self?.togglePanel() }
        inputMonitor.onAmplifierChord = { [weak self] in self?.toggleAmplifier() }
        inputMonitor.start()
    }

    @objc private func toggleAmplifier() {
        if #available(macOS 14.4, *) {
            AmplifierPanel.shared.toggle()
        } else {
            NSSound.beep()   // amplificador exige macOS 14.4+
        }
    }

    @objc private func togglePanel() {
        if panel.isVisible {
            panel.orderOut(nil)
        } else {
            populateStack()
            panel.orderFrontRegardless()
        }
    }

    // MARK: Ações dos botões

    @objc private func pressEsc() { postKeyCode(escKeyCode) }

    @objc private func pressFKey(_ sender: NSButton) {
        postKeyCode(fKeyCodes[sender.tag])
    }

    @objc private func pressAuxKey(_ sender: NSButton) {
        if let key = AuxKey(rawValue: Int32(sender.tag)) { postAuxKey(key) }
    }

    @objc private func pressMute() {
        SystemVolume.shared.toggleMute()
    }

    @objc private func pressVolume(_ sender: NSButton) {
        SystemVolume.shared.step(up: sender.tag == 1)
    }

    @objc private func pressBacklight(_ sender: NSButton) {
        KeyboardBacklight.shared.step(up: sender.tag == 1)
    }

    @objc private func pressScreenBrightness(_ sender: NSButton) {
        ScreenBrightness.shared.step(up: sender.tag == 1)
    }

    // MARK: Ventoinhas

    @objc private func pressTurbo() {
        TurboMode.shared.toggle()
    }

    // MARK: Apps pesados (submenu reconstruído ao abrir)

    func menuNeedsUpdate(_ menu: NSMenu) {
        rebuildHeavyAppsSubmenu(menu)
    }

    private func rebuildHeavyAppsSubmenu(_ menu: NSMenu) {
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

    @objc private func pressFanMode(_ sender: NSButton) {
        applyFanMode(index: sender.tag)
    }

    @objc private func pressFanModeMenu(_ sender: NSMenuItem) {
        applyFanMode(index: sender.tag)
    }

    private func applyFanMode(index: Int) {
        let mode = FanMode.allCases[index]
        guard mode != FanControl.shared.mode else { return }
        FanControl.shared.set(mode) { [weak self] _ in
            self?.refreshFanSelection()
        }
    }

    private func refreshFanSelection() {
        let current = FanControl.shared.mode
        for (mode, button) in fanButtons {
            button.baseColor = mode == current
                ? NSColor.systemBlue.withAlphaComponent(0.85)
                : NSColor(white: 0.28, alpha: 0.7)
        }
        for (mode, item) in fanMenuItems {
            item.state = mode == current ? .on : .off
        }
    }

    // MARK: Mostrador de métricas

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

    // MARK: Captura de tela

    private func capturePath() -> String {
        let formatter = DateFormatter()
        formatter.dateFormat = "yyyy-MM-dd 'às' HH.mm.ss"
        let name = "Captura de Tela \(formatter.string(from: Date())).png"
        return NSString(string: "~/Desktop/\(name)").expandingTildeInPath
    }

    private func runScreencapture(_ arguments: [String]) {
        let process = Process()
        process.executableURL = URL(fileURLWithPath: "/usr/sbin/screencapture")
        process.arguments = arguments
        try? process.run()
    }

    // Esconde a barra antes de capturar pra ela não sair na foto/gravação.
    @objc private func captureFullScreen() {
        panel.orderOut(nil)
        DispatchQueue.main.asyncAfter(deadline: .now() + 0.4) { [self] in
            runScreencapture([capturePath()])
        }
    }

    @objc private func captureWindow() {
        panel.orderOut(nil)
        runScreencapture(["-iW", capturePath()])
    }

    @objc private func captureSelection() {
        panel.orderOut(nil)
        runScreencapture(["-is", capturePath()])
    }

    @objc private func startRecording() {
        panel.orderOut(nil)
        NSWorkspace.shared.open(URL(fileURLWithPath: "/System/Applications/Utilities/Screenshot.app"))
    }

    @objc private func toggleLayout() {
        showingFKeys.toggle()
        populateStack()
    }

    // MARK: Ícone na barra de menu

    private func buildStatusItem() {
        statusItem = NSStatusBar.system.statusItem(withLength: NSStatusItem.squareLength)
        statusItem.button?.image = NSImage(systemSymbolName: "keyboard",
                                           accessibilityDescription: "Virtual Touch Bar")

        let menu = NSMenu()
        menu.addItem(NSMenuItem(title: "Mostrar/Ocultar Touch Bar (fn)",
                                action: #selector(togglePanel), keyEquivalent: ""))
        menu.addItem(NSMenuItem(title: "Alternar F1–F12 / Mídia",
                                action: #selector(toggleLayout), keyEquivalent: ""))

        // Submenu das ventoinhas, pra ajustar mesmo com o painel escondido
        let fanSubmenu = NSMenu()
        fanMenuItems.removeAll()
        for (index, mode) in FanMode.allCases.enumerated() {
            let item = NSMenuItem(title: mode.label,
                                  action: #selector(pressFanModeMenu(_:)), keyEquivalent: "")
            item.tag = index
            item.target = self
            fanMenuItems[mode] = item
            fanSubmenu.addItem(item)
        }
        let fanItem = NSMenuItem(title: "Ventoinhas", action: nil, keyEquivalent: "")
        menu.addItem(fanItem)
        menu.setSubmenu(fanSubmenu, for: fanItem)
        refreshFanSelection()

        menu.addItem(.separator())

        let turboItem = NSMenuItem(title: "Modo Turbo / Game",
                                   action: #selector(pressTurbo), keyEquivalent: "")
        turboItem.state = TurboMode.shared.isOn ? .on : .off
        turboMenuItem = turboItem
        menu.addItem(turboItem)

        let heavyItem = NSMenuItem(title: "Apps pra fechar no Turbo", action: nil, keyEquivalent: "")
        let heavySubmenu = NSMenu()
        heavySubmenu.delegate = self
        menu.setSubmenu(heavySubmenu, for: heavyItem)
        menu.addItem(heavyItem)

        menu.addItem(.separator())

        if #available(macOS 13.0, *) {
            let loginItem = NSMenuItem(title: "Iniciar com o Mac",
                                       action: #selector(toggleLoginItem(_:)), keyEquivalent: "")
            loginItem.state = SMAppService.mainApp.status == .enabled ? .on : .off
            menu.addItem(loginItem)
            menu.addItem(.separator())
        }

        menu.addItem(NSMenuItem(title: "Abrir permissões de Acessibilidade…",
                                action: #selector(openAccessibilitySettings), keyEquivalent: ""))
        menu.addItem(.separator())
        menu.addItem(NSMenuItem(title: "Sair", action: #selector(quit), keyEquivalent: "q"))

        menu.items.forEach { $0.target = self }
        statusItem.menu = menu
    }

    @available(macOS 13.0, *)
    @objc private func toggleLoginItem(_ sender: NSMenuItem) {
        do {
            if SMAppService.mainApp.status == .enabled {
                try SMAppService.mainApp.unregister()
                sender.state = .off
            } else {
                try SMAppService.mainApp.register()
                sender.state = .on
            }
        } catch {
            NSLog("Falha ao alterar item de login: \(error)")
        }
    }

    @objc private func openAccessibilitySettings() {
        let url = URL(string: "x-apple.systempreferences:com.apple.preference.security?Privacy_Accessibility")!
        NSWorkspace.shared.open(url)
    }

    @objc private func quit() { NSApp.terminate(nil) }
}

let app = NSApplication.shared
runSelfTestsIfRequested()
app.setActivationPolicy(.accessory)
let delegate = AppDelegate()
app.delegate = delegate
app.run()
