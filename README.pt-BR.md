# notchJP

**Música, áudio por aplicativo, agentes de IA e ferramentas em um painel para macOS.**

Versão gratuita e de código aberto baseada no [Notchi, de Ruban](https://github.com/sk-ruban/notchi), sob GPL-3.0-only. Consulte o [README principal](README.md) para os detalhes de desenvolvimento e compatibilidade.

## Recursos

- Painel por monitor, com gavetas laterais conforme a posição da tela.
- Spotify com controles de reprodução e cores baseadas na capa do álbum.
- Mixer com volume, silêncio e saída por aplicativo. Lembra volumes e se estava ativado ao fechar.
- Acompanhamento de Claude Code e Codex, calendário, lembretes e ferramentas de foco.
- Controles opcionais de TVs LG webOS pela rede local, mediante pareamento.
- Controles de ares-condicionados compatíveis com TCL Home usando a própria conta TCL Home do usuário.
- Cenas, favoritos e temporizadores para aparelhos compatíveis.

## Compilar

Requer macOS 15+, Xcode 26.3+ e ferramentas de linha de comando. Validado em Apple Silicon; Intel ainda não foi validado.

```sh
git clone https://github.com/JoaoPauloNA/notchJP.git
cd notchJP
./scripts/build-local-app.sh
```

O aplicativo fica em `build/public/Build/Products/Release/notchJP.app`. O script não instala o app. Esta primeira publicação oferece o fonte, sem instalador público notarizado e sem canal público de atualização automática. O painel permite escolher português do Brasil ou inglês em Aparência → Idioma.

## Edições pública e privada

Este repositório contém a **edição pública**: sem atualização automática, endereço de VPS ou credencial de distribuição. A tela Sobre identifica a edição e oferece o link do GitHub para atualizar manualmente. O build e o CI verificam essa separação.

A **edição privada** do mantenedor continua em outro repositório, com atualização automática assinada. A versão pública não oferece opção para ativar esse canal.

## Integrações residenciais

As integrações LG e TCL são experimentais e não oficiais. Modelos, firmware, região e serviços do fabricante podem afetar o funcionamento. A TV exige pareamento na rede local; ligar por Wake-on-LAN depende do aparelho. O ar usa a conta TCL Home e os serviços de nuvem da TCL. Credenciais e configurações pessoais não acompanham o repositório.

Temporizadores exigem o app aberto e o Mac acordado. As ações no Atalhos do Mac controlam ar, TV LG e cenas; veja [como usar com Siri](docs/SIRI.md). HomeKit e ponte para iPhone/HomePod não estão incluídos. O mixer converte PCM Float32 mono/estéreo de 8–192 kHz; rotas Bluetooth/USB precisam de validação adicional em hardware.

Leia [privacidade](PRIVACY.md), [contribuição](CONTRIBUTING.md) e [licença](LICENSE). Não confunda os downloads do Notchi original com esta versão.

## Novidades da versão 1.4

Perfis de áudio salvos e renomeáveis, guia inicial reabrível, idioma do painel selecionável, ações de recuperação e exportação de diagnóstico sem contas, tokens, endereços ou nomes de aparelhos. Consultas de serviços foram separadas da detecção do mouse e os temporizadores residenciais só agendam trabalho enquanto houver uma ação pendente. Algumas mensagens das integrações continuam no idioma original.

A distribuição pública permanece somente pelo fonte no GitHub, sem instalador nesta etapa.
