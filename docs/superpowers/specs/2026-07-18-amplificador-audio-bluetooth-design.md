# Amplificador de Áudio (Bluetooth) — Design

**Data:** 2026-07-18
**Projeto:** Virtual Touch Bar
**Plataforma alvo:** macOS 15.7.7 (Darwin 24.6) — API de *process tap* do Core Audio (macOS 14.4+) disponível

## Problema

A soundbar do usuário sai **alta e limpa no cabo (AUX)** e **muito baixa no Bluetooth**, mesmo com o volume do Mac no máximo. Diagnóstico confirmado:

- No Bluetooth, os botões +/- da soundbar **pulam faixa** em vez de mudar volume → a barra **não tem controle de volume próprio no BT**; o volume é 100% escravo do Mac (*absolute volume*).
- O **estágio amplificador da entrada Bluetooth da soundbar é fisicamente mais fraco** que o da entrada de cabo.

**Conclusão honesta:** o gargalo é o hardware da soundbar. Nenhum software alcança o amplificador interno dela. O `SystemVolume` atual do app só mexe no volume virtual (0–100%), que é o teto que não resolve.

## Meta e limitações (explícitas)

- **Meta:** entregar **ganho real** de volume no BT, "melhor esforço". **NÃO** promete os 80% do cabo.
- Só é possível ganhar volume **processando as amostras de áudio** (ganho > 0 dBFS com limiter), não setando volume.
- A eficácia depende da folga da fonte: conteúdo já masterizado perto de 0 dBFS (muita música) ganha pouco; voz/vídeo/conteúdo mais baixo ganha mais.
- Teto de segurança: **+12 dB (ganho linear 4.0x)**, limiter sempre ligado.

## Visão geral da solução

Três partes, num arquivo novo `amplifier.swift` (espelhando o padrão de `turbo.swift`), mais ajustes pontuais em `main.swift`:

1. **Gatilho `fn + x`** — via `CGEventTap`, sem quebrar o comportamento atual do `fn`.
2. **Motor de amplificação** — `AudioAmplifier`, usando process tap + aggregate device + ganho/limiter.
3. **HUD flutuante** — `AmplifierPanel`, controle visual (slider, presets, medidor).

Mais **memória por dispositivo** do último ganho usado.

---

## 1. Gatilho `fn + x` (CGEventTap)

**Problema:** hoje `installFnMonitors()` usa `NSEvent` e alterna a barra no **pressionar** do `fn`. Um chord "fn segurado + x" faria a barra piscar, e o `NSEvent` global só observa (não consegue **engolir** o `x`, que digitaria "x" no app em foco).

**Solução:** substituir os monitores `NSEvent` por um **`CGEventTap`** em `kCGSessionEventTapLocation` (ativo, não listen-only), escutando `flagsChanged` e `keyDown`. O app já tem permissão de Acessibilidade, requisito do event tap.

**Máquina de estados:**
- Detectar o estado do `fn` pela flag `.maskSecondaryFn` de cada evento (mais confiável que keyCode 63).
- Estados: `fnDown: Bool`, `fnConsumed: Bool`.
- **fn passa a pressionado** (`.maskSecondaryFn` aparece): `fnDown = true`, `fnConsumed = false`. Deixa passar.
- **`x` (keyCode 7) em `keyDown` com `fnDown == true`**: abre/alterna o HUD do amplificador, `fnConsumed = true`, **retorna `nil` (engole o `x`)**.
- **fn passa a solto** (`.maskSecondaryFn` some): se `fnDown && !fnConsumed` → `togglePanel()` (tap simples da barra). `fnDown = false`. Deixa passar.
- Reabilitar o tap em `.tapDisabledByTimeout` / `.tapDisabledByUserInput`.

**Efeito líquido:** `fn` sozinho continua abrindo a barra (agora no soltar, imperceptível); `fn+x` abre o amplificador sem piscar a barra e sem digitar "x".

**Encapsulamento:** classe `InputMonitor` em `amplifier.swift` (ou `main.swift`), com callbacks `onFnTap` e `onAmplifierChord`, para o `AppDelegate` conectar. Remove o `installFnMonitors()` atual.

---

## 2. Motor de amplificação (`AudioAmplifier`)

Singleton `AudioAmplifier.shared`. Usa a API de process tap (macOS 14.4+).

**Montagem (ao ligar o boost):**
1. Descobrir o dispositivo de saída padrão atual (reusar a lógica de `SystemVolume.defaultOutputDevice()`), guardar seu UID.
2. Criar `CATapDescription` — tap **global** (todos os processos), **estéreo**, `muteBehavior = .mutedWhenTapped` (o caminho original dos processos é mudado; só a nossa cópia processada toca).
3. `AudioHardwareCreateProcessTap` → `tapID`. Ler o formato do tap (`kAudioTapPropertyFormat`, `AudioStreamBasicDescription`).
4. Criar **aggregate device privado** (`AudioHardwareCreateAggregateDevice`): `kAudioAggregateDeviceIsPrivateKey = 1`, sub-device principal = dispositivo real (por UID), lista de sub-devices = [dispositivo real], `kAudioAggregateDeviceTapListKey` = [UUID do tap].
5. Instalar **IOProc** no aggregate: entrada = áudio do sistema (tap); saída = dispositivo real. Por amostra: aplicar **ganho linear** e depois **limiter**; escrever na saída.

**Modelo de roteamento (recomendado):** *sem trocar o dispositivo de saída do sistema*. O tap muda o caminho original e o aggregate reinjeta a versão processada no dispositivo real. Menos disruptivo (o menu de som do macOS continua mostrando a soundbar).
**Fallback:** se o mute do original se mostrar não confiável (áudio dobrado), trocar o default output do sistema para o aggregate enquanto o boost estiver ligado e restaurar ao desligar.

**Processamento de áudio (no IOProc):**
- **Ganho:** linear `1.0` (0 dB) a `4.0` (+12 dB).
- **Limiter:** feed-forward, threshold ~ **-1 dBFS**, ataque ~5 ms, release ~50 ms, soft-knee — evita estouro/chiado ao subir. (Função pura testável.)
- **Ramp de ganho:** interpolar mudanças de ganho em ~30 ms para não dar "pop".
- Suporte estéreo; fallback mono conforme o formato do tap.

**Desligar o boost:** parar/remover o IOProc, destruir o aggregate (`AudioHardwareDestroyAggregateDevice`) e o tap (`AudioHardwareDestroyProcessTap`), restaurar estado. **Sempre** restaurar — nunca deixar o sistema mudo.

**Robustez a mudança de dispositivo:**
- Observar `kAudioHardwarePropertyDefaultOutputDevice` e a vida do dispositivo real.
- Se o dispositivo real sumir (BT desconectou) → derrubar tap+aggregate e desligar o boost com segurança.
- Se o boost estava ligado e um novo dispositivo aparece, remontar (respeitando a memória por dispositivo).

**Falha segura:** qualquer erro de Core Audio → boost desligado + dispositivo original restaurado. Mensagem discreta (ex.: `NSSound.beep()` + log), como o `FanControl` faz.

**Permissão:** capturar áudio do sistema pode exigir **uma** autorização (TCC) na primeira vez. Adicionar `NSAudioCaptureUsageDescription` ao `Info.plist` (no `build.sh`) com texto explicativo. Se aparecer o prompt, é aceitar uma vez.

---

## 3. HUD (`AmplifierPanel`)

`NSPanel` não-ativador (mesma linha do `TouchBarPanel`), estilo escuro arredondado, exibido acima da barra / base central da tela. `fn+x` **alterna** aberto/fechado. Um botão **🔊+** na barra também abre (bônus, sem depender do teclado).

**Conteúdo:**
- Título "Amplificador".
- **Dispositivo de saída atual** (ex.: "🔵 Bluetooth: [nome da soundbar]") — deixa claro que age no BT.
- **Slider de ganho** 100% → 400%, com o **dB** ao lado.
- **Presets:** `Off` (100% / boost desligado) · `Boost` (~200% / +6 dB) · `Máx` (400% / +12 dB).
- **Medidor de nível (pico)** + **luz de "limiter atuando"** — mostra quando está no limite real.
- Atualiza o ganho ao vivo conforme o slider se move (com ramp).

---

## 4. Memória por dispositivo

- `UserDefaults`: mapa `deviceUID → { ganho, boostLigado }`.
- Ao trocar de saída, restaurar o último ganho daquele dispositivo.
- Ao reconectar a soundbar no BT, reaplicar o ganho/estado que estavam salvos para ela.
- Chave de identificação: UID do dispositivo Core Audio (`kAudioDevicePropertyDeviceUID`).

---

## Onde encaixa no código

- **Novo `amplifier.swift`:** `AudioAmplifier` (motor, singleton), `AmplifierPanel` (HUD), `AmplifierPreset` (enum), e o `InputMonitor` (CGEventTap) — ou o `InputMonitor` fica em `main.swift`.
- **`main.swift`:**
  - Remover `installFnMonitors()`; instalar o `CGEventTap` com a lógica tap/chord.
  - Adicionar o botão 🔊+ no `populateStack()`.
  - `applicationWillTerminate` → `AudioAmplifier.shared.teardownRestoringAudio()` (nunca sair deixando áudio roteado/mudo), junto do `FanControl.releaseOnQuit()` já existente.
- **`build.sh`:** frameworks já linkados (CoreAudio/AudioToolbox); adicionar `NSAudioCaptureUsageDescription` no `Info.plist`.

## Testes e verificação

- **Unitário (via `runSelfTestsIfRequested`):** funções puras de ganho e limiter (entrada → saída esperada, sem estouro acima do threshold).
- **Manual (fluxo real):**
  1. Soundbar no BT tocando áudio → `fn+x` → subir ganho → confirmar **mais alto** e **sem distorção** no limite.
  2. `fn` sozinho ainda abre/fecha a barra; segurar `fn`+`x` **não digita "x"** nem pisca a barra.
  3. Desconectar o BT com boost ligado → áudio **restaura sozinho**, sem travar/mudo.
  4. Sair do app com boost ligado → áudio volta ao normal.

## Riscos conhecidos

- **Troca/mute de dispositivo é a parte com mais casos de borda** — mitigado pelo modelo sem-troca + fallback + falha segura + restauração garantida.
- **Ganho pode não ser perceptível** em conteúdo já perto de 0 dBFS — limitação honesta assumida com o usuário.
- **Prompt de permissão de captura de áudio** pode aparecer uma vez.
