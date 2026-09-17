# Apps candidatos para revisão

Pesquisa em 17/09/2026. Estas 26 sugestões foram aprovadas e adicionadas ao catálogo na versão 1.5.9. Nenhum desses apps foi instalado. Prioridade é uma recomendação editorial, não um ranking de downloads.

Os identificadores abaixo foram consultados online com `winget search --id ID --exact --source winget` e `choco search ID --exact --limit-output --source https://community.chocolatey.org/api/v2/`. A disponibilidade foi confirmada nos dois gerenciadores; instalação e equivalência de parâmetros ainda não foram testadas. Versões podem diferir entre fontes.

| App | Prioridade sugerida | Utilidade | ID WinGet | Pacote Chocolatey |
|---|---|---|---|---|
| LibreOffice | Alta | Documentos, planilhas e apresentações; opção de suíte de escritório. | `TheDocumentFoundation.LibreOffice` | [libreoffice-fresh](https://community.chocolatey.org/packages/libreoffice-fresh) |
| ONLYOFFICE | Alta | Alternativa de suíte de escritório; oferecer como escolha junto ao LibreOffice. | `ONLYOFFICE.DesktopEditors` | [onlyoffice](https://community.chocolatey.org/packages/onlyoffice) |
| Thunderbird | Alta | Cliente de e-mail para várias contas. | `Mozilla.Thunderbird` | [thunderbird](https://community.chocolatey.org/packages/thunderbird) |
| ShareX | Alta | Capturas de tela, gravação e anotações; alternativa ao Greenshot. | `ShareX.ShareX` | [sharex](https://community.chocolatey.org/packages/sharex) |
| PDF24 Creator | Alta | Juntar, dividir, converter e imprimir PDFs. | `geeksoftwareGmbH.PDF24Creator` | [pdf24](https://community.chocolatey.org/packages/pdf24) |
| KeePassXC | Alta | Cofre de senhas local; alternativa ao Bitwarden. | `KeePassXCTeam.KeePassXC` | [keepassxc](https://community.chocolatey.org/packages/keepassxc) |
| LocalSend | Alta | Transferir arquivos entre PC e celular na rede local. | `LocalSend.LocalSend` | [localsend](https://community.chocolatey.org/packages/localsend) |
| Syncthing | Opcional | Sincronizar pastas entre dispositivos; exige configurar os pares e pastas. | `Syncthing.Syncthing` | [syncthing](https://community.chocolatey.org/packages/syncthing) |
| Spotify | Opcional | Música e podcasts; conta e plano conforme o serviço. | `Spotify.Spotify` | [spotify](https://community.chocolatey.org/packages/spotify) |
| Zoom | Opcional | Reuniões por vídeo. | `Zoom.Zoom` | [zoom](https://community.chocolatey.org/packages/zoom) |
| Microsoft Teams | Opcional | Reuniões e colaboração; usar Teams atual, não Teams Classic. | `Microsoft.Teams` | [microsoft-teams-new-bootstrapper](https://community.chocolatey.org/packages/microsoft-teams-new-bootstrapper) |
| Slack | Opcional | Comunicação de equipes. | `SlackTechnologies.Slack` | [slack](https://community.chocolatey.org/packages/slack) |
| Obsidian | Alta | Notas e organização pessoal em Markdown. | `Obsidian.Obsidian` | [obsidian](https://community.chocolatey.org/packages/obsidian) |
| Joplin | Opcional | Notas e cadernos; alternativa ao Obsidian. | `Joplin.Joplin` | [joplin](https://community.chocolatey.org/packages/joplin) |
| Audacity | Alta | Gravação e edição de áudio. | `Audacity.Audacity` | [audacity](https://community.chocolatey.org/packages/audacity) |
| Blender | Por perfil | Modelagem, animação e criação 3D. | `BlenderFoundation.Blender` | [blender](https://community.chocolatey.org/packages/blender) |
| Krita | Por perfil | Desenho e pintura digital. | `KDE.Krita` | [krita](https://community.chocolatey.org/packages/krita) |
| Paint.NET | Alta | Edição de imagens para tarefas do dia a dia. | `dotPDN.PaintDotNet` | [paint.net](https://community.chocolatey.org/packages/paint.net) |
| WinSCP | Por perfil | Transferência de arquivos por SFTP/SCP e outros protocolos. | `WinSCP.WinSCP` | [winscp](https://community.chocolatey.org/packages/winscp) |
| PuTTY | Por perfil | Terminal SSH e acesso serial. | `PuTTY.PuTTY` | [putty](https://community.chocolatey.org/packages/putty) |
| Wireshark | Por perfil | Análise de tráfego de rede; recursos de captura podem exigir componentes adicionais. | `WiresharkFoundation.Wireshark` | [wireshark](https://community.chocolatey.org/packages/wireshark) |
| VSCodium | Por perfil | Editor baseado no código aberto do VS Code; alternativa, sem seleção dupla automática. | `VSCodium.VSCodium` | [vscodium](https://community.chocolatey.org/packages/vscodium) |
| Heroic Games Launcher | Por perfil | Launcher alternativo para bibliotecas de jogos. | `HeroicGamesLauncher.HeroicGamesLauncher` | [heroic-games-launcher](https://community.chocolatey.org/packages/heroic-games-launcher) |
| Bambu Studio | Por perfil | Preparação de modelos para impressão 3D. | `Bambulab.Bambustudio` | [bambustudio](https://community.chocolatey.org/packages/bambustudio) |
| FreeCAD | Por perfil | Projeto CAD paramétrico. | `FreeCAD.FreeCAD` | [freecad](https://community.chocolatey.org/packages/freecad) |
| PeaZip | Opcional | Gerenciamento de arquivos compactados; alternativa ao 7-Zip. | `Giorgiotani.Peazip` | [peazip](https://community.chocolatey.org/packages/peazip) |

## Critérios para o Upkeep

- WinGet como primeira opção para apps de desktop; Chocolatey como alternativa explícita, preservando o gerenciador e o escopo usados na instalação. Não instalar o mesmo app por ambos automaticamente.
- Oferecer alternativas sem marcar todas: LibreOffice/ONLYOFFICE, Bitwarden/KeePassXC, Greenshot/ShareX, VS Code/VSCodium, 7-Zip/PeaZip.
- Manter ferramentas específicas em perfis: desenvolvimento, criação, jogos e impressão 3D.
- Scoop é uma opção futura para ferramentas portáteis e instalações por usuário; precisa de integração própria para seleção, inventário e atualização. Não é uma integração nova já implementada.
- Microsoft Store já pode ser consultada pelo WinGet; selecionar a fonte explicitamente quando o pacote for da Store.

O ranking histórico do Chocolatey inclui runtimes, extensões e programas legados. Foi usado como referência de popularidade, sem importar automaticamente seu conteúdo.

Fontes: [catálogo Chocolatey por downloads](https://community.chocolatey.org/packages?sortOrder=package-download-count), [repositório de manifestos WinGet](https://github.com/microsoft/winget-pkgs), [fontes do WinGet](https://learn.microsoft.com/en-us/windows/package-manager/winget/source), [Scoop](https://github.com/ScoopInstaller/Scoop).

## Catálogo anterior à aprovação (69)

Os mapeamentos nesta seção são os existentes no Upkeep; esta rodada validou os 26 candidatos acima. Nenhuma mudança de preset foi feita.

- **Communications:** Telegram Desktop, Signal, WhatsApp Desktop.
- **Development:** Git, GitHub CLI, GitHub Desktop, Visual Studio Code, Python 3.13, Node.js, Windows Subsystem for Linux, Docker Desktop, PowerShell, Windows Terminal, CMake, uv, Ollama.
- **Essentials:** 7-Zip, Bitwarden, UniGetUI, ImageGlass, Notepad++, Microsoft PowerToys, Everything, gsudo, Greenshot, TeraCopy, WizTree, Sumatra PDF, EarTrumpet, AutoHotkey.
- **Gaming:** Steam, EA Desktop, Epic Games Launcher, Discord, Sunshine.
- **Internet:** Google Chrome, Brave, Firefox, LibreWolf, qBittorrent, JDownloader, Helium.
- **Media:** VLC Media Player, FFmpeg, HandBrake, MKVToolNix, OBS Studio, K-Lite Codec Pack Standard, yt-dlp, GIMP, Inkscape, Subtitle Edit.
- **Productivity:** Zotero, calibre, draw.io, Pandoc.
- **Remote Access:** RustDesk, Parsec, AnyDesk.
- **Utilities:** CrystalDiskInfo, Rufus, Ventoy, HWiNFO, CPU-Z, Bulk Crap Uninstaller, Tailscale, NVCleanstall, Snappy Driver Installer Origin, Raspberry Pi Imager.

Comparação atualizada dos 95 apps com o WinUtil: [lista completa](WINUTIL-CATALOG-COMPARISON.md).
