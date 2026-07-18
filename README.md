# Virtual Touch Bar

Uma **Touch Bar virtual** para macOS — uma barra flutuante e leve, no estilo do Dock, para Macs **sem Touch Bar física** (ou com chip T2, onde várias teclas de função pararam de funcionar). Aparece ao apertar `fn` e some ao apertar de novo.

Escrita em **Swift nativo**, sem dependências. Roda como item da barra de menus (sem ícone no Dock).

> 🇧🇷 Projeto em português. Short English summary at the bottom.

![status](https://img.shields.io/badge/plataforma-macOS%2011%2B-blue) ![licença](https://img.shields.io/badge/licen%C3%A7a-MIT-green)

## Por que existe

Em Macs mais novos (T2 / Apple Silicon) e teclados sem a Touch Bar, várias teclas de atalho antigas **deixaram de funcionar** — brilho, volume, retroiluminação do teclado. Este app fala **direto com as APIs do sistema** (CoreAudio, DisplayServices, CoreBrightness, SMC) para trazer tudo de volta numa barra só, bonita e discreta.

## Recursos

- **`esc`** e alternância **F1–F12 / teclas de mídia**
- **Brilho da tela** (via `DisplayServices`, funciona no T2)
- **Retroiluminação do teclado** (via `CoreBrightness`)
- **Mídia**: anterior / play-pause / próxima
- **Volume**: mudo / diminuir / aumentar (via `CoreAudio`, funciona no T2)
- **Captura de tela**: tela inteira, janela, seleção e gravação
- **Controle de ventoinhas**: Auto / Silêncio / Médio / Booster (via helper SMC)
- **Modo Turbo / Game**: fecha apps pesados e prioriza desempenho
- **Métricas ao vivo**: temperatura, consumo (W) e RAM
- Abre junto com o Mac, mostra/esconde com `fn`

### 🔊 Amplificador de áudio para Bluetooth — *em desenvolvimento*

Muita gente tem esse problema: a **soundbar sai alta e limpa no cabo, mas fraquíssima no Bluetooth**, mesmo com o volume no máximo. Isso acontece porque **o amplificador da entrada Bluetooth da soundbar é fisicamente mais fraco** que o da entrada de cabo, e o volume no BT é escravo do Mac (*absolute volume*).

Estamos construindo um amplificador de sistema (`fn + x`) que processa o áudio de verdade — **ganho + limiter** via a API de *process tap* do Core Audio (macOS 14.4+) — para arrancar mais volume no Bluetooth **sem instalar driver nenhum**.

**Aviso honesto:** é *melhor esforço*. Como o gargalo é o hardware da soundbar, isso **não iguala o cabo** — dá um ganho real, especialmente em conteúdo com folga (voz, vídeo). O design completo está em [`docs/superpowers/specs`](docs/superpowers/specs/2026-07-18-amplificador-audio-bluetooth-design.md).

## Como compilar

Precisa do Xcode Command Line Tools (`xcode-select --install`).

```sh
git clone https://github.com/userresg17/virtual-touch-bar.git
cd virtual-touch-bar
./build.sh
open VirtualTouchBar.app
```

O `build.sh` compila e monta o `VirtualTouchBar.app`.

## Permissões

- **Acessibilidade** — para detectar o `fn` e enviar teclas ao sistema. O app pede na primeira abertura (Ajustes → Privacidade e Segurança → Acessibilidade).
- **Controle de ventoinhas** — instala uma vez um helper SMC (setuid root) pedindo sua senha de administrador.

## Compatibilidade

- macOS 11+ (Big Sur em diante). O amplificador de áudio exige **macOS 14.4+**.
- Testado em Macs Intel com chip T2. Deve funcionar em Apple Silicon.

## Contribuindo

Achou um bug ou tem a mesma dor com sua soundbar? Abra uma *issue* ou um *pull request*. Toda ajuda é bem-vinda.

## Licença

[MIT](LICENSE) — use, modifique e distribua à vontade.

---

### English summary

**Virtual Touch Bar** is a lightweight floating bar for macOS, for Macs **without a physical Touch Bar** (or T2 Macs where function keys broke). Press `fn` to show/hide it. Native Swift, no dependencies. Brings back brightness, keyboard backlight, volume, media keys, screenshots, fan control, a game/turbo mode and live metrics — by talking directly to system APIs.

An **audio amplifier for Bluetooth** (`fn + x`) is in progress: many soundbars play loud over cable but very quiet over Bluetooth because the BT input amp is physically weaker. It applies real gain + a limiter via Core Audio's process-tap API (macOS 14.4+), no driver install. Honest note: it's best-effort and **won't match the cable** — the bottleneck is the soundbar hardware — but it gives a real boost, especially on content with headroom.

Build: `./build.sh` then `open VirtualTouchBar.app`. Requires Accessibility permission. MIT licensed.
