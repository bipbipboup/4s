# =============================================================================
# 6-Compile-Client.ps1
# 4Story 3.5 - Compilation du client depuis C:\4Story_3.5_Source\4s\TClient
#
#   1. Upgrade TClient.sln VS2005 -> VS2017
#   2. Ajout chemins DX SDK + patches dans les .vcxproj
#   3. Compilation : Engine Lib -> TComp -> TCML -> TachyonControl -> TChart -> TClient -> TLoader
#   4. Collecte des binaires -> C:\TClient_35\
#
# Prerequis : Visual Studio 2017 installe
# =============================================================================

#Requires -RunAsAdministrator
$ErrorActionPreference = "Stop"

$SourceBase    = Split-Path -Parent $PSScriptRoot
$TClientDir    = "$SourceBase\TClient"
$TClientSln    = "$TClientDir\TClient.sln"
$DXInclude     = "$SourceBase\Includes\DX\Include"
$DXLib         = "$SourceBase\Includes\DX\Lib"
$PatchesDir    = "$TClientDir\Patches"
$Destination   = "C:\TClient_35"
$BuildConfig   = "Release"
$BuildPlatform = "Win32"

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
        [string]$Project,
        [string]$Config   = $BuildConfig,
        [string]$Platform = $BuildPlatform
    )
    $logFile = "$env:TEMP\4story_client35_build.log"
    $name = [System.IO.Path]::GetFileNameWithoutExtension($Project)
    $msbuildArgs = @(
        "`"$Project`"",
        "/p:Configuration=$Config",
        "/p:Platform=$Platform",
        "/t:Rebuild",
        "/m",
        "/nologo",
        "/v:minimal",
        "/flp:LogFile=`"$logFile`";Verbosity=normal;Append"
    )
    $sdk = Find-WindowsSDK
    if ($sdk) { $msbuildArgs += "/p:WindowsTargetPlatformVersion=$sdk" }

    Write-Info "Compilation : $name ($Config|$Platform)"

    $proc = Start-Process -FilePath $MSBuild -ArgumentList $msbuildArgs -Wait -PassThru -NoNewWindow
    if ($proc.ExitCode -ne 0) {
        Write-Err "Echec de $name (code $($proc.ExitCode))"
        Write-Warn "Log : $logFile"
        if (Test-Path $logFile) {
            Get-Content $logFile | Where-Object { $_ -match ': error C|: error LNK|: fatal error' } |
                Select-Object -Last 15 | ForEach-Object { Write-Host "    $_" -ForegroundColor Red }
        }
        throw "MSBuild failed for '$name'"
    }
    Write-OK "Compile : $name"
}

function Add-XmlPath {
    param([string]$VcxPath, [string]$Element, [string]$NewPath)
    $txt = [System.IO.File]::ReadAllText($VcxPath)
    if ($txt -like "*$NewPath*") { return $false }

    $pattern = "(<$Element>)"
    if ($txt -match $pattern) {
        $txt = $txt -replace "(<$Element>)", "`$1$NewPath;"
        [System.IO.File]::WriteAllText($VcxPath, $txt)
        return $true
    }

    $parentTag = if ($Element -eq "AdditionalIncludeDirectories") { "ClCompile" } else { "Link" }
    $insertAfter = "<$parentTag>"
    if ($txt -match [regex]::Escape($insertAfter)) {
        $replacement = "$insertAfter`r`n      <$Element>$NewPath;%($Element)</$Element>"
        $txt = $txt.Replace($insertAfter, $replacement)
        [System.IO.File]::WriteAllText($VcxPath, $txt)
        return $true
    }
    return $false
}

# =============================================================================
# DEBUT
# =============================================================================
Write-Host ""
Write-Host "############################################################" -ForegroundColor Cyan
Write-Host "#    4Story 3.5 - Etape 6 : Compilation du client         #" -ForegroundColor Cyan
Write-Host "############################################################" -ForegroundColor Cyan

if (-not (Test-Path $TClientSln)) {
    Write-Err "Solution introuvable : $TClientSln"
    exit 1
}

$vsPath = Find-VS2017
if (-not $vsPath) {
    Write-Err "Visual Studio 2017 introuvable."
    exit 1
}
Write-OK "Visual Studio 2017 : $vsPath"

$MSBuild = "$vsPath\MSBuild\15.0\Bin\MSBuild.exe"
if (-not (Test-Path $MSBuild)) { Write-Err "MSBuild introuvable." ; exit 1 }
Write-OK "MSBuild : $MSBuild"

$DevEnv = "$vsPath\Common7\IDE\devenv.exe"

Remove-Item "$env:TEMP\4story_client35_build.log" -ErrorAction SilentlyContinue
New-Item -ItemType Directory -Path $PatchesDir -Force | Out-Null

# =============================================================================
# 1. Upgrade VS2005 -> VS2017
# =============================================================================
Write-Step 1 "Upgrade de la solution VS2005 -> VS2017"

$engineLibVcxproj = "$TClientDir\TEngine\Engine Lib\Engine Lib.vcxproj"
if (-not (Test-Path $engineLibVcxproj)) {
    Write-Info "Conversion en cours (peut prendre 1-2 min)..."
    $proc = Start-Process -FilePath $DevEnv -ArgumentList @("`"$TClientSln`"", "/upgrade") -Wait -PassThru -NoNewWindow
    if ($proc.ExitCode -ne 0) {
        Write-Warn "devenv /upgrade code $($proc.ExitCode) - on continue quand meme"
    }
    Start-Sleep -Seconds 5
    if (Test-Path $engineLibVcxproj) {
        Write-OK "Upgrade termine. Fichiers .vcxproj generes."
    } else {
        Write-Err "Upgrade echoue : Engine Lib.vcxproj absent."
        exit 1
    }
} else {
    Write-OK "Solution deja convertie (.vcxproj present)."
}

# =============================================================================
# 2. Creation des headers stubs dans Patches/
# =============================================================================
Write-Step "2" "Creation des headers stubs dans Patches/"

$sdkVer  = Find-WindowsSDK
$sdkBase = "${env:ProgramFiles(x86)}\Windows Kits\10\Include\$sdkVer"

function Write-StubHeader {
    param([string]$File, [string]$Content)
    if (-not (Test-Path $File)) {
        [System.IO.File]::WriteAllText($File, $Content)
        Write-OK "  Cree : $(Split-Path $File -Leaf)"
    } else {
        Write-Info "  Deja present : $(Split-Path $File -Leaf)"
    }
}

Write-StubHeader "$PatchesDir\basetsd.h" @"
// basetsd.h - redirect to Windows SDK (avoids old DX SDK version with missing POINTER_64)
#pragma once
#include "$sdkBase\shared\basetsd.h"
"@

Write-StubHeader "$PatchesDir\sal.h" @"
// sal.h - redirect to Windows SDK SAL2 annotations
#pragma once
#include "$sdkBase\shared\sal.h"
"@

Write-StubHeader "$PatchesDir\DXGIFormat.h" @"
#pragma once
#include "$sdkBase\shared\dxgiformat.h"
"@

Write-StubHeader "$PatchesDir\DXGIType.h" @"
#pragma once
#include "$sdkBase\shared\dxgitype.h"
"@

Write-StubHeader "$PatchesDir\DXGI.h" @"
#pragma once
#include "$sdkBase\shared\dxgi.h"
"@

Write-StubHeader "$PatchesDir\afxisapi.h" @"
// afxisapi.h - stub (MFC ISAPI extension removed in VS2017, not needed for this code)
#pragma once
"@

# 4s_client_pre_include.h
$preInclude = "$TClientDir\4s_client_pre_include.h"
$preIncContent = @"
// 4s_client_pre_include.h
// Pre-include force pour compatibilite VS2017 / Windows 10 SDK

// Cible Windows XP+ minimum
#ifndef _WIN32_WINNT
#define _WIN32_WINNT 0x0501
#endif
#ifndef WINVER
#define WINVER 0x0501
#endif

// MFC CX_BORDER/CY_BORDER renommes AFX_CX_BORDER en VS2017
#ifndef CX_BORDER
#define CX_BORDER 1
#endif
#ifndef CY_BORDER
#define CY_BORDER 1
#endif
"@
if (-not (Test-Path $preInclude) -or
    ([System.IO.File]::ReadAllText($preInclude) -notmatch "CX_BORDER")) {
    [System.IO.File]::WriteAllText($preInclude, $preIncContent)
    Write-OK "  4s_client_pre_include.h cree/mis a jour"
} else {
    Write-Info "  4s_client_pre_include.h : deja a jour"
}

# =============================================================================
# 2b. Compiler hackshield_stub.lib
# =============================================================================
Write-Step "2b" "Compilation de hackshield_stub.lib"

$stubC = "$PatchesDir\hackshield_stub.c"
$stubCContent = @'
// hackshield_stub.c - stubs pour fonctions anti-cheat manquantes
// Compile avec /TP (C++) pour gerer les deux types de mangling :
//   - HackShield/APex : extern "C" + __stdcall -> decoration C (@N)
//   - XTrap           : __cdecl C++ -> mangling C++ (?...)

extern "C" {
// HackShield
int __stdcall _AhnHS_InitializeA(const char* a, void* b, int c, const char* d, unsigned int e, unsigned int f) { return 0; }
int __stdcall _AhnHS_StartService(void)  { return 0; }
int __stdcall _AhnHS_StopService(void)   { return 0; }
int __stdcall _AhnHS_Uninitialize(void)  { return 0; }
int __stdcall _AhnHS_MakeResponse(unsigned char* a, unsigned long b, void* c) { return 0; }
// HSUpdateExA : la fonction attend 804 octets de parametres (__stdcall = callee clean)
#pragma comment(linker, "/alternatename:__AhnHS_HSUpdateExA@804=__AhnHS_HSUpdateExA@0")
__declspec(naked) void __stdcall _AhnHS_HSUpdateExA(void)
{
    __asm
    {
        xor eax, eax
        ret 804
    }
}
// APex
long __stdcall CHCStart(void* a, void* b) { return 0; }
long __stdcall CHCEnd(void)               { return 0; }
} // extern "C"

// XTrap - appele depuis du code C++ sans extern "C" -> mangling C++
void __cdecl XTrap_C_Start(const char* a, const char* b) { (void)a; (void)b; }
void __cdecl XTrap_C_KeepAlive(void) {}
void __cdecl XTrap_C_SetUserInfo(const char* a, const char* b, const char* c, const char* d, unsigned long e) { (void)a; (void)b; (void)c; (void)d; (void)e; }
'@
[System.IO.File]::WriteAllText($stubC, $stubCContent)

$msvcToolsDir = Get-ChildItem "$vsPath\VC\Tools\MSVC" -Directory |
                Sort-Object Name | Select-Object -Last 1
if (-not $msvcToolsDir) {
    Write-Warn "  cl.exe introuvable - hackshield_stub.lib non compile"
} else {
    $clExe   = "$($msvcToolsDir.FullName)\bin\HostX86\x86\cl.exe"
    $libExe  = "$($msvcToolsDir.FullName)\bin\HostX86\x86\lib.exe"
    $msvcInc = "$($msvcToolsDir.FullName)\include"
    $msvcLib = "$($msvcToolsDir.FullName)\lib\x86"
    $ucrtInc  = "$sdkBase\ucrt"
    $sharedInc = "$sdkBase\shared"
    $umInc    = "$sdkBase\um"
    $ucrtLib  = "${env:ProgramFiles(x86)}\Windows Kits\10\Lib\$sdkVer\ucrt\x86"
    $umLib    = "${env:ProgramFiles(x86)}\Windows Kits\10\Lib\$sdkVer\um\x86"

    $env:INCLUDE = "$msvcInc;$ucrtInc;$sharedInc;$umInc"
    $env:LIB     = "$msvcLib;$ucrtLib;$umLib"
    $env:PATH   += ";$($msvcToolsDir.FullName)\bin\HostX86\x86"

    $savedEAP = $ErrorActionPreference
    $ErrorActionPreference = "Continue"
    $clOut = & $clExe /c /W0 /MT /TP /Fo"$PatchesDir\hackshield_stub.obj" $stubC 2>&1
    $clExit = $LASTEXITCODE
    if ($clExit -eq 0) {
        $libOut = & $libExe /OUT:"$PatchesDir\hackshield_stub.lib" "$PatchesDir\hackshield_stub.obj" 2>&1
        $libExit = $LASTEXITCODE
        if ($libExit -eq 0) { Write-OK "  hackshield_stub.lib cree" }
        else { Write-Err "  lib.exe echec ($libExit)" }
    } else {
        Write-Err "  cl.exe echec ($clExit) - hackshield_stub.lib non cree"
    }
    $ErrorActionPreference = $savedEAP
}

# =============================================================================
# 3. Patch des .vcxproj : DX SDK + ForcedIncludeFiles
# =============================================================================
Write-Step 3 "Patch des .vcxproj : chemins DX SDK + pre-include"

$projectsToFix = @(
    "$TClientDir\TEngine\Engine Lib\Engine Lib.vcxproj",
    "$TClientDir\TEngine\TachyonControl\TachyonControl.vcxproj",
    "$TClientDir\TEngine\TComp\TComp.vcxproj",
    "$TClientDir\TEngine\TCML\TCML.vcxproj",
    "$TClientDir\TChart\TChart.vcxproj",
    "$TClientDir\TClient\TClient.vcxproj"
)

foreach ($vcx in $projectsToFix) {
    if (-not (Test-Path $vcx)) { Write-Warn "  Absent : $vcx" ; continue }
    $name = Split-Path $vcx -Leaf

    $txt = [System.IO.File]::ReadAllText($vcx)
    $changed = $false

    if ($txt -notlike "*4s_client_pre_include*") {
        $txt = $txt -replace '(<ClCompile>)', "`$1`r`n      <ForcedIncludeFiles>$preInclude;%(ForcedIncludeFiles)</ForcedIncludeFiles>"
        $changed = $true
        Write-OK "  $name : ForcedIncludeFiles ajoute"
    } else {
        Write-Info "  $name : ForcedIncludeFiles deja present"
    }

    if ($changed) { [System.IO.File]::WriteAllText($vcx, $txt) }

    $r = Add-XmlPath -VcxPath $vcx -Element "AdditionalIncludeDirectories" -NewPath $DXInclude
    if ($r) { Write-OK "  $name : DX Include ajoute" }
    else     { Write-Info "  $name : DX Include deja present" }

    $r2 = Add-XmlPath -VcxPath $vcx -Element "AdditionalIncludeDirectories" -NewPath $PatchesDir
    if ($r2) { Write-OK "  $name : Patches dir ajoute" }
    else      { Write-Info "  $name : Patches dir deja present" }
}

# DX Lib + corrections TClient.vcxproj
$vcxClient = "$TClientDir\TClient\TClient.vcxproj"
if (Test-Path $vcxClient) {
    $txt = [System.IO.File]::ReadAllText($vcxClient)
    $changed = $false

    # DX Lib
    $r = Add-XmlPath -VcxPath $vcxClient -Element "AdditionalLibraryDirectories" -NewPath $DXLib
    if ($r) { Write-OK "  TClient.vcxproj : DX Lib ajoute" }
    else     { Write-Info "  TClient.vcxproj : DX Lib deja present" }

    # Retirer AHClientInterface.lib
    $txt = [System.IO.File]::ReadAllText($vcxClient)
    if ($txt -match "AHClientInterface\.lib") {
        $txt = $txt -replace ";?AHClientInterface\.lib", ""
        $changed = $true
        Write-OK "  TClient.vcxproj : AHClientInterface.lib retire"
    }

    # Retirer HShield et HSUpChk
    if ($txt -match "HShield\.lib") {
        $txt = $txt -replace ";?\.\.\\\.\.\\HShield\\Lib\\Win\\x86\\Multithreaded\\[^;`"<]+", ""
        $txt = $txt -replace ";?HShield\.lib", ""
        $txt = $txt -replace ";?HSUpChk\.lib", ""
        $changed = $true
        Write-OK "  TClient.vcxproj : HShield.lib retire"
    }

    # Retirer XTrap
    if ($txt -match "XTrap4Client_mt\.lib") {
        $txt = $txt -replace ";?XTrap4Client_mt\.lib", ""
        $changed = $true
        Write-OK "  TClient.vcxproj : XTrap4Client_mt.lib retire"
    }

    # Ajouter hackshield_stub.lib + legacy_stdio_definitions.lib apres NPGameLib.lib
    if ($txt -notmatch "hackshield_stub\.lib") {
        $txt = $txt -replace "(NPGameLib\.lib;?)", '$1hackshield_stub.lib;legacy_stdio_definitions.lib;'
        $changed = $true
        Write-OK "  TClient.vcxproj : hackshield_stub.lib + legacy_stdio_definitions.lib ajoutes"
    }

    # Ajouter Patches au libpath
    if ($txt -notmatch [regex]::Escape($PatchesDir)) {
        $txt = $txt -replace "(<AdditionalLibraryDirectories>[^<]*)(TEngine\\Lib|\.\.\\TEngine\\Lib)", "`$1`$2;$PatchesDir"
        $changed = $true
        Write-OK "  TClient.vcxproj : Patches ajoute au libpath"
    }

    # SAFESEH:NO
    if ($txt -notmatch "ImageHasSafeExceptionHandlers") {
        $txt = $txt -replace "(<SubSystem>Windows</SubSystem>)", "`$1`r`n      <ImageHasSafeExceptionHandlers>false</ImageHasSafeExceptionHandlers>"
        $changed = $true
        Write-OK "  TClient.vcxproj : SAFESEH:NO ajoute"
    }

    # Retirer TProtocol ProjectReference (TProtocol n'a pas de config Release|Win32)
    if ($txt -match "TProtocol\.vcxproj") {
        $txt = $txt -replace "(?s)\s*<ProjectReference Include=""[^""]*TProtocol\.vcxproj""[^>]*>.*?</ProjectReference>", ""
        $changed = $true
        Write-OK "  TClient.vcxproj : TProtocol ProjectReference retire"
    } else {
        Write-Info "  TClient.vcxproj : TProtocol ProjectReference deja absent"
    }

    # Convertir FxCompile (.psh/.vsh DX8) -> None (HLSL compiler VS2017 ne supporte pas ces formats)
    if ($txt -match "<FxCompile") {
        $txt = $txt -replace "<FxCompile Include=""([^""]*\.(psh|vsh))""[^/]*/?>", '<None Include="$1" />'
        $txt = $txt -replace "</FxCompile>", "</None>"
        $changed = $true
        Write-OK "  TClient.vcxproj : FxCompile (.psh/.vsh) -> None"
    } else {
        Write-Info "  TClient.vcxproj : FxCompile deja absent"
    }

    if ($changed) { [System.IO.File]::WriteAllText($vcxClient, $txt) }
    else { Write-Info "  TClient.vcxproj : deja a jour" }
}

# =============================================================================
# 4. Patch _WIN32_WINNT dans Engine Lib/StdAfx.h
# =============================================================================
Write-Step 4 "Patch _WIN32_WINNT dans Engine Lib"

$stdAfxPath = "$TClientDir\TEngine\Engine Lib\StdAfx.h"
if (Test-Path $stdAfxPath) {
    $content = [System.IO.File]::ReadAllText($stdAfxPath)
    if ($content -notmatch "_WIN32_WINNT") {
        $newContent = $content -replace "(#define VC_EXTRALEAN)", "#ifndef _WIN32_WINNT`r`n#define _WIN32_WINNT 0x0501`r`n#endif`r`n`$1"
        [System.IO.File]::WriteAllText($stdAfxPath, $newContent)
        Write-OK "  StdAfx.h : _WIN32_WINNT 0x0501 ajoute"
    } else {
        Write-Info "  StdAfx.h : _WIN32_WINNT deja present"
    }
}

$tClientStdAfx = "$TClientDir\TClient\StdAfx.h"
if (Test-Path $tClientStdAfx) {
    $content = [System.IO.File]::ReadAllText($tClientStdAfx)
    if ($content -match "_WIN32_WINNT 0x0501") {
        Write-Info "  TClient/StdAfx.h : _WIN32_WINNT 0x0501 deja present"
    } elseif ($content -match "_WIN32_WINNT 0x0400") {
        $newContent = $content -replace "_WIN32_WINNT 0x0400", "_WIN32_WINNT 0x0501"
        [System.IO.File]::WriteAllText($tClientStdAfx, $newContent)
        Write-OK "  TClient/StdAfx.h : _WIN32_WINNT 0x0400 -> 0x0501"
    } elseif ($content -notmatch "_WIN32_WINNT") {
        $newContent = $content -replace "(#pragma once)", "`$1`r`n#ifndef _WIN32_WINNT`r`n#define _WIN32_WINNT 0x0501`r`n#endif"
        [System.IO.File]::WriteAllText($tClientStdAfx, $newContent)
        Write-OK "  TClient/StdAfx.h : _WIN32_WINNT 0x0501 ajoute"
    }
}

# =============================================================================
# 5. Correctifs C++ VS2017
# =============================================================================
Write-Step 5 "Correctifs C++ pour VS2017"

# TMiniDump.cpp : PSTR -> PCSTR
$miniDump = "$TClientDir\TClient\TMiniDump.cpp"
if (Test-Path $miniDump) {
    $txt = [System.IO.File]::ReadAllText($miniDump)
    if ($txt -match "EnumerateLoadedModulesProc\(PSTR ModuleName") {
        $txt = $txt -replace "EnumerateLoadedModulesProc\(PSTR ModuleName", "EnumerateLoadedModulesProc(PCSTR ModuleName"
        [System.IO.File]::WriteAllText($miniDump, $txt)
        Write-OK "  TMiniDump.cpp : PSTR -> PCSTR"
    } else { Write-Info "  TMiniDump.cpp : deja corrige" }
}

# TTextLinker.cpp : const refs sur iterateurs set
$textLinker = "$TClientDir\TClient\TTextLinker.cpp"
if (Test-Path $textLinker) {
    $txt = [System.IO.File]::ReadAllText($textLinker)
    $changed = $false
    # Le source original a "TComponent::TextSetting& vDATA" (pas de const)
    # On ajoute const sans dupliquer TComponent::
    if ($txt -match "TComponent::TextSetting& vDATA = \(\*it\)" -and $txt -notmatch "const TComponent::TextSetting& vDATA") {
        $txt = $txt -replace "TComponent::TextSetting& vDATA = \(\*it\)", "const TComponent::TextSetting& vDATA = (*it)"
        $changed = $true
    }
    if ($txt -match "TComponent::TextSetting& data = \*itr" -and $txt -notmatch "const TComponent::TextSetting& data") {
        $txt = $txt -replace "TComponent::TextSetting& data = \*itr", "const TComponent::TextSetting& data = *itr"
        $changed = $true
    }
    if ($changed) {
        [System.IO.File]::WriteAllText($textLinker, $txt)
        Write-OK "  TTextLinker.cpp : const refs corrigees"
    } else { Write-Info "  TTextLinker.cpp : deja corrige" }
}

# TComponent.cpp : const iterator + const_cast pour mutation
$tComp = "$TClientDir\TEngine\TComp\TComponent.cpp"
if (Test-Path $tComp) {
    $txt = [System.IO.File]::ReadAllText($tComp)
    $changed = $false
    if ($txt -match "TextSetting& data = \*itr;") {
        $txt = $txt.Replace("TextSetting& data = *itr;", "const TextSetting& data = *itr;")
        $changed = $true
    }
    if (-not ($txt -match [regex]::Escape("const_cast<TextSetting&>(data).iEnd = iStart - 1;"))) {
        if ($txt -match [regex]::Escape("data.iEnd = iStart - 1;")) {
            $txt = $txt.Replace("data.iEnd = iStart - 1;", "const_cast<TextSetting&>(data).iEnd = iStart - 1;")
            $changed = $true
        }
    }
    if (-not ($txt -match [regex]::Escape("const_cast<TextSetting&>(data).iStart = iEnd + 1;"))) {
        if ($txt -match [regex]::Escape("data.iStart = iEnd + 1;")) {
            $txt = $txt.Replace("data.iStart = iEnd + 1;", "const_cast<TextSetting&>(data).iStart = iEnd + 1;")
            $changed = $true
        }
    }
    if ($changed) {
        [System.IO.File]::WriteAllText($tComp, $txt)
        Write-OK "  TComponent.cpp : const iterator + const_cast"
    } else { Write-Info "  TComponent.cpp : deja corrige" }
}

# TEdit.cpp : const_cast pour mutation via iterateur set
$tEdit = "$TClientDir\TEngine\TComp\TEdit.cpp"
if (Test-Path $tEdit) {
    $txt = [System.IO.File]::ReadAllText($tEdit)
    $changed = $false
    if ($txt -match "itr->iStart \+= iCount;") {
        $txt = $txt.Replace("itr->iStart += iCount;", "const_cast<TextSetting&>(*itr).iStart += iCount;")
        $changed = $true
    }
    if ($txt -match "itr->iEnd \+= iCount;") {
        $txt = $txt.Replace("itr->iEnd += iCount;", "const_cast<TextSetting&>(*itr).iEnd += iCount;")
        $changed = $true
    }
    if ($changed) {
        [System.IO.File]::WriteAllText($tEdit, $txt)
        Write-OK "  TEdit.cpp : const_cast ajoute"
    } else { Write-Info "  TEdit.cpp : deja corrige" }
}

# TClient.cpp : bypass TClientMP.mpc check pour les nations avec anti-cheat tiers (APEX/XTrap)
# La condition originale ne couvre pas INSTALL_APEX -> le check .mpc s'execute pour TW
# et echoue car notre TClient.exe recompile ne correspond pas au .mpc original
$tClientMain = "$TClientDir\TClient\TClient.cpp"
if (Test-Path $tClientMain) {
    $txt = [System.IO.File]::ReadAllText($tClientMain)
    # Bypass complet du check TClientMP.mpc (inutile pour un serveur prive)
    $mpcBlock = 'if ( !CTNationOption::INSTALL_HACKSHIELD && !CTNationOption::INSTALL_GAMEGUARD'
    if ($txt -match [regex]::Escape($mpcBlock)) {
        $txt = $txt -replace '(?s)\s*if \( !CTNationOption::INSTALL_HACKSHIELD.*?TClientMP\.mpc check bypasse \(serveur prive.*?\)', "`r`n`t// TClientMP.mpc check bypasse (serveur prive - pas d'anti-tamper necessaire)"
        # Remplacement plus robuste : supprimer le bloc entier
        $pattern = '(?s)(#ifdef TEST_MODE\r?\n#else\r?\n)\s*if \( !CTNationOption::INSTALL_HACKSHIELD[^}]+\}\r?\n\t\}'
        if ($txt -match $pattern) {
            $txt = $txt -replace $pattern, ('$1' + "`t// TClientMP.mpc check bypasse (serveur prive)")
            [System.IO.File]::WriteAllText($tClientMain, $txt)
            Write-OK "  TClient.cpp : bypass TClientMP.mpc complet"
        } else {
            Write-Info "  TClient.cpp : bypass TClientMP.mpc (regex non matche - verifier manuellement)"
        }
    } else {
        Write-Info "  TClient.cpp : bypass TClientMP.mpc deja applique"
    }
}

# =============================================================================
# 6. Compilation
# =============================================================================
Write-Step 6 "Compilation"

$buildErrors = @()

$vcxEngineLib = "$TClientDir\TEngine\Engine Lib\Engine Lib.vcxproj"
$vcxTComp     = "$TClientDir\TEngine\TComp\TComp.vcxproj"
$vcxTCML      = "$TClientDir\TEngine\TCML\TCML.vcxproj"
$vcxTachCtrl  = "$TClientDir\TEngine\TachyonControl\TachyonControl.vcxproj"
$vcxTChart    = "$TClientDir\TChart\TChart.vcxproj"
$vcxTClient   = "$TClientDir\TClient\TClient.vcxproj"
$vcxTLoader   = "$TClientDir\TLoader\TLoader.vcxproj"

try {
    Invoke-MSBuild -MSBuild $MSBuild -Project $vcxEngineLib
} catch {
    Write-Err "Engine Lib echoue - impossible de continuer."
    exit 1
}

$engLibFile = "$TClientDir\TEngine\Lib\EngineLib.lib"
if (Test-Path $engLibFile) { Write-OK "EngineLib.lib : $engLibFile" }
else { Write-Warn "EngineLib.lib introuvable apres compilation" }

try {
    Invoke-MSBuild -MSBuild $MSBuild -Project $vcxTComp
} catch {
    Write-Err "TComp echoue - impossible de continuer."
    exit 1
}

try {
    Invoke-MSBuild -MSBuild $MSBuild -Project $vcxTCML
} catch {
    Write-Err "TCML echoue - impossible de continuer."
    exit 1
}

try {
    Invoke-MSBuild -MSBuild $MSBuild -Project $vcxTachCtrl
} catch {
    Write-Err "TachyonControl echoue - impossible de continuer."
    exit 1
}

try {
    Invoke-MSBuild -MSBuild $MSBuild -Project $vcxTChart
} catch {
    Write-Warn "TChart echoue - on continue"
    $buildErrors += "TChart"
}

try {
    Invoke-MSBuild -MSBuild $MSBuild -Project $vcxTClient
} catch {
    Write-Warn "TClient echoue"
    $buildErrors += "TClient"
}

try {
    Invoke-MSBuild -MSBuild $MSBuild -Project $vcxTLoader
} catch {
    Write-Warn "TLoader echoue (non bloquant)"
    $buildErrors += "TLoader"
}

# =============================================================================
# 7. Collecte des binaires -> $Destination
# =============================================================================
Write-Step 7 "Collecte des binaires -> $Destination"

New-Item -ItemType Directory -Path $Destination -Force | Out-Null

$searchPaths = @(
    "$TClientDir\TClient\Exec",
    "$TClientDir\TClient\Release",
    "$TClientDir\TClient\$BuildConfig",
    "$TClientDir\TLoader\Release",
    "$TClientDir\TLoader\$BuildConfig"
)

foreach ($dir in $searchPaths) {
    if (-not (Test-Path $dir)) { continue }
    Get-ChildItem "$dir\*" -Include "*.exe","*.dll" -File | ForEach-Object {
        Copy-Item $_.FullName -Destination $Destination -Force
        Write-OK "  $($_.Name)"
    }
}

$collected = Get-ChildItem $Destination -ErrorAction SilentlyContinue
if (-not $collected -or $collected.Count -eq 0) {
    Write-Info "Recherche recursive..."
    Get-ChildItem $TClientDir -Recurse -Include "*.exe" |
        Where-Object { $_.DirectoryName -like "*Release*" -and $_.DirectoryName -notlike "*Debug*" -and
                       ($_.Name -eq "TClient.exe" -or $_.Name -eq "TLoader.exe") } |
        ForEach-Object {
            Copy-Item $_.FullName -Destination $Destination -Force
            Write-Info "  $($_.Name) <- $($_.DirectoryName)"
        }
}

Write-Host ""
Write-Info "Contenu de $Destination :"
Get-ChildItem $Destination -ErrorAction SilentlyContinue | ForEach-Object { Write-Host "    $($_.Name)" -ForegroundColor Gray }

# =============================================================================
# RESUME FINAL
# =============================================================================
Write-Host ""
if ($buildErrors.Count -gt 0) {
    Write-Host "############################################################" -ForegroundColor Yellow
    Write-Host "#     COMPILATION TERMINEE AVEC ERREURS                   #" -ForegroundColor Yellow
    Write-Host "############################################################" -ForegroundColor Yellow
    Write-Host "  Projets en echec : $($buildErrors -join ', ')" -ForegroundColor Yellow
} else {
    Write-Host "############################################################" -ForegroundColor Green
    Write-Host "#         COMPILATION TERMINEE AVEC SUCCES                #" -ForegroundColor Green
    Write-Host "############################################################" -ForegroundColor Green
    Write-Host ""
    Write-Host "  TClient.exe -> $Destination" -ForegroundColor Green
    Write-Host ""
    Write-Host "  Prochaine etape : copier les ressources du client" -ForegroundColor Yellow
    Write-Host "  (Data/, Index/, Tcd/, etc.) a cote du TClient.exe" -ForegroundColor Yellow
    Write-Host "  puis lancer : TClient.exe 127.0.0.1 4816" -ForegroundColor Yellow
}
Write-Host ""
Write-Host "  Log de build : $env:TEMP\4story_client35_build.log" -ForegroundColor White
Write-Host ""
