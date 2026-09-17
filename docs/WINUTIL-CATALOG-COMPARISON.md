# Comparação completa: Upkeep e WinUtil

Consulta em 17/09/2026. Catálogo do WinUtil fixado no commit `9ac45d6c31e899d5e3df2d9c81c30d84894b5dc8` para tornar a comparação reproduzível. [Fonte original](https://github.com/ChrisTitusTech/winutil/blob/9ac45d6c31e899d5e3df2d9c81c30d84894b5dc8/config/applications.json).

- Upkeep: **95 apps** (69 preservados + 26 sugestões aprovadas).
- WinUtil: **233 entradas**.
- Em ambos, pelo mesmo ID WinGet: **75**.
- Só no Upkeep: **20**.
- No WinUtil, ainda fora do Upkeep: **158**.

A comparação usa IDs de pacotes, ignorando maiúsculas/minúsculas; canais e versões diferentes permanecem separados. Node.js e Node.js LTS, por exemplo, não são a mesma entrada. A presença no WinUtil não garante disponibilidade atual do pacote nem equivalência do fallback Chocolatey.

## Alterações aplicadas

- Adicionadas as 26 sugestões da revisão anterior, com descrições em português e inglês. Nenhum preset foi ampliado e nenhum desses apps foi instalado.
- UniGetUI: corrigido o ID removido `MartiCliment.UniGetUI` para `Devolutions.UniGetUI`, confirmado na fonte WinGet.
- RustDesk: preservado no catálogo por Chocolatey (`rustdesk`), removido o ID WinGet indisponível. [Registro da remoção no WinGet](https://github.com/microsoft/winget-pkgs/issues/352094), [pacote Chocolatey](https://community.chocolatey.org/packages/rustdesk).
- Validada a disponibilidade das 95 opções: 93 na fonte winget, WhatsApp na Microsoft Store e RustDesk no Chocolatey. Não foram executadas instalações de validação.

## Próximas adições recomendadas para revisão

| Apps | Por que considerar |
|---|---|
| NAPS2 | Digitalização de documentos; complementa os editores de PDF. |
| Moonlight | Cliente de streaming para usar com Sunshine, que já está no catálogo. |
| Playnite | Organiza bibliotecas de jogos de vários launchers. |
| Autoruns, Process Explorer, Process Monitor | Diagnóstico avançado do Windows, separado das opções para iniciantes. |
| Google Drive, OneDrive | Sincronização com serviços de nuvem, escolhidos conforme a conta usada. |
| Bruno, JetBrains Toolbox | Ferramentas para desenvolvimento e testes de APIs. |
| Node.js LTS | Canal alternativo ao Node.js atual; evitar selecionar os dois por padrão. |
| .NET Desktop Runtime 10 | Dependência opcional para apps que exigem esse runtime. |

Os IDs dessas sugestões foram consultados na fonte WinGet. Elas ainda não foram adicionadas.

## Pontos do WinUtil que exigem revisão

- A entrada Process Monitor aponta para `procexp` no Chocolatey, o mesmo pacote usado para Process Explorer. Não copiar esse fallback.
- A entrada mpc-qt aponta para `mediainfo` no Chocolatey. São aplicativos diferentes.
- TeamViewer aponta para `teamviewer9` no Chocolatey; validar o pacote atual antes de importar.
- Há canais diferentes de Python, Node.js, Firefox e runtimes. Não tratar toda diferença como um app faltando.

## Catálogo completo do Upkeep

| App | Categoria | ID WinGet | Chocolatey | WinUtil | Mudança |
|---|---|---|---|---|---|
| Microsoft Teams | Communications | `Microsoft.Teams` | `microsoft-teams-new-bootstrapper` | Sim | Adicionado agora |
| Signal | Communications | `OpenWhisperSystems.Signal` | `signal` | Sim | Preservado |
| Slack | Communications | `SlackTechnologies.Slack` | `slack` | Sim | Adicionado agora |
| Telegram Desktop | Communications | `Telegram.TelegramDesktop` | `telegram` | Sim | Preservado |
| Thunderbird | Communications | `Mozilla.Thunderbird` | `thunderbird` | Sim | Adicionado agora |
| WhatsApp Desktop | Communications | `msstore:9NKSQGP7F2NH` | `na` | Sim | Preservado |
| Zoom | Communications | `Zoom.Zoom` | `zoom` | Sim | Adicionado agora |
| CMake | Development | `Kitware.CMake` | `cmake` | Sim | Preservado |
| Docker Desktop | Development | `Docker.DockerDesktop` | `docker-desktop` | Sim | Preservado |
| Git | Development | `Git.Git` | `git` | Sim | Preservado |
| GitHub CLI | Development | `GitHub.cli` | `gh` | Sim | Preservado |
| GitHub Desktop | Development | `GitHub.GitHubDesktop` | `github-desktop` | Sim | Preservado |
| Node.js | Development | `OpenJS.NodeJS` | `nodejs` | Sim | Preservado |
| Ollama | Development | `Ollama.Ollama` | `na` | Não | Preservado |
| PowerShell | Development | `Microsoft.PowerShell` | `powershell-core` | Sim | Preservado |
| PuTTY | Development | `PuTTY.PuTTY` | `putty` | Sim | Adicionado agora |
| Python 3.13 | Development | `Python.Python.3.13` | `python313` | Não | Preservado |
| uv | Development | `astral-sh.uv` | `na` | Sim | Preservado |
| Visual Studio Code | Development | `Microsoft.VisualStudioCode` | `vscode` | Sim | Preservado |
| VSCodium | Development | `VSCodium.VSCodium` | `vscodium` | Sim | Adicionado agora |
| Windows Subsystem for Linux | Development | `Microsoft.WSL` | `na` | Não | Preservado |
| Windows Terminal | Development | `Microsoft.WindowsTerminal` | `microsoft-windows-terminal` | Sim | Preservado |
| WinSCP | Development | `WinSCP.WinSCP` | `winscp` | Sim | Adicionado agora |
| Wireshark | Development | `WiresharkFoundation.Wireshark` | `wireshark` | Sim | Adicionado agora |
| 7-Zip | Essentials | `7zip.7zip` | `7zip` | Sim | Preservado |
| AutoHotkey | Essentials | `AutoHotkey.AutoHotkey` | `autohotkey` | Sim | Preservado |
| Bitwarden | Essentials | `Bitwarden.Bitwarden` | `bitwarden` | Sim | Preservado |
| EarTrumpet | Essentials | `File-New-Project.EarTrumpet` | `eartrumpet` | Sim | Preservado |
| Everything | Essentials | `voidtools.Everything` | `everything` | Sim | Preservado |
| Greenshot | Essentials | `Greenshot.Greenshot` | `greenshot` | Não | Preservado |
| gsudo | Essentials | `gerardog.gsudo` | `gsudo` | Sim | Preservado |
| ImageGlass | Essentials | `DuongDieuPhap.ImageGlass` | `imageglass` | Sim | Preservado |
| KeePassXC | Essentials | `KeePassXCTeam.KeePassXC` | `keepassxc` | Sim | Adicionado agora |
| Microsoft PowerToys | Essentials | `Microsoft.PowerToys` | `powertoys` | Sim | Preservado |
| Notepad++ | Essentials | `Notepad++.Notepad++` | `notepadplusplus` | Sim | Preservado |
| Sumatra PDF | Essentials | `SumatraPDF.SumatraPDF` | `sumatrapdf` | Sim | Preservado |
| TeraCopy | Essentials | `CodeSector.TeraCopy` | `teracopy` | Não | Preservado |
| UniGetUI | Essentials | `Devolutions.UniGetUI` | `wingetui` | Sim | Preservado |
| WizTree | Essentials | `AntibodySoftware.WizTree` | `wiztree` | Sim | Preservado |
| Discord | Gaming | `Discord.Discord` | `discord` | Sim | Preservado |
| EA Desktop | Gaming | `ElectronicArts.EADesktop` | `na` | Sim | Preservado |
| Epic Games Launcher | Gaming | `EpicGames.EpicGamesLauncher` | `epicgameslauncher` | Sim | Preservado |
| Heroic Games Launcher | Gaming | `HeroicGamesLauncher.HeroicGamesLauncher` | `heroic-games-launcher` | Sim | Adicionado agora |
| Steam | Gaming | `Valve.Steam` | `steam-client` | Sim | Preservado |
| Sunshine | Gaming | `LizardByte.Sunshine` | `sunshine` | Sim | Preservado |
| Brave | Internet | `Brave.Brave` | `brave` | Sim | Preservado |
| Firefox | Internet | `Mozilla.Firefox` | `firefox` | Sim | Preservado |
| Google Chrome | Internet | `Google.Chrome` | `googlechrome` | Sim | Preservado |
| Helium | Internet | `ImputNet.Helium` | `na` | Sim | Preservado |
| JDownloader | Internet | `AppWork.JDownloader` | `jdownloader2` | Não | Preservado |
| LibreWolf | Internet | `LibreWolf.LibreWolf` | `librewolf` | Sim | Preservado |
| qBittorrent | Internet | `qBittorrent.qBittorrent` | `qbittorrent` | Sim | Preservado |
| Audacity | Media | `Audacity.Audacity` | `audacity` | Sim | Adicionado agora |
| Bambu Studio | Media | `Bambulab.Bambustudio` | `bambustudio` | Não | Adicionado agora |
| Blender | Media | `BlenderFoundation.Blender` | `blender` | Sim | Adicionado agora |
| FFmpeg | Media | `Gyan.FFmpeg` | `ffmpeg` | Não | Preservado |
| FreeCAD | Media | `FreeCAD.FreeCAD` | `freecad` | Não | Adicionado agora |
| GIMP | Media | `GIMP.GIMP.3` | `na` | Sim | Preservado |
| HandBrake | Media | `HandBrake.HandBrake` | `handbrake` | Sim | Preservado |
| Inkscape | Media | `Inkscape.Inkscape` | `na` | Não | Preservado |
| K-Lite Codec Pack Standard | Media | `CodecGuide.K-LiteCodecPack.Standard` | `k-litecodecpack-standard` | Sim | Preservado |
| Krita | Media | `KDE.Krita` | `krita` | Não | Adicionado agora |
| MKVToolNix | Media | `MoritzBunkus.MKVToolNix` | `mkvtoolnix` | Não | Preservado |
| OBS Studio | Media | `OBSProject.OBSStudio` | `obs-studio` | Sim | Preservado |
| Paint.NET | Media | `dotPDN.PaintDotNet` | `paint.net` | Sim | Adicionado agora |
| Spotify | Media | `Spotify.Spotify` | `spotify` | Não | Adicionado agora |
| Subtitle Edit | Media | `Nikse.SubtitleEdit` | `na` | Não | Preservado |
| VLC Media Player | Media | `VideoLAN.VLC` | `vlc` | Sim | Preservado |
| yt-dlp | Media | `yt-dlp.yt-dlp` | `yt-dlp` | Não | Preservado |
| calibre | Productivity | `calibre.calibre` | `na` | Sim | Preservado |
| draw.io | Productivity | `JGraph.Draw` | `na` | Não | Preservado |
| Joplin | Productivity | `Joplin.Joplin` | `joplin` | Sim | Adicionado agora |
| LibreOffice | Productivity | `TheDocumentFoundation.LibreOffice` | `libreoffice-fresh` | Sim | Adicionado agora |
| Obsidian | Productivity | `Obsidian.Obsidian` | `obsidian` | Sim | Adicionado agora |
| ONLYOFFICE | Productivity | `ONLYOFFICE.DesktopEditors` | `onlyoffice` | Sim | Adicionado agora |
| Pandoc | Productivity | `JohnMacFarlane.Pandoc` | `na` | Não | Preservado |
| PDF24 Creator | Productivity | `geeksoftwareGmbH.PDF24Creator` | `pdf24` | Sim | Adicionado agora |
| Zotero | Productivity | `DigitalScholar.Zotero` | `na` | Sim | Preservado |
| AnyDesk | Remote Access | `AnyDesk.AnyDesk` | `na` | Sim | Preservado |
| Parsec | Remote Access | `Parsec.Parsec` | `parsec` | Sim | Preservado |
| RustDesk | Remote Access | `na` | `rustdesk` | Não | Preservado |
| Bulk Crap Uninstaller | Utilities | `Klocman.BulkCrapUninstaller` | `bulk-crap-uninstaller` | Sim | Preservado |
| CPU-Z | Utilities | `CPUID.CPU-Z` | `cpu-z` | Sim | Preservado |
| CrystalDiskInfo | Utilities | `CrystalDewWorld.CrystalDiskInfo` | `crystaldiskinfo` | Sim | Preservado |
| HWiNFO | Utilities | `REALiX.HWiNFO` | `hwinfo` | Sim | Preservado |
| LocalSend | Utilities | `LocalSend.LocalSend` | `localsend` | Sim | Adicionado agora |
| NVCleanstall | Utilities | `TechPowerUp.NVCleanstall` | `na` | Sim | Preservado |
| PeaZip | Utilities | `Giorgiotani.Peazip` | `peazip` | Sim | Adicionado agora |
| Raspberry Pi Imager | Utilities | `RaspberryPiFoundation.RaspberryPiImager` | `na` | Não | Preservado |
| Rufus | Utilities | `Rufus.Rufus` | `rufus` | Sim | Preservado |
| ShareX | Utilities | `ShareX.ShareX` | `sharex` | Sim | Adicionado agora |
| Snappy Driver Installer Origin | Utilities | `GlennDelahoy.SnappyDriverInstallerOrigin` | `sdio` | Sim | Preservado |
| Syncthing | Utilities | `Syncthing.Syncthing` | `syncthing` | Não | Adicionado agora |
| Tailscale | Utilities | `Tailscale.Tailscale` | `tailscale` | Sim | Preservado |
| Ventoy | Utilities | `Ventoy.Ventoy` | `ventoy` | Sim | Preservado |

## Todas as entradas do WinUtil ainda fora do Upkeep

A lista abaixo é uma comparação, não uma recomendação de instalar tudo. IDs e categorias nesta tabela são os declarados pelo WinUtil; apenas as sugestões priorizadas acima foram verificadas individualmente nesta rodada.

| App | Categoria WinUtil | ID WinGet |
|---|---|---|
| Chromium | Browsers | `Hibbiki.Chromium` |
| Edge | Browsers | `Microsoft.Edge` |
| Firefox ESR | Browsers | `Mozilla.Firefox.ESR` |
| Floorp | Browsers | `Ablaze.Floorp` |
| Mullvad Browser | Browsers | `MullvadVPN.MullvadBrowser` |
| Tor Browser | Browsers | `TorProject.TorBrowser` |
| Ungoogled Chromium | Browsers | `eloston.ungoogled-chromium` |
| Vivaldi | Browsers | `Vivaldi.Vivaldi` |
| Waterfox | Browsers | `Waterfox.Waterfox` |
| Zen Browser | Browsers | `Zen-Team.Zen-Browser` |
| Betterbird | Communications | `Betterbird.Betterbird` |
| Chatterino | Communications | `ChatterinoTeam.Chatterino` |
| Dorion | Communications | `SpikeHD.Dorion` |
| Element | Communications | `Element.Element` |
| Proton Mail | Communications | `Proton.ProtonMail` |
| QTox | Communications | `Tox.qTox` |
| TeamSpeak 3 | Communications | `TeamSpeakSystems.TeamSpeakClient` |
| TeamSpeak 6 | Communications | `TeamSpeakSystems.TeamSpeakClient.Beta.6` |
| Vesktop | Communications | `Vencord.Vesktop` |
| Viber | Communications | `Rakuten.Viber` |
| Amazon Corretto 21 (LTS) | Development | `Amazon.Corretto.21.JDK` |
| Amazon Corretto 25 (LTS) | Development | `Amazon.Corretto.25.JDK` |
| Amazon Corretto 8 (LTS) | Development | `Amazon.Corretto.8.JDK` |
| Bruno | Development | `Bruno.Bruno` |
| ChatGPT Desktop | Development | `msstore:9NT1R1C2HH7J` |
| Claude Code | Development | `Anthropic.ClaudeCode` |
| Claude Desktop | Development | `Anthropic.Claude` |
| Codex | Development | `OpenAI.Codex` |
| Cursor | Development | `Anysphere.Cursor` |
| Fast Node Manager | Development | `Schniz.fnm` |
| Git Extensions | Development | `GitExtensionsTeam.GitExtensions` |
| Go | Development | `GoLang.Go` |
| Jetbrains Toolbox | Development | `JetBrains.Toolbox` |
| Lazygit | Development | `JesseDuffield.lazygit` |
| Lua | Development | `rjpcomputing.luaforwindows` |
| Neovim | Development | `Neovim.Neovim` |
| NodeJS LTS | Development | `OpenJS.NodeJS.LTS` |
| Oh My Posh (Prompt) | Development | `JanDeDobbeleer.OhMyPosh` |
| pnpm | Development | `pnpm.pnpm` |
| Postman | Development | `Postman.Postman` |
| Python3 | Development | `Python.Python.3.14` |
| Ruby | Development | `RubyInstallerTeam.Ruby.4.0` |
| Rust | Development | `Rustlang.Rust.MSVC` |
| Starship (Shell Prompt) | Development | `Starship.Starship` |
| Sublime Text | Development | `SublimeHQ.SublimeText.4` |
| System Informer | Development | `WinsiderSS.SystemInformer` |
| Unity Game Engine | Development | `Unity.UnityHub` |
| Vagrant | Development | `Hashicorp.Vagrant` |
| Visual Studio 2022 | Development | `Microsoft.VisualStudio.2022.Community` |
| Visual Studio 2026 | Development | `Microsoft.VisualStudio.Community` |
| Yarn | Development | `Yarn.Yarn` |
| Zed | Development | `ZedIndustries.Zed` |
| Adobe Acrobat Reader | Document | `Adobe.Acrobat.Reader.64-bit` |
| Foxit PDF Reader | Document | `Foxit.FoxitReader` |
| NAPS2 (Scanner) | Document | `Cyanfish.NAPS2` |
| Okular | Document | `KDE.Okular` |
| PDF-XChange Editor | Document | `TrackerSoftware.PDF-XChangeEditor` |
| PDFgear | Document | `PDFgear.PDFgear` |
| PDFsam Basic | Document | `PDFsam.PDFsam` |
| QOwnNotes | Document | `pbek.QOwnNotes` |
| Simplenote | Document | `Automattic.Simplenote` |
| Xournal++ | Document | `Xournal++.Xournal++` |
| Battle.net | Games | `Blizzard.BattleNet` |
| Cemu | Games | `Cemu.Cemu` |
| EmulationStation Desktop Edition | Games | `ES-DE.EmulationStation-DE` |
| GeForce NOW | Games | `Nvidia.GeForceNow` |
| GOG Galaxy | Games | `GOG.Galaxy` |
| Itch.io | Games | `ItchIo.Itch` |
| Modrinth App | Games | `Modrinth.ModrinthApp` |
| Overwolf | Games | `Overwolf.CurseForge` |
| Playnite | Games | `Playnite.Playnite` |
| Prism Launcher | Games | `PrismLauncher.PrismLauncher` |
| Roblox | Games | `Roblox.Roblox` |
| Ubisoft Connect | Games | `Ubisoft.Connect` |
| Virtual Desktop Streamer | Games | `VirtualDesktop.Streamer` |
| .NET Desktop Runtime 10 | Microsoft Tools | `Microsoft.DotNet.DesktopRuntime.10` |
| .NET Desktop Runtime 6 | Microsoft Tools | `Microsoft.DotNet.DesktopRuntime.6` |
| .NET Desktop Runtime 8 | Microsoft Tools | `Microsoft.DotNet.DesktopRuntime.8` |
| .NET Desktop Runtime 9 | Microsoft Tools | `Microsoft.DotNet.DesktopRuntime.9` |
| Autoruns | Microsoft Tools | `Microsoft.Sysinternals.Autoruns` |
| DISMTools | Microsoft Tools | `CodingWondersSoftware.DISMTools.Stable` |
| NTLite | Microsoft Tools | `Nlitesoft.NTLite` |
| NuGet | Microsoft Tools | `Microsoft.NuGet` |
| OneDrive | Microsoft Tools | `Microsoft.OneDrive` |
| Process Explorer | Microsoft Tools | `Microsoft.Sysinternals.ProcessExplorer` |
| Process Monitor | Microsoft Tools | `Microsoft.Sysinternals.ProcessMonitor` |
| RDCMan | Microsoft Tools | `Microsoft.Sysinternals.RDCMan` |
| TCPView | Microsoft Tools | `Microsoft.Sysinternals.TCPView` |
| Visual C++ 2015-2022 32-bit | Microsoft Tools | `Microsoft.VCRedist.2015+.x86` |
| Visual C++ 2015-2022 64-bit | Microsoft Tools | `Microsoft.VCRedist.2015+.x64` |
| AIMP (Music Player) | Multimedia Tools | `AIMP.AIMP` |
| File Converter | Multimedia Tools | `AdrienAllard.FileConverter` |
| foobar2000 (Music Player) | Multimedia Tools | `PeterPawlowski.foobar2000` |
| IrfanView | Multimedia Tools | `IrfanSkiljan.IrfanView` |
| iTunes | Multimedia Tools | `Apple.iTunes` |
| Media Player Classic - Home Cinema | Multimedia Tools | `clsid2.mpc-hc` |
| mpc-qt | Multimedia Tools | `mpc-qt.mpc-qt` |
| mpv | Multimedia Tools | `shinchiro.mpv` |
| nomacs | Multimedia Tools | `nomacs.nomacs` |
| Advanced IP Scanner | Pro Tools | `Famatech.AdvancedIPScanner` |
| Angry IP Scanner | Pro Tools | `angryziber.AngryIPScanner` |
| Cinebench R23 | Pro Tools | `Maxon.CinebenchR23` |
| Display Driver Uninstaller | Pro Tools | `Wagnardsoft.DisplayDriverUninstaller` |
| GPU-Z | Pro Tools | `TechPowerUp.GPU-Z` |
| HWMonitor | Pro Tools | `CPUID.HWMonitor` |
| Mullvad VPN | Pro Tools | `MullvadVPN.MullvadVPN` |
| Nmap | Pro Tools | `Insecure.Nmap` |
| OpenVPN Connect | Pro Tools | `OpenVPNTechnologies.OpenVPNConnect` |
| Proton VPN | Pro Tools | `Proton.ProtonVPN` |
| Simplewall | Pro Tools | `Henry++.simplewall` |
| WireGuard | Pro Tools | `WireGuard.WireGuard` |
| Jellyfin Media Player | Selfhosted Tools | `Jellyfin.JellyfinMediaPlayer` |
| Jellyfin Server | Selfhosted Tools | `Jellyfin.Server` |
| Kodi Media Center | Selfhosted Tools | `XBMCFoundation.Kodi` |
| Moonlight/GameStream Client | Selfhosted Tools | `MoonlightGameStreamingProject.Moonlight` |
| NetBird | Selfhosted Tools | `Netbird.Netbird` |
| Nextcloud Desktop | Selfhosted Tools | `Nextcloud.NextcloudDesktop` |
| Plex Desktop | Selfhosted Tools | `Plex.Plex` |
| Plex Media Server | Selfhosted Tools | `Plex.PlexMediaServer` |
| 1Password | Utilities | `AgileBits.1Password` |
| BlurAutoClicker | Utilities | `Blur009.BlurAutoClicker` |
| Cloudflare WARP | Utilities | `Cloudflare.Warp` |
| Crystal Disk Mark | Utilities | `CrystalDewWorld.CrystalDiskMark` |
| Deskflow | Utilities | `Deskflow.Deskflow` |
| Dropbox | Utilities | `Dropbox.Dropbox` |
| Ente Auth | Utilities | `ente-io.auth-desktop` |
| F.lux | Utilities | `flux.flux` |
| Files | Utilities | `FilesCommunity.Files` |
| GlazeWM | Utilities | `glzr-io.glazewm` |
| Google Drive | Utilities | `Google.GoogleDrive` |
| Hugo | Utilities | `Hugo.Hugo.Extended` |
| HxD Hex Editor | Utilities | `MHNexus.HxD` |
| Internet Download Manager | Utilities | `Tonec.InternetDownloadManager` |
| JPEG View | Utilities | `sylikc.JPEGView` |
| MiniTool Partition Wizard | Utilities | `MiniTool.PartitionWizard.Free` |
| MSEdgeRedirect | Utilities | `rcmaehl.MSEdgeRedirect` |
| MSI Afterburner | Utilities | `Guru3D.Afterburner` |
| NanaZip | Utilities | `M2Team.NanaZip` |
| Nilesoft Shell | Utilities | `Nilesoft.Shell` |
| OFGB (Oh Frick Go Back) | Utilities | `xM4ddy.OFGB` |
| OPAutoClicker | Utilities | `OPAutoClicker.OPAutoClicker` |
| OpenRGB | Utilities | `OpenRGB.OpenRGB` |
| Oracle VirtualBox | Utilities | `Oracle.VirtualBox` |
| Policy Plus | Utilities | `Fleex255.PolicyPlus` |
| Process Lasso | Utilities | `BitSum.ProcessLasso` |
| Proton Authenticator | Utilities | `Proton.ProtonAuthenticator` |
| Proton Drive | Utilities | `Proton.ProtonDrive` |
| Proton Pass | Utilities | `Proton.ProtonPass` |
| Revo Uninstaller | Utilities | `RevoUninstaller.RevoUninstaller` |
| SignalRGB | Utilities | `WhirlwindFX.SignalRgb` |
| StartAllBack | Utilities | `StartIsBack.StartAllBack` |
| TeamViewer | Utilities | `TeamViewer.TeamViewer` |
| TightVNC | Utilities | `GlavSoft.TightVNC` |
| Total Commander | Utilities | `Ghisler.TotalCommander` |
| TranslucentTB | Utilities | `CharlesMilette.TranslucentTB` |
| TreeSize Free | Utilities | `JAMSoftware.TreeSize.Free` |
| WinRAR | Utilities | `RARLab.WinRAR` |
| Wise Program Uninstaller (WiseCleaner) | Utilities | `WiseCleaner.WiseProgramUninstaller` |
