# =============================================================================
# 2-Compile-Server.ps1
# 4Story - Compilation du serveur
#
#   1. Recherche de Visual Studio 2017 + MSBuild
#   2. Compilation : TNetLib + TControlSvr + TLoginSvr + TWorldSvr + TMapSvr + TRelaySvr
#   3. Collecte des binaires -> C:\TServices_4s\
#
# Prerequis : avoir execute 1-Prepare-Sources.ps1 (migration + patches appliques)
# =============================================================================

#Requires -RunAsAdministrator
$ErrorActionPreference = "Stop"

$SourceBase   = Split-Path -Parent $PSScriptRoot
$TServerDir   = "$SourceBase\TServer"
$TServerSln   = "$TServerDir\TServer.sln"
$Destination  = "C:\TServices_4s"

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

function Find-WindowsSDK {
    $sdkRoot = "${env:ProgramFiles(x86)}\Windows Kits\10\Include"
    if (-not (Test-Path $sdkRoot)) { return $null }
    $latest = Get-ChildItem $sdkRoot -Directory |
              Where-Object { $_.Name -match '^\d+\.\d+\.\d+\.\d+$' } |
              Sort-Object { [version]$_.Name } |
              Select-Object -Last 1
    if ($latest) { return $latest.Name }
    return $null
}

function Invoke-MSBuild {
    param(
        [string]$MSBuild,
        [string]$Solution,
        [string]$Project  = "",
        [string]$Config   = "Release",
        [string]$Platform = "Win32"
    )
    $logFile = "$env:TEMP\4story_build.log"
    $msbuildArgs = @(
        "`"$Solution`"",
        "/p:Configuration=$Config",
        "/p:Platform=$Platform",
        "/m",
        "/nologo",
        "/v:minimal",
        "/flp:LogFile=`"$logFile`";Verbosity=normal;Append"
    )
    $sdk = Find-WindowsSDK
    if ($sdk) { $msbuildArgs += "/p:WindowsTargetPlatformVersion=$sdk" }

    if ($Project) {
        $msbuildArgs += "/t:${Project}:Rebuild"
    } else {
        $msbuildArgs += "/t:Rebuild"
    }

    Write-Info "Compilation : $Project ($Config|$Platform)"

    $proc = Start-Process -FilePath $MSBuild -ArgumentList $msbuildArgs -Wait -PassThru -NoNewWindow
    if ($proc.ExitCode -ne 0) {
        Write-Err "Echec de $Project (code $($proc.ExitCode))"
        Write-Warn "Log : $logFile"
        # Afficher les erreurs
        if (Test-Path $logFile) {
            Get-Content $logFile | Where-Object { $_ -match ': error C|: error LNK|: fatal error' } |
                Select-Object -Last 10 | ForEach-Object { Write-Host "    $_" -ForegroundColor Red }
        }
        throw "MSBuild failed for '$Project'"
    }
    Write-OK "Compile : $Project"
}

# =============================================================================
# DEBUT
# =============================================================================
Write-Host ""
Write-Host "############################################################" -ForegroundColor Cyan
Write-Host "#       4Story - Etape 2 : Compilation du serveur         #" -ForegroundColor Cyan
Write-Host "############################################################" -ForegroundColor Cyan

# =============================================================================
# 1. Verification pre-requis
# =============================================================================
Write-Step 1 "Verification des pre-requis"

if (-not (Test-Path $TServerSln)) {
    Write-Err "Solution introuvable : $TServerSln"
    Write-Warn "Assurez-vous d'avoir execute le script 1-Prepare-Sources.ps1."
    exit 1
}

$vcxExists = Test-Path "$TServerDir\TNetLib\TNetLib.vcxproj"
if (-not $vcxExists) {
    Write-Err "TNetLib.vcxproj introuvable - la migration VS2005->VS2017 n'a pas ete effectuee."
    Write-Warn "Executez d'abord 1-Prepare-Sources.ps1."
    exit 1
}

$vsPath = Find-VS2017
if (-not $vsPath) {
    Write-Err "Visual Studio 2017 introuvable."
    Write-Warn "Installez VS 2017 avec 'Desktop development with C++' (MFC + ATL inclus)."
    exit 1
}
Write-OK "Visual Studio 2017 : $vsPath"

$MSBuild = "$vsPath\MSBuild\15.0\Bin\MSBuild.exe"
if (-not (Test-Path $MSBuild)) { Write-Err "MSBuild introuvable dans $vsPath" ; exit 1 }
Write-OK "MSBuild : $MSBuild"

$sdk = Find-WindowsSDK
if ($sdk) { Write-OK "Windows SDK : $sdk" }
else       { Write-Warn "Windows SDK non detecte - la compilation pourrait echouer." }

Remove-Item "$env:TEMP\4story_build.log" -ErrorAction SilentlyContinue

# =============================================================================
# 1b. Suppression des PostBuildEvent (/RegServer) dans les .vcxproj
#     Le post-build tente de lancer l'EXE en mode /RegServer pendant le build,
#     ce qui echoue systematiquement (code 9009) et fait echouer MSBuild.
#     L'enregistrement COM est gere par le script 5-Registry-Services.ps1.
# =============================================================================
Write-Info "Suppression des PostBuildEvent dans les .vcxproj..."
foreach ($srv in @('TControlSvr','TLoginSvr','TWorldSvr','TMapSvr','TRelaySvr')) {
    $vcx = "$TServerDir\$srv\$srv.vcxproj"
    if (-not (Test-Path $vcx)) { continue }
    [xml]$xml = Get-Content $vcx -Encoding UTF8
    $changed = $false
    foreach ($idg in $xml.Project.ItemDefinitionGroup) {
        if ($idg.PostBuildEvent) {
            $idg.RemoveChild($idg.PostBuildEvent) | Out-Null
            $changed = $true
        }
    }
    if ($changed) { $xml.Save($vcx); Write-OK "  $srv.vcxproj : PostBuildEvent supprime" }
}

# =============================================================================
# 2. Compilation
# =============================================================================
Write-Step 2 "Compilation (TNetLib + 5 serveurs)"

# TNetLib en premier (les serveurs en dependent)
Invoke-MSBuild -MSBuild $MSBuild -Solution $TServerSln -Project "TNetLib"

$libFile = Get-ChildItem $TServerDir -Recurse -Filter "TNetLib.lib" -ErrorAction SilentlyContinue | Select-Object -First 1
if ($libFile) { Write-OK "TNetLib.lib : $($libFile.FullName)" }
else          { Write-Err "TNetLib.lib introuvable apres compilation." ; exit 1 }

# Serveurs
$buildErrors = @()
foreach ($project in @("TControlSvr","TLoginSvr","TWorldSvr","TMapSvr","TRelaySvr")) {
    try {
        Invoke-MSBuild -MSBuild $MSBuild -Solution $TServerSln -Project $project
    } catch {
        Write-Warn "Echec de $project - passage au suivant."
        $buildErrors += $project
    }
}

if ($buildErrors.Count -gt 0) {
    Write-Warn "Projets en echec : $($buildErrors -join ', ')"
} else {
    Write-OK "Tous les projets compiles avec succes."
}

# =============================================================================
# 3. Collecte des binaires -> $Destination
# =============================================================================
Write-Step 3 "Collecte des binaires -> $Destination"

if (Test-Path $Destination) {
    Write-Warn "$Destination existe deja - arret des services en cours..."
    foreach ($svc in @('TMapSvr','TRelaySvr','TWorldSvr','TLoginSvr','TControlSvr')) {
        $s = Get-Service $svc -ErrorAction SilentlyContinue
        if ($s -and $s.Status -eq 'Running') {
            Stop-Service $svc -Force
            Write-Info "  Service $svc arrete."
        }
    }
    Start-Sleep -Seconds 2
    Remove-Item $Destination -Recurse -Force
}
New-Item -ItemType Directory -Path $Destination -Force | Out-Null

# Chercher les EXEs dans le dossier Services (sortie Release configuree dans les .vcxproj)
$servicesDir = "$TServerDir\Services"
if (Test-Path $servicesDir) {
    Get-ChildItem "$servicesDir\*" -Include "*.exe","*.dll" -File | ForEach-Object {
        Copy-Item $_.FullName -Destination $Destination -Force
        Write-OK "  $($_.Name)"
    }
}

# Fallback : recherche recursive dans les dossiers Release
$collected = Get-ChildItem $Destination -ErrorAction SilentlyContinue
if (-not $collected -or $collected.Count -eq 0) {
    Write-Info "Recherche recursive des EXEs dans les dossiers Release..."
    Get-ChildItem $TServerDir -Recurse -Include "*.exe","*.dll" |
        Where-Object { $_.DirectoryName -like "*Release*" -and $_.DirectoryName -notlike "*Debug*" } |
        ForEach-Object {
            Copy-Item $_.FullName -Destination $Destination -Force
            Write-Info "  $($_.Name) <- $($_.DirectoryName)"
        }
}

Write-Host ""
Write-Info "Contenu de $Destination :"
Get-ChildItem $Destination -ErrorAction SilentlyContinue | ForEach-Object { Write-Host "    $($_.Name)" -ForegroundColor Gray }

$required = @("TControlSvr.exe","TLoginSvr.exe","TWorldSvr.exe","TMapSvr.exe","TRelaySvr.exe")
$missing  = $required | Where-Object { -not (Test-Path "$Destination\$_") }
if ($missing) {
    Write-Warn "Executables manquants : $($missing -join ', ')"
    Write-Warn "Log de build : $env:TEMP\4story_build.log"
} else {
    Write-OK "Tous les executables serveur presents dans $Destination."
}

# =============================================================================
# RESUME FINAL
# =============================================================================
Write-Host ""
Write-Host "############################################################" -ForegroundColor Green
Write-Host "#               ETAPE 2 TERMINEE                          #" -ForegroundColor Green
Write-Host "############################################################" -ForegroundColor Green
Write-Host ""
Write-Host "  Binaires serveur : $Destination" -ForegroundColor White
Write-Host "  Log de build     : $env:TEMP\4story_build.log" -ForegroundColor White
Write-Host ""
Write-Host "  Passez maintenant au script 3-SQLServer-Database.ps1." -ForegroundColor Cyan
Write-Host ""
