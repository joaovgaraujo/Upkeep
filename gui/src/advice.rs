//! Curated "should this run?" knowledge base for services and startup items.
//! Matched case-insensitively on substrings of the service name / display
//! name (or startup entry name / command). Notes are short one-liners in
//! both languages; Windows' own service description complements them.

use crate::i18n::Lang;

#[derive(Debug, Clone, Copy, PartialEq, Eq)]
pub enum Advice {
    /// Needed by Windows/drivers or clearly valuable — leave it on.
    Keep,
    /// Legitimate but personal choice; depends on whether you use the app.
    Optional,
    /// Updater/telemetry/preloader — turning it off loses nothing real.
    SafeOff,
}

pub struct AdviceEntry {
    /// Lowercase substrings; a hit on ANY of them (against the lowercased
    /// haystack) selects this entry. First match in the list wins.
    patterns: &'static [&'static str],
    pub advice: Advice,
    note_en: &'static str,
    note_pt: &'static str,
}

impl AdviceEntry {
    pub fn note(&self, lang: Lang) -> &'static str {
        match lang {
            Lang::En => self.note_en,
            Lang::PtBr => self.note_pt,
        }
    }
}

macro_rules! entry {
    ($patterns:expr, $advice:expr, $en:expr, $pt:expr) => {
        AdviceEntry {
            patterns: $patterns,
            advice: $advice,
            note_en: $en,
            note_pt: $pt,
        }
    };
}

use Advice::{Keep, Optional, SafeOff};

/// Services knowledge base. Matched against "name display_name" lowercased.
static SERVICES_KB: &[AdviceEntry] = &[
    // -- Core Windows: keep ------------------------------------------------
    entry!(&["windefend", "defender antivirus", "defender core", "securityhealth", "wscsvc", "sgrmbroker"], Keep,
        "Part of Windows Security (your antivirus). Never turn this off.",
        "Parte da Seguran\u{e7}a do Windows (seu antiv\u{ed}rus). Nunca desligue."),
    entry!(&["samss", "security accounts manager"], Keep,
        "Core account-security service, required for Windows sign-in. Always keep it.",
        "Servi\u{e7}o central de seguran\u{e7}a de contas, necess\u{e1}rio para o login do Windows. Sempre mantenha."),
    entry!(&["wuauserv", "waasmedic", "usosvc", "uhssvc"], Keep,
        "Windows Update itself. Needed to receive security fixes.",
        "\u{c9} o pr\u{f3}prio Windows Update. Necess\u{e1}rio para receber corre\u{e7}\u{f5}es de seguran\u{e7}a."),
    entry!(&["audiosrv", "audioendpointbuilder"], Keep,
        "Windows sound. Without it, no audio.",
        "O som do Windows. Sem ele, sem \u{e1}udio."),
    entry!(&["apxsvc", "virtual audio device proxy"], Optional,
        "Proxy for virtual/spatial audio devices. Normal sound works without it.",
        "Proxy para dispositivos de \u{e1}udio virtuais/espaciais. O som normal funciona sem ele."),
    entry!(&["bfe", "mpssvc", "base filtering"], Keep,
        "The Windows firewall's foundation.",
        "A base do firewall do Windows."),
    entry!(&["bits", "dosvc", "delivery optimization"], Keep,
        "Downloads Windows and app updates in the background.",
        "Baixa atualiza\u{e7}\u{f5}es do Windows e de apps em segundo plano."),
    entry!(&["cryptsvc", "eventlog", "winmgmt", "schedule", "seclogon", "themes", "profsvc", "brokerinfrastructure", "dcomlaunch", "rpcss", "lsm "], Keep,
        "Core Windows plumbing. Leave it alone.",
        "Engrenagem essencial do Windows. Deixe como est\u{e1}."),
    entry!(&["appinfo"], Keep,
        "Handles administrator (UAC) elevation prompts.",
        "Cuida dos pedidos de eleva\u{e7}\u{e3}o de administrador (UAC)."),
    entry!(&["appxsvc", "appx deployment", "clipsvc", "installservice"], Keep,
        "Installs and updates Microsoft Store apps.",
        "Instala e atualiza apps da Loja Microsoft."),
    entry!(&["wlansvc", "dhcp", "dnscache", "netprofm", "nlasvc"], Keep,
        "Networking / Wi-Fi. Required to stay online.",
        "Rede / Wi-Fi. Necess\u{e1}rio para ficar online."),
    // -- Vendors: driver stacks -------------------------------------------
    entry!(&["nvdisplay", "nvcontainer", "nvidia display"], Keep,
        "Part of the NVIDIA graphics driver.",
        "Parte do driver de v\u{ed}deo NVIDIA."),
    entry!(&["nvtelemetry"], SafeOff,
        "NVIDIA telemetry. Nothing breaks without it.",
        "Telemetria da NVIDIA. Nada quebra sem ela."),
    entry!(&["amd crash defender", "amd external events", "amd3dvcache", "amdappcompat", "amdppkg", "amd provisioning"], Keep,
        "Part of the AMD driver stack (graphics/CPU features).",
        "Parte do pacote de drivers AMD (recursos de v\u{ed}deo/CPU)."),
    entry!(&["rtkaud", "realtek audio"], Keep,
        "Realtek audio driver helper.",
        "Auxiliar do driver de \u{e1}udio Realtek."),
    // -- Privacy / telemetry: safe off -------------------------------------
    entry!(&["diagtrack", "connected user experiences"], SafeOff,
        "Microsoft telemetry collector. The privacy tweaks disable this.",
        "Coletor de telemetria da Microsoft. Os ajustes de privacidade j\u{e1} desativam isto."),
    entry!(&["dmwappush"], SafeOff,
        "Telemetry-related push message routing.",
        "Roteamento de mensagens ligado \u{e0} telemetria."),
    entry!(&["retaildemo"], SafeOff,
        "Store-shelf demo mode. Useless on a real PC.",
        "Modo demonstra\u{e7}\u{e3}o de loja. In\u{fa}til num PC de verdade."),
    entry!(&["remoteregistry"], SafeOff,
        "Lets other machines edit this PC's registry. Off is safer.",
        "Permite que outras m\u{e1}quinas editem o registro deste PC. Desligado \u{e9} mais seguro."),
    entry!(&["fax"], SafeOff,
        "Faxing. If you don't fax, turn it off.",
        "Fax. Se voc\u{ea} n\u{e3}o usa fax, pode desligar."),
    // -- Updaters: safe off / optional -------------------------------------
    entry!(&["adobearmservice", "adobe acrobat update", "adobeupdateservice"], SafeOff,
        "Adobe's background updater. Upkeep already updates apps.",
        "Atualizador em segundo plano da Adobe. O Upkeep j\u{e1} atualiza os apps."),
    entry!(&["gupdate", "google update"], Optional,
        "Google's updater. Chrome still updates itself when opened.",
        "Atualizador da Google. O Chrome ainda se atualiza ao abrir."),
    entry!(&["edgeupdate", "microsoft edge update"], Optional,
        "Edge's updater. Keeping it on is fine; Edge also updates on launch.",
        "Atualizador do Edge. Pode manter; o Edge tamb\u{e9}m se atualiza ao abrir."),
    entry!(&["lghubupdater", "lghub updater"], SafeOff,
        "Logitech G HUB updater. Your peripherals work without it.",
        "Atualizador do Logitech G HUB. Seus perif\u{e9}ricos funcionam sem ele."),
    // -- Windows features: personal choice ---------------------------------
    entry!(&["sysmain"], Optional,
        "Preloads your frequent apps. Fine on or off with an SSD.",
        "Pr\u{e9}-carrega seus apps frequentes. Tanto faz ligado ou desligado com SSD."),
    entry!(&["wsearch", "windows search"], Optional,
        "Indexes files so Start-menu search is instant. Uses some disk in background.",
        "Indexa arquivos para a busca do menu Iniciar ser instant\u{e2}nea. Usa um pouco de disco em segundo plano."),
    entry!(&["spooler"], Optional,
        "Printing. Safe to disable only if you never print.",
        "Impress\u{e3}o. S\u{f3} desligue se voc\u{ea} nunca imprime."),
    entry!(&["xblauthmanager", "xblgamesave", "xboxnetapisvc", "xboxgip", "xbox"], Optional,
        "Only needed for Xbox app / Game Pass features.",
        "Necess\u{e1}rio apenas para o app Xbox / Game Pass."),
    entry!(&["lfsvc", "geolocation"], Optional,
        "Location service (time zone, Find My Device, weather).",
        "Servi\u{e7}o de localiza\u{e7}\u{e3}o (fuso hor\u{e1}rio, Encontrar Meu Dispositivo, clima)."),
    entry!(&["mapsbroker"], Optional,
        "Offline maps updates. Off is fine if you don't use the Maps app.",
        "Atualiza\u{e7}\u{e3}o de mapas offline. Pode desligar se n\u{e3}o usa o app Mapas."),
    entry!(&["wersvc", "error reporting"], Optional,
        "Sends crash reports to Microsoft.",
        "Envia relat\u{f3}rios de travamento \u{e0} Microsoft."),
    entry!(&["wbiosrvc", "biometric"], Optional,
        "Fingerprint/face sign-in. Keep if you use Windows Hello.",
        "Login por biometria. Mantenha se usa o Windows Hello."),
    entry!(&["phonesvc", "phone service"], Optional,
        "Used by Phone Link. Off is fine if you don't pair a phone.",
        "Usado pelo Link do Celular. Pode desligar se n\u{e3}o conecta um celular."),
    entry!(&["aarsvc", "agent activation"], Optional,
        "Voice-assistant activation runtime. Manual is fine.",
        "Runtime de ativa\u{e7}\u{e3}o por voz. Manual est\u{e1} \u{f3}timo."),
    entry!(&["alg", "application layer gateway"], Optional,
        "Legacy Internet Connection Sharing plug-ins. Rarely used today.",
        "Plug-ins legados de compartilhamento de conex\u{e3}o. Raramente usado hoje."),
    // -- Third-party apps: depends on usage ---------------------------------
    entry!(&["com.docker", "docker"], Optional,
        "Docker's backend. Only needed while you develop with containers.",
        "Backend do Docker. S\u{f3} necess\u{e1}rio enquanto voc\u{ea} desenvolve com cont\u{ea}ineres."),
    entry!(&["rustdesk"], Optional,
        "Remote-access server. Keep ONLY if you use RustDesk to reach this PC from elsewhere.",
        "Servidor de acesso remoto. Mantenha APENAS se voc\u{ea} usa o RustDesk para acessar este PC de fora."),
    entry!(&["sunshine"], Optional,
        "Game-streaming host for Moonlight clients. Needed only while streaming.",
        "Servidor de streaming de jogos para clientes Moonlight. Necess\u{e1}rio s\u{f3} durante o streaming."),
    entry!(&["tailscale"], Optional,
        "Your private VPN. Keep if this PC should stay reachable through Tailscale.",
        "Sua VPN privada. Mantenha se este PC deve continuar acess\u{ed}vel pelo Tailscale."),
    entry!(&["teamviewer"], Optional,
        "Remote access. Keep only if you rely on unattended TeamViewer access.",
        "Acesso remoto. Mantenha s\u{f3} se depende de acesso TeamViewer n\u{e3}o assistido."),
    entry!(&["parsec"], Optional,
        "Low-latency remote desktop. Keep if you connect to this PC with Parsec.",
        "Acesso remoto de baixa lat\u{ea}ncia. Mantenha se voc\u{ea} conecta neste PC via Parsec."),
    entry!(&["steam client service"], Optional,
        "Started by Steam on demand; Manual is the right setting.",
        "Iniciado pelo Steam quando preciso; Manual \u{e9} o ajuste certo."),
    entry!(&["flexnet", "solidworks", "swvisualize"], Optional,
        "SolidWorks licensing/queue services. Needed while using SolidWorks.",
        "Servi\u{e7}os de licen\u{e7}a/fila do SolidWorks. Necess\u{e1}rios ao usar o SolidWorks."),
    entry!(&["macrium", "reflect"], Keep,
        "Macrium Reflect's backup scheduler. Keep if you rely on scheduled backups.",
        "Agendador de backups do Macrium Reflect. Mantenha se depende de backups agendados."),
    entry!(&["everything"], Optional,
        "Everything's file indexer, for instant filename search.",
        "Indexador do Everything, para busca instant\u{e2}nea de arquivos."),
    entry!(&["ollama"], Optional,
        "Local AI model server. Start it manually when you need it.",
        "Servidor local de modelos de IA. Inicie manualmente quando precisar."),
    entry!(&["gubootservice", "gumemfiles", "glary"], Optional,
        "Part of Glary Utilities (its boot-time measurement lives here). Fine to disable if you stop using Glary.",
        "Parte do Glary Utilities (a medi\u{e7}\u{e3}o de tempo de boot vem daqui). Pode desligar se deixar de usar o Glary."),
    entry!(&["ssh-agent"], Optional,
        "Holds SSH keys for developers. Manual is fine.",
        "Guarda chaves SSH para desenvolvedores. Manual est\u{e1} \u{f3}timo."),
    entry!(&["bonjour"], Optional,
        "Apple device discovery (AirPlay, iTunes). Off is fine without Apple gear.",
        "Descoberta de dispositivos Apple (AirPlay, iTunes). Pode desligar sem aparelhos Apple."),
    entry!(&["vmms", "hyper-v"], Optional,
        "Runs Hyper-V virtual machines. Only needed if you use Hyper-V (WSL2 uses its own lighter service).",
        "Executa m\u{e1}quinas virtuais Hyper-V. S\u{f3} necess\u{e1}rio se voc\u{ea} usa o Hyper-V (o WSL2 usa outro servi\u{e7}o mais leve)."),
    entry!(&["nfsclnt", "client for nfs"], Optional,
        "Access to Linux/NFS network shares. Off is fine if you never mount NFS drives.",
        "Acesso a compartilhamentos de rede NFS/Linux. Pode desligar se voc\u{ea} nunca monta unidades NFS."),
    entry!(&["appidsvc", "application identity"], Optional,
        "Only used by AppLocker application-restriction rules; home PCs don't need it.",
        "Usado apenas pelas regras de restri\u{e7}\u{e3}o AppLocker; PCs dom\u{e9}sticos n\u{e3}o precisam dele."),
    entry!(&["appmgmt", "application management"], Optional,
        "Legacy remote software install (Group Policy). Safe off at home.",
        "Instala\u{e7}\u{e3}o remota legada de software (Pol\u{ed}tica de Grupo). Pode desligar em casa."),
    entry!(&["appreadiness", "app readiness"], Optional,
        "Finishes preparing Store apps after updates/sign-in. Low impact either way.",
        "Finaliza a prepara\u{e7}\u{e3}o de apps da Loja ap\u{f3}s atualiza\u{e7}\u{f5}es/login. Pouco impacto de qualquer forma."),
    entry!(&["appvclient", "app-v"], Optional,
        "Microsoft App-V application virtualization. Only for corporate setups that use it.",
        "Virtualiza\u{e7}\u{e3}o de aplicativos App-V da Microsoft. S\u{f3} para ambientes corporativos que a usam."),
    entry!(&["assignedaccess"], SafeOff,
        "Kiosk mode support. No effect on a normal PC.",
        "Suporte ao modo quiosque. Sem efeito num PC normal."),
    entry!(&["wslservice", "wsl service", "subsystem for linux"], Optional,
        "Windows Subsystem for Linux. Keep if you use Linux tools on Windows.",
        "Subsistema do Windows para Linux. Mantenha se usa ferramentas Linux no Windows."),
    entry!(&["cdrom device arbiter"], Keep,
        "Manages CD/DVD drive visibility. Disabling can make drives disappear; idle cost is minimal.",
        "Gerencia a exibi\u{e7}\u{e3}o de unidades de CD/DVD. Desligar pode fazer as unidades sumirem; o custo ocioso \u{e9} m\u{ed}nimo."),
    entry!(&["adpsvc", "aggregated data platform"], Keep,
        "Part of Windows' data platform. Leave it at its default.",
        "Parte da plataforma de dados do Windows. Deixe no padr\u{e3}o."),
    entry!(&["remote solver", "flow simulation"], Optional,
        "SolidWorks remote simulation solver. Only needed while running simulations.",
        "Solver remoto de simula\u{e7}\u{e3}o do SolidWorks. Necess\u{e1}rio apenas ao rodar simula\u{e7}\u{f5}es."),
    entry!(&["lamparray", "logisync"], Optional,
        "Logitech lighting/sync helpers. Devices keep working without them.",
        "Auxiliares de ilumina\u{e7}\u{e3}o/sincroniza\u{e7}\u{e3}o da Logitech. Os dispositivos continuam funcionando sem eles."),
];

/// Startup-items knowledge base. Matched against "name command" lowercased.
static STARTUP_KB: &[AdviceEntry] = &[
    entry!(&["securityhealth"], Keep,
        "The Windows Security tray icon. Leave it on.",
        "\u{cd}cone da Seguran\u{e7}a do Windows. Deixe ligado."),
    entry!(&["microsoftedgeautolaunch", "--no-startup-window"], SafeOff,
        "Preloads Edge at login just to open faster later. Pure convenience.",
        "Pr\u{e9}-carrega o Edge no login s\u{f3} para abrir mais r\u{e1}pido depois. Pura conveni\u{ea}ncia."),
    entry!(&["adobecollabsync", "acrobat synchronizer", "adobe acrobat synchronizer"], SafeOff,
        "Adobe Acrobat sync helper. Acrobat works fine without it.",
        "Auxiliar de sincroniza\u{e7}\u{e3}o do Acrobat. O Acrobat funciona bem sem ele."),
    entry!(&["ccxprocess"], SafeOff,
        "Adobe Creative Cloud promo/content helper.",
        "Auxiliar de conte\u{fa}do/promo\u{e7}\u{f5}es da Adobe Creative Cloud."),
    entry!(&["adobegcinvoker", "agcinvokerutility"], SafeOff,
        "Adobe licensing check helper; runs fine on demand.",
        "Verifica\u{e7}\u{e3}o de licen\u{e7}a da Adobe; roda sob demanda quando preciso."),
    entry!(&["onedrive"], Optional,
        "Syncs your files to OneDrive from login. Disable if you don't use OneDrive.",
        "Sincroniza seus arquivos com o OneDrive desde o login. Desligue se n\u{e3}o usa OneDrive."),
    entry!(&["discord"], Optional,
        "Opens Discord at login. You can just open it when you want to chat.",
        "Abre o Discord no login. Voc\u{ea} pode abrir s\u{f3} quando quiser conversar."),
    entry!(&["docker desktop"], Optional,
        "Heavy at boot. Start Docker when you actually need containers.",
        "Pesado no boot. Inicie o Docker quando realmente precisar de cont\u{ea}ineres."),
    entry!(&["everything"], Keep,
        "Instant file search depends on it running in the background.",
        "A busca instant\u{e2}nea de arquivos depende dele rodando em segundo plano."),
    entry!(&["greenshot"], Optional,
        "Needed at startup for its PrintScreen hotkeys to work.",
        "Precisa iniciar junto para os atalhos de PrintScreen funcionarem."),
    entry!(&["ollama"], Optional,
        "Local AI server from login. Start it manually when needed instead.",
        "Servidor local de IA desde o login. Prefira iniciar manualmente quando precisar."),
    entry!(&["displaymagician"], Optional,
        "Display profile switcher; keep if you use its game profiles.",
        "Troca de perfis de v\u{ed}deo; mantenha se usa os perfis por jogo."),
    entry!(&["reflectui", "macrium"], Keep,
        "Macrium Reflect's tray monitor for scheduled backups.",
        "Monitor do Macrium Reflect para backups agendados."),
    entry!(&["steam"], Optional,
        "Opens Steam at login (tray). Handy for gamers, not required.",
        "Abre o Steam no login (bandeja). \u{da}til para quem joga, n\u{e3}o obrigat\u{f3}rio."),
    entry!(&["epicgameslauncher", "epic games"], SafeOff,
        "Only needed when you play Epic games; it opens itself then.",
        "S\u{f3} necess\u{e1}rio quando voc\u{ea} joga algo da Epic; ele abre sozinho na hora."),
    entry!(&["battle.net", "battlenet"], Optional,
        "Game launcher at login. Optional.",
        "Launcher de jogos no login. Opcional."),
    entry!(&["spotify"], Optional,
        "Opens Spotify at login.",
        "Abre o Spotify no login."),
    entry!(&["whatsapp", "telegram"], Optional,
        "Messenger at login \u{2014} keep it if you want messages from the start.",
        "Mensageiro no login \u{2014} mantenha se quer receber mensagens desde o in\u{ed}cio."),
    entry!(&["rtkauduservice", "realtek"], Keep,
        "Realtek audio driver component.",
        "Componente do driver de \u{e1}udio Realtek."),
    entry!(&["nvbackend", "nvidia"], Optional,
        "NVIDIA extras (GeForce Experience features).",
        "Extras da NVIDIA (recursos do GeForce Experience)."),
    entry!(&["lghub", "logi"], Optional,
        "Logitech software for RGB/macros. Devices work basically without it.",
        "Software Logitech para RGB/macros. Os dispositivos funcionam basicamente sem ele."),
    entry!(&["icue", "corsair"], Optional,
        "Corsair RGB/macros software.",
        "Software de RGB/macros da Corsair."),
    entry!(&["parsec"], Optional,
        "Keep if you connect to this PC remotely with Parsec.",
        "Mantenha se voc\u{ea} acessa este PC remotamente com o Parsec."),
    entry!(&["rustdesk"], Optional,
        "Keep ONLY if you use RustDesk to reach this PC remotely.",
        "Mantenha APENAS se usa o RustDesk para acessar este PC remotamente."),
    entry!(&["tailscale"], Optional,
        "Your VPN's tray client.",
        "Cliente de bandeja da sua VPN."),
    entry!(&["jdownloader"], Optional,
        "Download manager at login; opening it manually works too.",
        "Gerenciador de downloads no login; abrir manualmente tamb\u{e9}m funciona."),
    entry!(&["wallpaper engine", "wallpaper64", "wallpaper32"], Optional,
        "Animated wallpapers from login.",
        "Pap\u{e9}is de parede animados desde o login."),
    entry!(&["classiccontextmenu"], Optional,
        "Restores the old Windows 10 right-click menu on Windows 11. Keep if you prefer it.",
        "Restaura o menu de bot\u{e3}o direito cl\u{e1}ssico do Windows 10 no Windows 11. Mantenha se prefere assim."),
    entry!(&["eartrumpet"], Keep,
        "Per-app volume control in the tray; it needs to start with Windows to be useful.",
        "Controle de volume por app na bandeja; precisa iniciar com o Windows para ser \u{fa}til."),
    entry!(&["bravesoftwareupdate", "brave update"], SafeOff,
        "Brave's background updater; Brave also updates itself when opened.",
        "Atualizador em segundo plano do Brave; o Brave tamb\u{e9}m se atualiza ao abrir."),
    entry!(&["microsoft edge installer", "edgeupdate", "msedge_cleanup"], SafeOff,
        "Edge update/preload helper. Edge still updates when launched.",
        "Auxiliar de atualiza\u{e7}\u{e3}o/pr\u{e9}-carga do Edge. O Edge ainda se atualiza ao abrir."),
    entry!(&["webex"], Optional,
        "Webex helper at login. Only useful if you join Webex meetings regularly.",
        "Auxiliar do Webex no login. \u{da}til apenas se voc\u{ea} participa de reuni\u{f5}es Webex com frequ\u{ea}ncia."),
    entry!(&["eabackground", "ea desktop", "eadesktop"], SafeOff,
        "EA launcher background helper; it starts itself when you play EA games.",
        "Auxiliar do launcher da EA; ele inicia sozinho quando voc\u{ea} joga algo da EA."),
    entry!(&["glary"], Optional,
        "Glary Utilities autostart component.",
        "Componente de autostart do Glary Utilities."),
    entry!(&["command palette", "powertoys"], Optional,
        "PowerToys helper; needed at login for its hotkeys to work.",
        "Auxiliar do PowerToys; precisa iniciar junto para os atalhos funcionarem."),
    // -- Scheduled-task patterns (the Tasks section shares this KB) ---------
    entry!(&["googleupdatertask", "googleupdatetask"], Optional,
        "Keeps Chrome/Google apps updated in the background.",
        "Mant\u{e9}m o Chrome e apps da Google atualizados em segundo plano."),
    entry!(&["amd install manager"], Optional,
        "Periodically checks for AMD driver updates. Optional if you update drivers yourself.",
        "Verifica periodicamente atualiza\u{e7}\u{f5}es de driver AMD. Opcional se voc\u{ea} mesmo atualiza os drivers."),
    entry!(&["amdx3dinstaller"], Optional,
        "AMD 3D V-Cache setup helper for X3D CPUs.",
        "Auxiliar de configura\u{e7}\u{e3}o do 3D V-Cache da AMD para CPUs X3D."),
    entry!(&["equalizerapoupdatechecker"], SafeOff,
        "Update check for Equalizer APO; check for updates manually instead.",
        "Verifica\u{e7}\u{e3}o de atualiza\u{e7}\u{e3}o do Equalizer APO; verifique manualmente quando quiser."),
    entry!(&["npcapwatchdog"], Optional,
        "Watches the Npcap packet-capture driver (used by Wireshark).",
        "Monitora o driver de captura de pacotes Npcap (usado pelo Wireshark)."),
    entry!(&["firefox default browser agent"], SafeOff,
        "Reports default-browser status to Mozilla. Firefox works fine without it.",
        "Reporta \u{e0} Mozilla qual \u{e9} o navegador padr\u{e3}o. O Firefox funciona bem sem isso."),
    entry!(&["matlab", "startup accelerator"], Optional,
        "Preloads MATLAB so it opens faster. Disable to free memory at logon.",
        "Pr\u{e9}-carrega o MATLAB para abrir mais r\u{e1}pido. Desligue para liberar mem\u{f3}ria no login."),
    entry!(&["createexplorershellunelevatedtask"], Keep,
        "Windows task that respawns Explorer unelevated. Leave it.",
        "Tarefa do Windows que reinicia o Explorer sem eleva\u{e7}\u{e3}o. Deixe como est\u{e1}."),
    entry!(&["runplatformexperiencehelper"], SafeOff,
        "Daily telemetry/experience reporting task.",
        "Tarefa di\u{e1}ria de telemetria/relat\u{f3}rio de experi\u{ea}ncia."),
    entry!(&["klcp_update"], SafeOff,
        "K-Lite codec pack update check.",
        "Verifica\u{e7}\u{e3}o de atualiza\u{e7}\u{e3}o do pacote de codecs K-Lite."),
    entry!(&["bluestackshelper"], SafeOff,
        "BlueStacks emulator helper task.",
        "Tarefa auxiliar do emulador BlueStacks."),
    entry!(&["autorun for"], Optional,
        "This is PowerToys' own autostart task (runs PowerToys.exe). Heavy at sign-in \u{2014} disable only if you don't need FancyZones & co. right away.",
        "\u{c9} a tarefa de autostart do pr\u{f3}prio PowerToys (executa PowerToys.exe). Pesada no login \u{2014} desligue s\u{f3} se n\u{e3}o precisar do FancyZones e cia. de imediato."),
    entry!(&["gigabyte", "gcc"], Optional,
        "Gigabyte Control Center (motherboard RGB/fan/BIOS utility). The board works fine without it.",
        "Gigabyte Control Center (utilit\u{e1}rio de RGB/ventoinhas/BIOS da placa-m\u{e3}e). A placa funciona bem sem ele."),
    entry!(&["railsim"], Optional,
        "Your own RL-training watchdog task (relaunches the V19 python run from checkpoints). Disable when the experiment is done.",
        "Sua pr\u{f3}pria tarefa de watchdog do treinamento RL (relan\u{e7}a o run V19 a partir de checkpoints). Desligue quando o experimento terminar."),
    entry!(&["steelseries"], Optional,
        "SteelSeries GG peripherals software. Devices keep working with saved settings without it.",
        "Software SteelSeries GG para perif\u{e9}ricos. Os dispositivos continuam funcionando com as configura\u{e7}\u{f5}es salvas sem ele."),
    entry!(&["wingetui", "unigetui"], SafeOff,
        "UniGetUI's tray daemon; it only pre-checks package updates. Open the app when you want it.",
        "Daemon de bandeja do UniGetUI; s\u{f3} pr\u{e9}-verifica atualiza\u{e7}\u{f5}es de pacotes. Abra o app quando quiser."),
    entry!(&["send to onenote"], SafeOff,
        "Legacy 'Send to OneNote' helper. Nothing else depends on it.",
        "Auxiliar antigo 'Enviar para o OneNote'. Nada mais depende dele."),
    entry!(&["solidworks"], SafeOff,
        "SolidWorks Fast Start / Background Downloader preloaders. SolidWorks just opens a bit slower without them.",
        "Pr\u{e9}-carregadores Fast Start / Background Downloader do SolidWorks. O SolidWorks s\u{f3} abre um pouco mais devagar sem eles."),
    entry!(&["office automatic updates"], Optional,
        "Keeps Microsoft Office updated in the background.",
        "Mant\u{e9}m o Microsoft Office atualizado em segundo plano."),
    entry!(&["office actions server", "office background push", "office feature updates", "office startup maintenance", "office serviceability"], SafeOff,
        "Office background telemetry/feature-deployment tasks. Office itself is unaffected.",
        "Tarefas de telemetria/implanta\u{e7}\u{e3}o de recursos do Office em segundo plano. O Office em si n\u{e3}o \u{e9} afetado."),
    entry!(&["updateconfiguration"], Optional,
        "Visual Studio's background update check.",
        "Verifica\u{e7}\u{e3}o de atualiza\u{e7}\u{e3}o do Visual Studio em segundo plano."),
    entry!(&["ad rms rights policy"], SafeOff,
        "Corporate document-DRM template task. Useless on a personal PC.",
        "Tarefa de modelos DRM corporativos para documentos. In\u{fa}til num PC pessoal."),
    entry!(&["verifiedpublishercertstorecheck"], SafeOff,
        "Background AppID certificate check tied to AppLocker. No effect on a home PC.",
        "Verifica\u{e7}\u{e3}o de certificados AppID ligada ao AppLocker. Sem efeito num PC dom\u{e9}stico."),
    entry!(&["pre-staged app cleanup"], SafeOff,
        "Cleanup of pre-staged Store apps. Harmless either way.",
        "Limpeza de apps da Loja pr\u{e9}-preparados. Inofensivo de qualquer forma."),
    entry!(&["autochk"], SafeOff,
        "Uploads disk-check telemetry to Microsoft.",
        "Envia telemetria de verifica\u{e7}\u{e3}o de disco \u{e0} Microsoft."),
    entry!(&["device information"], SafeOff,
        "Device census telemetry task.",
        "Tarefa de telemetria de invent\u{e1}rio do dispositivo."),
    entry!(&["remediatehardwarechange", "mdmdiagnosticscleanup"], SafeOff,
        "Corporate Autopilot/MDM provisioning tasks. Irrelevant on an unmanaged personal PC.",
        "Tarefas de provisionamento corporativo Autopilot/MDM. Irrelevantes num PC pessoal n\u{e3}o gerenciado."),
    entry!(&["diskdiagnostic"], Optional,
        "Warns you when a drive reports S.M.A.R.T. failures. Keep unless you monitor disk health with another tool.",
        "Avisa quando um disco reporta falhas S.M.A.R.T. Mantenha, a menos que monitore a sa\u{fa}de dos discos com outra ferramenta."),
];

fn find(kb: &'static [AdviceEntry], haystack: &str) -> Option<&'static AdviceEntry> {
    let hay = haystack.to_lowercase();
    kb.iter()
        .find(|e| e.patterns.iter().any(|p| hay.contains(p)))
}

/// Advice for a Windows service, matched on its short and display names.
pub fn service_advice(name: &str, display_name: &str) -> Option<&'static AdviceEntry> {
    find(SERVICES_KB, &format!("{name} {display_name}"))
}

/// Advice for a startup entry, matched on its name and command line.
pub fn startup_advice(name: &str, command: &str) -> Option<&'static AdviceEntry> {
    find(STARTUP_KB, &format!("{name} {command}"))
}

#[cfg(test)]
mod tests {
    use super::*;

    #[test]
    fn matches_known_services_and_startup_items() {
        assert_eq!(service_advice("WinDefend", "Microsoft Defender Antivirus Service").map(|e| e.advice), Some(Keep));
        assert_eq!(service_advice("DiagTrack", "Connected User Experiences and Telemetry").map(|e| e.advice), Some(SafeOff));
        assert_eq!(service_advice("com.docker.service", "Docker Desktop Service").map(|e| e.advice), Some(Optional));
        assert_eq!(
            startup_advice("MicrosoftEdgeAutoLaunch_ABC", "msedge.exe --no-startup-window").map(|e| e.advice),
            Some(SafeOff)
        );
        assert_eq!(startup_advice("OneDrive", "OneDrive.exe /background").map(|e| e.advice), Some(Optional));
        assert!(startup_advice("SomeUnknownThing", "x.exe").is_none());
    }

    #[test]
    fn every_entry_has_notes_in_both_languages() {
        for kb in [SERVICES_KB, STARTUP_KB] {
            for e in kb {
                assert!(!e.note(Lang::En).is_empty());
                assert!(!e.note(Lang::PtBr).is_empty());
                assert!(!e.patterns.is_empty());
                for p in e.patterns {
                    assert_eq!(*p, p.to_lowercase(), "patterns must be lowercase: {p}");
                }
            }
        }
    }
}
