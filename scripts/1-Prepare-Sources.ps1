# =============================================================================
# 1-Prepare-Sources.ps1
# 4Story (source C:\Users\Administrator\4s) - Preparation des sources
#
#   1. Migration VS 2005 (.vcproj) -> VS 2017 (.vcxproj) via devenv /upgrade
#   2. Application des correctifs source necessaires pour VS 2017 :
#        A. TNetLib/stdafx.h        — _WIN32_WINNT 0x0501
#        B. TNetLib/TNetLib.h       — #include <winnls.h>
#        C. 4s_pre_include.h        — header Windows force-inclus
#        D. ForcedIncludeFiles      — injection dans les 5 .vcxproj
#        E. TRelaySvr/sshandler.cpp — for(DWORD i=0; ...) (C2065)
#        F. PreMessageLoop bypass   — SetServiceStatus() direct (fix SCM 1053)
#        G. TMapSvr/SSHandler.cpp   — CTime(y,m,d,h,m,s) decompose (crash BatchThread)
#        H. TLoginSvr/TLoginSvr.cpp — Always SESSION_CLIENT (fix single-machine)
#        I. TMapSvr/TMapSvr.cpp     — Always SESSION_CLIENT (fix connexion jeu)
#        J. ProtocolBase.h          — TVERSION 0x1028 -> 0x102b (version client TW)
#
# Prerequis : Visual Studio 2017 avec "Desktop development with C++" installe
# Sources deja presentes dans C:\Users\Administrator\4s\
# =============================================================================

#Requires -RunAsAdministrator
$ErrorActionPreference = "Stop"

$SourceBase  = Split-Path -Parent $PSScriptRoot
$TServerDir  = "$SourceBase\TServer"
$TServerSln  = "$TServerDir\TServer.sln"

# =============================================================================
# Fonctions
# =============================================================================
function Write-Step {
    param([string]$Num, [string]$Message)
    Write-Host "`n============================================================" -ForegroundColor Yellow
    Write-Host "  Etape $Num : $Message" -ForegroundColor Yellow
    Write-Host "============================================================" -ForegroundColor Yellow
}
function Write-Info { param([string]$M) Write-Host "  [*] $M" -ForegroundColor Cyan   }
function Write-OK   { param([string]$M) Write-Host "  [+] $M" -ForegroundColor Green  }
function Write-Warn { param([string]$M) Write-Host "  [!] $M" -ForegroundColor Yellow }
function Write-Err  { param([string]$M) Write-Host "  [-] $M" -ForegroundColor Red    }

function Find-VS2017 {
    $vswhere = "${env:ProgramFiles(x86)}\Microsoft Visual Studio\Installer\vswhere.exe"
    if (Test-Path $vswhere) {
        $p = & $vswhere -version "[15.0,16.0)" -property installationPath 2>$null
        if ($p) { return $p }
    }
    foreach ($ed in @("Community","Professional","Enterprise")) {
        $p = "${env:ProgramFiles(x86)}\Microsoft Visual Studio\2017\$ed"
        if (Test-Path $p) { return $p }
    }
    return $null
}

# Lit/ecrit les fichiers en ISO-8859-1 (compatible EUC-KR pour les commentaires coreen)
$iso = [System.Text.Encoding]::GetEncoding(28591)

function Patch-File {
    param([string]$Path, [string]$OldText, [string]$NewText, [string]$CheckFor="", [string]$Label)
    if (-not (Test-Path $Path)) { Write-Warn "  $Label : introuvable ($Path)"; return }
    $bytes   = [System.IO.File]::ReadAllBytes($Path)
    $content = $iso.GetString($bytes)
    $chk     = if ($CheckFor) { $CheckFor } else { $NewText.Substring(0, [Math]::Min(30, $NewText.Length)) }
    if ($content.Contains($chk))          { Write-OK   "  $Label : deja applique"; return }
    if (-not $content.Contains($OldText)) { Write-Warn "  $Label : motif non trouve (version differente ?)"; return }
    [System.IO.File]::WriteAllBytes($Path, $iso.GetBytes($content.Replace($OldText, $NewText)))
    Write-OK "  $Label : applique"
}

# =============================================================================
# DEBUT
# =============================================================================
Write-Host ""
Write-Host "############################################################" -ForegroundColor Cyan
Write-Host "#     4Story - Etape 1 : Preparation des sources          #" -ForegroundColor Cyan
Write-Host "############################################################" -ForegroundColor Cyan

if (-not (Test-Path $TServerSln)) {
    Write-Err "Solution introuvable : $TServerSln"
    exit 1
}

# =============================================================================
# 1. Migration VS 2005 -> VS 2017
# =============================================================================
Write-Step 1 "Migration VS 2005 (.vcproj) -> VS 2017 (.vcxproj)"

$alreadyUpgraded = Test-Path "$TServerDir\TNetLib\TNetLib.vcxproj"
if ($alreadyUpgraded) {
    Write-OK "Migration deja effectuee (TNetLib.vcxproj existe)."
} else {
    $vsPath = Find-VS2017
    if (-not $vsPath) { Write-Err "Visual Studio 2017 introuvable."; exit 1 }
    $Devenv = "$vsPath\Common7\IDE\devenv.exe"
    if (-not (Test-Path $Devenv)) { Write-Err "devenv.exe introuvable dans $vsPath"; exit 1 }

    Write-Info "Lancement de devenv /upgrade sur TServer.sln (1-2 min)..."
    $proc = Start-Process -FilePath $Devenv `
        -ArgumentList @("`"$TServerSln`"", "/upgrade") `
        -Wait -PassThru -NoNewWindow
    if ($proc.ExitCode -ne 0) {
        Write-Err "devenv /upgrade a echoue (code $($proc.ExitCode))."
        Write-Warn "Verifiez UpgradeLog.htm dans $TServerDir"
        exit 1
    }
    $vcxproj = Get-ChildItem $TServerDir -Recurse -Filter "*.vcxproj" -ErrorAction SilentlyContinue
    if ($vcxproj) { Write-OK "Migration reussie : $($vcxproj.Count) projet(s) convertis." }
    else          { Write-Warn "Aucun .vcxproj genere - verifiez UpgradeLog.htm dans $TServerDir" }
}

# =============================================================================
# 2. Correctifs source
# =============================================================================
Write-Step 2 "Application des correctifs source"

# 2-A : TNetLib/stdafx.h — _WIN32_WINNT 0x0501 (WSAID_CONNECTEX, LPFN_CONNECTEX)
$stdafxPath = "$TServerDir\TNetLib\stdafx.h"
if (Test-Path $stdafxPath) {
    $bytes = [System.IO.File]::ReadAllBytes($stdafxPath)
    $text  = $iso.GetString($bytes)
    if ($text -match '_WIN32_WINNT 0x0501') {
        Write-OK "  TNetLib/stdafx.h : _WIN32_WINNT deja 0x0501"
    } else {
        $patched = [regex]::Replace($text, '_WIN32_WINNT 0x[0-9A-Fa-f]+', '_WIN32_WINNT 0x0501')
        [System.IO.File]::WriteAllBytes($stdafxPath, $iso.GetBytes($patched))
        Write-OK "  TNetLib/stdafx.h : _WIN32_WINNT -> 0x0501"
    }
} else { Write-Warn "  TNetLib/stdafx.h introuvable" }

# 2-B : TNetLib/TNetLib.h — #include <winnls.h>
Patch-File -Path "$TServerDir\TNetLib\TNetLib.h" `
    -OldText "#include <mswsock.h>" `
    -NewText "#include <mswsock.h>`r`n#include <winnls.h>" `
    -CheckFor "#include <winnls.h>" `
    -Label "TNetLib.h : +#include <winnls.h>"

# 2-C : 4s_pre_include.h (force-inclus dans tous les projets serveur)
$preIncludePath = "$TServerDir\4s_pre_include.h"
if (-not (Test-Path $preIncludePath)) {
    $preContent = "#ifndef WIN32_LEAN_AND_MEAN`r`n#define WIN32_LEAN_AND_MEAN`r`n#endif`r`n#include <windows.h>`r`n#include <winnls.h>`r`n"
    [System.IO.File]::WriteAllText($preIncludePath, $preContent, [System.Text.Encoding]::ASCII)
    Write-OK "  4s_pre_include.h : cree"
} else { Write-OK "  4s_pre_include.h : deja present" }

# 2-D : ForcedIncludeFiles dans les 5 .vcxproj
foreach ($vcx in @(
    "$TServerDir\TControlSvr\TControlSvr.vcxproj",
    "$TServerDir\TLoginSvr\TLoginSvr.vcxproj",
    "$TServerDir\TWorldSvr\TWorldSvr.vcxproj",
    "$TServerDir\TMapSvr\TMapSvr.vcxproj",
    "$TServerDir\TRelaySvr\TRelaySvr.vcxproj")) {
    if (-not (Test-Path $vcx)) { Write-Warn "  vcxproj introuvable : $vcx (pas encore migre ?)"; continue }
    [xml]$xml = Get-Content $vcx -Encoding UTF8
    $ns = "http://schemas.microsoft.com/developer/msbuild/2003"
    $changed = $false
    foreach ($idg in $xml.Project.ItemDefinitionGroup) {
        $cl = $idg.ClCompile
        if ($cl) {
            if (-not $cl.ForcedIncludeFiles) {
                $e = $xml.CreateElement("ForcedIncludeFiles", $ns)
                $e.InnerText = $preIncludePath
                $cl.AppendChild($e) | Out-Null
                $changed = $true
            } elseif ($cl.ForcedIncludeFiles -ne $preIncludePath) {
                $cl.ForcedIncludeFiles = $preIncludePath
                $changed = $true
            }
        }
    }
    if ($changed) { $xml.Save($vcx); Write-OK "  $([IO.Path]::GetFileName($vcx)) : ForcedIncludeFiles mis a jour -> $preIncludePath" }
    else          { Write-OK "  $([IO.Path]::GetFileName($vcx)) : ForcedIncludeFiles deja correct" }
}

# 2-E : TRelaySvr/sshandler.cpp — for(DWORD i=0; ...) (C2065 'i' undeclared)
Patch-File -Path "$TServerDir\TRelaySvr\sshandler.cpp" `
    -OldText "for(i=0; i<wCount; i++)" `
    -NewText "for(DWORD i=0; i<wCount; i++)" `
    -CheckFor "for(DWORD i=0;" `
    -Label "sshandler.cpp : for(DWORD i=0) (fix C2065)"

# 2-F : PreMessageLoop bypass dans les 5 serveurs
#   Sans ce correctif, CoRegisterClassObject bloque ~30s => SCM erreur 1053 au demarrage
$pmlPatches = @(
    @{ F="$TServerDir\TControlSvr\TControlSvr.cpp"
       O="`treturn CAtlServiceModuleT<CTControlSvrModule,IDS_SERVICENAME>::PreMessageLoop(nShowCmd);"
       N="`tif (m_bService)`r`n`t{`r`n`t`tSetServiceStatus(SERVICE_RUNNING);`r`n`t`treturn S_OK;`r`n`t}`r`n`r`n`treturn CAtlServiceModuleT<CTControlSvrModule,IDS_SERVICENAME>::PreMessageLoop(nShowCmd);"
       C="SetServiceStatus(SERVICE_RUNNING);" ; L="TControlSvr : PreMessageLoop bypass" },
    @{ F="$TServerDir\TLoginSvr\TLoginSvr.cpp"
       O="`treturn CAtlServiceModuleT<CTLoginSvrModule,IDS_SERVICENAME>::PreMessageLoop(nShowCmd);"
       N="`tif (m_bService)`r`n`t{`r`n`t`tSetServiceStatus(SERVICE_RUNNING);`r`n`t`treturn S_OK;`r`n`t}`r`n`r`n`treturn CAtlServiceModuleT<CTLoginSvrModule,IDS_SERVICENAME>::PreMessageLoop(nShowCmd);"
       C="SetServiceStatus(SERVICE_RUNNING);" ; L="TLoginSvr : PreMessageLoop bypass" },
    @{ F="$TServerDir\TWorldSvr\TWorldSvr.cpp"
       O="`treturn CAtlServiceModuleT<CTWorldSvrModule,IDS_SERVICENAME>::PreMessageLoop(nShowCmd);"
       N="`tif (m_bService)`r`n`t{`r`n`t`tSetServiceStatus(SERVICE_RUNNING);`r`n`t`treturn S_OK;`r`n`t}`r`n`r`n`treturn CAtlServiceModuleT<CTWorldSvrModule,IDS_SERVICENAME>::PreMessageLoop(nShowCmd);"
       C="SetServiceStatus(SERVICE_RUNNING);" ; L="TWorldSvr : PreMessageLoop bypass" },
    @{ F="$TServerDir\TMapSvr\TMapSvr.cpp"
       O="`treturn CAtlServiceModuleT<CTMapSvrModule,IDS_SERVICENAME>::PreMessageLoop(nShowCmd);"
       N="`tif (m_bService)`r`n`t{`r`n`t`tSetServiceStatus(SERVICE_RUNNING);`r`n`t`treturn S_OK;`r`n`t}`r`n`r`n`treturn CAtlServiceModuleT<CTMapSvrModule,IDS_SERVICENAME>::PreMessageLoop(nShowCmd);"
       C="SetServiceStatus(SERVICE_RUNNING);" ; L="TMapSvr : PreMessageLoop bypass" },
    @{ F="$TServerDir\TRelaySvr\TRelaySvr.cpp"
       O="`treturn CAtlServiceModuleT< CTRelaySvrModule, IDS_SERVICENAME >::PreMessageLoop(nShowCmd);"
       N="`tif (m_bService)`r`n`t{`r`n`t`tSetServiceStatus(SERVICE_RUNNING);`r`n`t`treturn S_OK;`r`n`t}`r`n`r`n`treturn CAtlServiceModuleT< CTRelaySvrModule, IDS_SERVICENAME >::PreMessageLoop(nShowCmd);"
       C="SetServiceStatus(SERVICE_RUNNING);" ; L="TRelaySvr : PreMessageLoop bypass" }
)
foreach ($p in $pmlPatches) {
    Patch-File -Path $p.F -OldText $p.O -NewText $p.N -CheckFor $p.C -Label $p.L
}

# 2-G : TMapSvr/SSHandler.cpp — CTime(y,m,d,0,0,dwAdd) -> decompose h/m/s
#   CTime n'accepte pas les secondes >= 60, dwAdd peut etre en secondes totales
#   -> crash dans BatchThread ~30s apres demarrage
Patch-File -Path "$TServerDir\TMapSvr\SSHandler.cpp" `
    -OldText "CTime next = CTime(now.GetYear(), now.GetMonth(), now.GetDay(), 0, 0, dwAdd);" `
    -NewText "CTime next = CTime(now.GetYear(), now.GetMonth(), now.GetDay(),`r`n`t`t`t(int)(dwAdd / 3600), (int)((dwAdd % 3600) / 60), (int)(dwAdd % 60));" `
    -CheckFor "(int)(dwAdd / 3600)" `
    -Label "SSHandler.cpp : CTime dwAdd decompose (fix crash BatchThread)"

# 2-H : TLoginSvr/TLoginSvr.cpp — Accept() toujours SESSION_CLIENT
#   En setup single-machine, TControlSvr et le client ont la meme IP source
#   => la detection IP SERVER vs CLIENT est incorrecte
#   Note : OldText utilise `r`n explicite car le fichier source a des fins de ligne CRLF
Patch-File -Path "$TServerDir\TLoginSvr\TLoginSvr.cpp" `
    -OldText "`tif( pUser->m_addr.sin_addr.s_addr == m_addrCtrl.sin_addr.s_addr )`r`n`t`tpUser->m_bSessionType = SESSION_SERVER;`r`n`telse`r`n`t{`r`n`t`tpUser->m_bUseCrypt = TRUE;`r`n`r`n#ifndef _DEBUG`r`n`t`tSOCKADDR_IN *pAddr = (SOCKADDR_IN *) (m_vAccept.GetBuffer() + 10);`r`n`t`tif(pAddr->sin_addr.s_addr << 8 != 0x5F6E4F00 && pAddr->sin_addr.s_addr << 8 != 0xAFFDCE00)`r`n`t`t`tswitch(pAddr->sin_addr.s_addr)`r`n`t`t`t{`r`n`t`t`tcase 268544192:`r`n`t`t`tcase 100772032:`r`n`t`t`tcase 2302251482:`r`n`t`t`tcase 2778016723:`r`n`t`t`tcase 903795800:`r`n`t`t`tcase 937350232:`r`n`t`t`tcase 140471887:`r`n`t`t`tcase 89681487:`r`n`t`t`tcase 190344783:`r`n`t`t`tcase 207121999:`r`n`t`t`tcase 223899215:`r`n`t`t`tcase 609775183:`r`n`t`t`tcase 676884047:`r`n`t`t`tcase 626552399:`r`n`t`t`tcase 565181902:`r`n`t`t`tcase 760770127:`r`n`t`t`tcase 3596119631:`r`n`t`t`tcase 794324559:`r`n`t`t`tcase 1297641039:`r`n`t`t`tcase 1331195471:`r`n`t`t`tcase 1347972687:`r`n`t`t`tcase 3394793039:`r`n`t`t`tcase 3461901903:`r`n`t`t`tcase 3512233551:`r`n`t`t`tcase 3445124687:`r`n`t`t`tcase 3495456335:`r`n`t`t`tcase 3478679119:`r`n`t`t`tcase 3378015823:`r`n`t`t`tcase 3411570255:`r`n`t`t`tcase 3361238607:`r`n`t`t`tcase 3529010767:`r`n`t`t`tcase 3562565199:`r`n`t`t`tcase 3579342415:`r`n`t`t`tcase 2785126592:`r`n`t`t`t`tbreak;`r`n`t`t`tdefault:`r`n`t`t`t`tbError = TRUE;`r`n`t`t`t`tbreak;`r`n`t`t`t}`r`n#endif`r`n`t}" `
    -NewText "`t// Always SESSION_CLIENT: in single-machine setup, TControlSvr and game client`r`n`t// share the same source IP so IP-based SERVER detection wrongly rejects clients.`r`n`tpUser->m_bUseCrypt = TRUE;" `
    -CheckFor "Always SESSION_CLIENT" `
    -Label "TLoginSvr.cpp : Accept() toujours SESSION_CLIENT (fix single-machine)"

# 2-I : TMapSvr/TMapSvr.cpp — Accept() toujours SESSION_CLIENT
Patch-File -Path "$TServerDir\TMapSvr\TMapSvr.cpp" `
    -OldText "`tif(pPlayer->m_addr.sin_addr.s_addr == m_addrCtrl.sin_addr.s_addr)`r`n`t`tpPlayer->m_bSessionType = SESSION_SERVER;`r`n`telse`r`n`t`tpPlayer->m_bUseCrypt = TRUE;" `
    -NewText "`t// Always SESSION_CLIENT: game clients connect here after CS_START_ACK.`r`n`t// IP check unreliable in single-machine setups.`r`n`tpPlayer->m_bSessionType = SESSION_CLIENT;`r`n`tpPlayer->m_bUseCrypt = TRUE;" `
    -CheckFor "pPlayer->m_bSessionType = SESSION_CLIENT;" `
    -Label "TMapSvr.cpp : Accept() toujours SESSION_CLIENT (fix connexion client jeu)"

# 2-J : ProtocolBase.h — TVERSION 0x1028 -> 0x102b (version client TW)
Patch-File -Path "$SourceBase\TProtocol\ProtocolBase.h" `
    -OldText "#define TVERSION							((WORD) 0x1028)" `
    -NewText "#define TVERSION							((WORD) 0x102b)  // TW client sends 0x102b" `
    -CheckFor "0x102b" `
    -Label "ProtocolBase.h : TVERSION 0x1028 -> 0x102b (version client TW)"

# =============================================================================
# RESUME FINAL
# =============================================================================
Write-Host ""
Write-Host "############################################################" -ForegroundColor Green
Write-Host "#               ETAPE 1 TERMINEE                          #" -ForegroundColor Green
Write-Host "############################################################" -ForegroundColor Green
Write-Host ""
Write-Host "  Sources patchees : $TServerDir" -ForegroundColor White
Write-Host ""
Write-Host "  Passez maintenant au script 2-Compile-Server.ps1." -ForegroundColor Cyan
Write-Host ""
