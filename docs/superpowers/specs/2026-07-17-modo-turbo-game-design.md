# Modo Turbo / Game — Design

Data: 2026-07-17
Projeto: Virtual Touch Bar (MacBook Pro Intel i9-9880H, macOS)

## Contexto e realidade técnica

O pedido original foi "dar um boost no processador e na placa de vídeo, aumentando
o clock e o consumo quando estiver jogando".

**Não é possível fazer overclock por software no macOS.** A Apple tranca o
firmware; não existe controle de multiplicador de CPU nem de clock de GPU (o Intel
XTU também não funciona). O i9-9880H **já** faz Turbo Boost automático (até 4,8 GHz)
sozinho quando há carga.

O gargalo real desta máquina é **thermal throttling**: quando esquenta, o clock cai
pra se proteger. Logo, o "boost" de verdade não é forçar clock — é **remover o teto
térmico** pra o processador *sustentar* o turbo alto por mais tempo. O app já faz
parte disso com o modo Booster das ventoinhas.

Na bateria o i9 se limita de propósito (a bateria não entrega corrente pro turbo
cheio); por isso o Turbo só faz sentido pleno na tomada. Comportamento escolhido:
**avisar na bateria, mas deixar ligar**.

Sobre "limpar RAM": no macOS RAM livre é usada como cache (é bom). Forçar limpeza
(`purge`) joga cache útil fora e não faz a CPU render mais. O que ajuda de verdade é
**fechar apps pesados** que ocupam RAM e CPU à toa — e só isso é feito, com
confirmação.

## Objetivo

Um **Modo Turbo / Game**: um toque liga tudo que maximiza o desempenho sustentado
real desta máquina, e desliga revertendo sozinho. Mais um mostrador ao vivo pra o
usuário ver o boost trabalhando.

## Escopo aprovado

1. Ventoinhas no máximo + anti-throttling (`caffeinate`).
2. Fechar apps pesados marcados pelo usuário (com confirmação).
3. Mostrador ao vivo na barra (temperatura, watts, pressão de RAM).
4. Na bateria: avisar mas permitir ligar.
5. Permissões confirmadas **uma única vez**.

Fora de escopo (YAGNI): overclock real, leitura de GHz em tempo real (exigiria
`powermetrics` root e pesado — dá pra adicionar depois se desejado), reabrir apps
fechados, controle de GPU dedicada.

## Arquitetura

Novo arquivo **`turbo.swift`** (mantém o `main.swift` enxuto). O `build.sh` passa a
compilar `*.swift` em vez de só `main.swift`. Nenhum comportamento existente muda.

### Componentes

**`SystemMetrics`** — leituras, sem root.
- Temperatura da CPU e watts do pacote via SMC (leitura de SMC não exige root — o
  mesmo caminho do comando `status` do helper). Como as chaves variam por modelo,
  o componente **sonda** um conjunto de candidatas na inicialização e só usa/mostra
  as que respondem:
  - Temperatura: `TC0P`, `TCXC`, `TC0E`, `TC0D` (primeira que ler).
  - Watts do pacote: `PCPC`, `PC0C`, `PSTR` (primeira que ler).
- Pressão de RAM via `host_statistics64` (`vm_statistics64`): calcula % de uso e
  mapeia pra nível 🟢 tranquilo / 🟡 apertado / 🔴 sob pressão (usando páginas
  wired+compressed vs. total, alinhado à métrica de "memory pressure").
- Um `Timer` atualiza a cada ~2s, ativo **apenas** quando a barra está visível ou o
  Turbo está ligado (economia de bateria).
- A leitura de SMC em Swift replica o mínimo do `smcfan.c` (abrir `AppleSMC`,
  `key_info` + `read_bytes`), sem escrever nada.

**`PowerSource`** — detecta tomada vs. bateria via IOKit (`IOPSCopyPowerSourcesInfo`
/ `IOPSGetProvidingPowerSourceType`). Falha na leitura → assume tomada (não bloqueia).

**`HeavyApps`** — gerencia a lista de apps que o Turbo fecha.
- Guarda bundle IDs em `UserDefaults` (`turboHeavyApps`).
- Submenu "Apps pra fechar no Turbo" lista os apps abertos no momento (só apps
  comuns: `NSRunningApplication` com `activationPolicy == .regular`, excluindo o
  próprio Touch Bar e o Finder). Marcar/desmarcar adiciona/remove da lista.
- Ao ligar o Turbo: cruza a lista com o que está aberto → mostra um alerta de
  confirmação listando os nomes ("Fechar: Google Chrome, Discord?") → em OK, chama
  `NSRunningApplication.terminate()` (educado; nunca `forceTerminate`). App com
  trabalho não salvo mostra o próprio diálogo do macOS — não forçamos.

**`TurboMode`** — orquestrador (singleton, estado em `UserDefaults` `turboOn`).
- `ligar()`:
  1. Se primeiro uso → roda o fluxo de permissões único (ver abaixo).
  2. Se na bateria → alerta "ganho limitado na bateria" com Ligar/Cancelar.
  3. `FanControl.shared.set(.booster)`.
  4. Inicia `caffeinate -di` como processo filho; guarda o `Process` pra matar
     depois.
  5. Fecha os apps pesados marcados (com confirmação).
  6. Atualiza visual do botão (aceso/vermelho) e o item de menu.
- `desligar()`:
  1. `FanControl.shared.set(.auto)`.
  2. Mata o `caffeinate`.
  3. Atualiza visual. (Apps fechados não reabrem.)
- Estado inicial no launch: **desligado** (não surpreende o usuário ligando as
  ventoinhas ao abrir). `applicationWillTerminate` já devolve as ventoinhas; passa
  também a matar o `caffeinate`.

### Permissões — confirmação única

Fluxo disparado no **primeiro uso do Turbo** (flag `turboSetupDone` em UserDefaults):
1. **Acessibilidade** — já solicitada no launch do app; o macOS lembra pra sempre.
2. **Senha de admin** — instala o helper `smcfan` como setuid root **uma vez**
   (mecanismo já existente); reutilizado sem pedir senha de novo. O Turbo usa o
   mesmo helper.
3. **Fechar apps** — usa `NSRunningApplication.terminate()`, que **não** dispara o
   prompt de Automação por app (evitamos AppleScript de propósito).

Um único diálogo explica o que vai acontecer e dispara o que faltar. Depois marca
`turboSetupDone = true` e nunca mais pergunta.

### UI (mudanças no `main.swift`)

- Novo botão **⚡ Turbo** na barra (símbolo `bolt.fill`); aceso/vermelho quando
  ativo, cinza quando não.
- Item de menu "Modo Turbo / Game" com estado (✓) + submenu "Apps pra fechar no
  Turbo".
- **Mostrador** na barra: uma view compacta com `🌡️ 78° · ⚡ 42W · 🟢`, atualizada
  pelo `SystemMetrics`. Métricas que não lerem no modelo somem (não quebram).

## Fluxo de dados

`Timer (2s)` → `SystemMetrics.sample()` lê SMC + vm_stat → publica valores →
`AppDelegate` atualiza o texto do mostrador. Independente do Turbo, que só orquestra
fans/caffeinate/apps.

## Tratamento de erros

- Chave SMC ausente no modelo → métrica omitida do mostrador.
- `caffeinate` não inicia → `NSSound.beep()` e segue (fans e resto continuam).
- `terminate()` de um app → se o app pedir pra salvar, o macOS cuida; não forçamos.
- Leitura de fonte de energia falha → assume tomada.
- Instalação do helper falha (senha errada/cancelada) → bip, Turbo não liga fans mas
  não trava o app.

## Testes / verificação

Sem testes unitários viáveis (UI + SMC + processos do sistema). Verificação manual
após build:
- Ligar Turbo → `smcfan status` mostra ventoinhas em modo forçado no máximo.
- `pgrep caffeinate` retorna PID enquanto ligado; some ao desligar.
- Mostrador atualiza temp/watts/RAM a cada ~2s.
- Marcar um app leve de teste na lista e confirmar que fecha educadamente.
- Na bateria: aparece o aviso mas deixa ligar.
- Desligar / sair do app → ventoinhas voltam pro Auto, `caffeinate` morto.

## Mudanças no build

`build.sh` linha 39: `swiftc -O -framework Cocoa -framework ServiceManagement *.swift`
(compila `main.swift` + `turbo.swift`). O helper `smcfan.c` segue igual.
