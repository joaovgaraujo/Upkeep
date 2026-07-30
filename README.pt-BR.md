# Upkeep

[English](README.md) | **Português (BR)**

Atualize tudo em um PC Windows a partir de uma única janela, e configure um PC
novo do zero.

Upkeep é um painel em Rust/egui que envolve um motor em batch que aciona o
[topgrade](https://github.com/topgrade-rs/topgrade), winget, Chocolatey,
Windows Update, a Microsoft Store, Steam e JDownloader. Também traz um
caminho para PC novo: ponto de restauração, ajustes, drivers e um catálogo de
apps com predefinições.

## Leia antes de rodar

**O Upkeep roda com privilégios de administrador.** A interface carrega um
manifesto `requireAdministrator` e o motor herda essa elevação, porque
instalar atualizações no sistema todo exige isso. Isso tem consequências que
vale entender:

- **Executa scripts remotos como administrador.** O caminho de ajustes
  "winutil" usa por padrão `irm https://christitus.com/win | iex`, e o
  Chocolatey é instalado a partir de
  `community.chocolatey.org/install.ps1`. Ambos são os métodos de instalação
  documentados pelos próprios projetos, e ambos só rodam quando você aciona,
  mas são execução remota de código como administrador, e você deve estar
  confortável com isso antes de usar esses recursos.
- **Instala automaticamente as ferramentas** de que depende: Chocolatey,
  topgrade e o módulo do PowerShell `PSWindowsUpdate`.
- **Launchers de jogos abertos pelo Upkeep herdam privilégios de
  administrador** durante a sessão, assim como os jogos abertos a partir
  deles. Se isso importa para você, abra os launchers você mesmo em vez de
  usar a etapa de launchers.

## Padrões que você pode querer mudar

- **Pins: vale a pena ler este item.** Um pacote fixado ("pin") deixa de
  receber atualizações, *inclusive atualizações de segurança*. Quatro
  pacotes já vêm fixados, por dois motivos diferentes:
  - **Adobe Acrobat Reader** (`.64-bit`, `.32-bit`, `Acrobat.Pro`, e os
    equivalentes no Chocolatey) está fixado **por preferência do autor**,
    sem motivo técnico. O Acrobat é um alvo frequente de vulnerabilidades
    exploradas, então manter esse pin significa rodar um leitor de PDF
    conhecidamente desatualizado. **Se você não é o autor, provavelmente vai
    querer remover esse pin**, seja pela aba Pins ou com:
    ```
    winget pin remove --id Adobe.Acrobat.Reader.64-bit
    choco  pin remove -n=adobereader
    ```
  - **MiKTeX** e **Heroic** estão fixados porque os próprios atualizadores
    deles são quebrados; fixar evita uma falha garantida a cada execução e
    não custa nada.
- `apps.json` e `presets/` são um catálogo curado, não uma recomendação.
  Leia-os antes de rodar o caminho de PC novo.

## Opcional: tempos de inicialização

A página de Inicialização pode mostrar quanto tempo cada item de startup
leva. Esse dado não é distribuído com o programa: seriam os números de uma
máquina específica apresentados como se fossem os seus, então a coluna
Tempo fica em branco até você fornecer um `boot-times.json` ao lado do
executável:

```json
{
  "_comment": "segundos por item de inicialização; comparado sem diferenciar maiúsculas/minúsculas pelo nome",
  "some background service": 4.7,
  "another autostart app": 1.1
}
```

As chaves são os nomes (de item ou de exibição) em minúsculas; sufixos por
usuário como `_223a20` são removidos antes da busca. Um arquivo ausente ou
malformado é simplesmente ignorado.

## Compilando

Requer um toolchain Rust (MSVC) e, para o instalador, o Inno Setup 6.

```powershell
cd gui
cargo build --release          # gera gui\target\release\Upkeep.exe
cargo test --release           # 58 testes

.\Build-Portable.ps1           # dist\Upkeep-Portable.zip + dist\Upkeep\
.\Build-Installer.ps1          # dist\Upkeep-Setup.exe
```

O executável localiza seus recursos subindo a partir do próprio diretório em
busca de `SystemUpdate_Topgrade.bat`, então a pasta portátil funciona a
partir de qualquer lugar.

## Estrutura

| Caminho | O que é |
| --- | --- |
| `gui/` | painel em Rust/egui (lib `dashboard_core` + binário `Upkeep`) |
| `SystemUpdate_Topgrade.bat` | o motor de atualização; roda também sozinho |
| `steps/` | etapas de Store, Steam, JDownloader, winget e launchers |
| `Setup-NewPC.ps1` | configuração de PC novo em uma única execução |
| `Install-Apps.ps1`, `apps.json`, `presets/` | catálogo e instalador de apps |
| `installer/` | script do Inno Setup |
| `UpdateDashboard.ps1`, `Functions.ps1` | painel WPF legado, substituído |

## Status

Projeto pessoal, compartilhado caso seja útil. É desenvolvido tendo como
referência uma única máquina com Windows 11, então caminhos e suposições
podem precisar de ajuste em outras máquinas. Sem garantias. Veja
[LICENSE](LICENSE).
