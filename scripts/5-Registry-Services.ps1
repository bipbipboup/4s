# =============================================================================
# 5-Registry-Services.ps1
# 4Story - Registre Windows + Installation et demarrage des services
#
#   1. DSN ODBC System (TGLOBAL_GSP, TGAME_GSP)
#   2. Suppression des anciens services (re-execution propre)
#   3. Installation des services Windows via sc.exe
#   4. Cles de registre Config sous HKLM\...\Services\<NomService>\Config
#   4b. AppID COM (requis par ATL pour que m_bService=TRUE)
#   5. Regles pare-feu
#   6. Demarrage dans l'ordre correct
#
# Noms de services (= IDS_SERVICENAME dans les EXEs) :
#   TControlSvr, TLoginSvr, TWorldSvr, TMapSvr, TRelaySvr
#
# Prerequis : avoir execute 2-Compile-Server.ps1 et 3-4-SQLServer-Database.ps1
# =============================================================================

#Requires -RunAsAdministrator
$ErrorActionPreference = "Stop"

# --- CONFIGURATION - MODIFIER SI NECESSAIRE ---
$InstanceName = "FourStory"
$SaPassword   = "ChangeThisStrongPassword!"    # Meme valeur que dans les scripts 3 et 4
$ServerConn   = ".\$InstanceName"
$GlobalDB     = "TGLOBAL_GSP"
$GameDB       = "TGAME_GSP"
$GlobalDSN    = "TGLOBAL_GSP"
$GameDSN      = "TGAME_GSP"

# Dossier des binaires compiles (sortie du script 2)
$ServicesDir  = "C:\TServices_4s"

# =============================================================================
# Fonctions
# =============================================================================
function Write-Step {
    param([int]$Num, [string]$Message)
    Write-Host "`n============================================================" -ForegroundColor Yellow
    Write-Host "  Etape $Num : $Message" -ForegroundColor Yellow
    Write-Host "============================================================" -ForegroundColor Yellow
}
function Write-Info { param([string]$M) Write-Host "  [*] $M" -ForegroundColor Cyan   }
function Write-OK   { param([string]$M) Write-Host "  [+] $M" -ForegroundColor Green  }
function Write-Warn { param([string]$M) Write-Host "  [!] $M" -ForegroundColor Yellow }
function Write-Err  { param([string]$M) Write-Host "  [-] $M" -ForegroundColor Red    }

function Set-RegValue {
    param([string]$Path, [string]$Name, $Value, [string]$Type = "String")
    if (-not (Test-Path $Path)) { New-Item -Path $Path -Force | Out-Null }
    Set-ItemProperty -Path $Path -Name $Name -Value $Value -Type $Type -Force
}

function Remove-ServiceIfExists {
    param([string]$Name)
    $s = Get-Service -Name $Name -ErrorAction SilentlyContinue
    if ($s) {
        if ($s.Status -eq "Running") {
            Stop-Service -Name $Name -Force -ErrorAction SilentlyContinue
            Start-Sleep -Seconds 2
        }
        sc.exe delete $Name | Out-Null
        Start-Sleep -Seconds 1
        Write-Info "  Service '$Name' supprime."
    }
}

# =============================================================================
# DEBUT
# =============================================================================
Write-Host ""
Write-Host "############################################################" -ForegroundColor Cyan
Write-Host "#   4Story - Etape 5 : Registre + Services Windows        #" -ForegroundColor Cyan
Write-Host "############################################################" -ForegroundColor Cyan

if (-not (Test-Path $ServicesDir)) {
    Write-Err "Dossier des binaires introuvable : $ServicesDir"
    Write-Warn "Assurez-vous d'avoir execute le script 2-Compile-Server.ps1."
    exit 1
}
Write-OK "Binaires : $ServicesDir"

$LocalIP = (Get-NetIPAddress -AddressFamily IPv4 |
            Where-Object { $_.InterfaceAlias -notlike "*Loopback*" -and $_.PrefixOrigin -ne "WellKnown" } |
            Select-Object -First 1).IPAddress
if (-not $LocalIP) { $LocalIP = "127.0.0.1" }
Write-Info "IP locale detectee : $LocalIP"

# Definition des services et de leur configuration registre
# Ports (decimaux) :
#   TControlSvr : 3616 (0x0E20)
#   TLoginSvr   : 4816 (0x12D0)
#   TWorldSvr   : 3816 (0x0EE8)
#   TMapSvr     : 5816 (0x16B8)
#   TRelaySvr   : 4016 (0x0FB0)
$services = @(
    @{
        ServiceName = "TControlSvr"
        ExeName     = "TControlSvr.exe"
        DisplayName = "4Story Control Server"
        StringVals  = @{ DBUser="sa"; DBPasswd=$SaPassword; DSN=$GlobalDSN }
        DwordVals   = @{ Port=0x0e20 }
    },
    @{
        ServiceName = "TLoginSvr"
        ExeName     = "TLoginSvr.exe"
        DisplayName = "4Story Login Server"
        StringVals  = @{ DBUser="sa"; DBPasswd=$SaPassword; DSN=$GlobalDSN; LogIP="127.0.0.1" }
        DwordVals   = @{ Port=0x12d0; ServerID=1; LogPort=0x1b58 }
    },
    @{
        ServiceName = "TWorldSvr"
        ExeName     = "TWorldSvr.exe"
        DisplayName = "4Story World Server"
        StringVals  = @{ DBUser="sa"; DBPasswd=$SaPassword; DSN=$GameDSN }
        DwordVals   = @{ GroupID=1; ServerID=1; Port=0x0ee8 }
    },
    @{
        ServiceName = "TMapSvr"
        ExeName     = "TMapSvr.exe"
        DisplayName = "4Story Map Server"
        # WorldIP et LogIP en loopback : tous les serveurs sur la meme machine.
        # Utiliser 127.0.0.1 evite les problemes si l'IP reseau change.
        StringVals  = @{ DBUser="sa"; GamePasswd=$SaPassword; GameDSN=$GameDSN; WorldIP="127.0.0.1"; LogIP="127.0.0.1" }
        DwordVals   = @{ GroupID=1; ServerID=1; GamePort=0x16b8; WorldPort=0x0ee8; LogPort=0x1b58 }
    },
    @{
        ServiceName = "TRelaySvr"
        ExeName     = "TRelaySvr.exe"
        DisplayName = "4Story Relay Server"
        # ControlIP, WorldIP en loopback
        StringVals  = @{ WorldIP="127.0.0.1"; ControlIP="127.0.0.1"; LogIP="127.0.0.1" }
        DwordVals   = @{ GroupID=1; ServerID=1; RelayPort=0x0fb0; WorldPort=0x0ee8; LogPort=0x1b58 }
    }
)

# =============================================================================
# 1. DSN ODBC System
# =============================================================================
Write-Step 1 "Creation des DSN ODBC System"

$dsnDefs = @(
    @{ DSN=$GlobalDSN; Database=$GlobalDB },
    @{ DSN=$GameDSN;   Database=$GameDB   }
)
foreach ($def in $dsnDefs) {
    foreach ($root in @("HKLM:\SOFTWARE\ODBC\ODBC.INI","HKLM:\SOFTWARE\WOW6432Node\ODBC\ODBC.INI")) {
        $dsnPath    = "$root\$($def.DSN)"
        $sourcePath = "$root\ODBC Data Sources"
        Set-RegValue -Path $dsnPath    -Name "Driver"      -Value "C:\Windows\System32\SQLSRV32.dll"
        Set-RegValue -Path $dsnPath    -Name "Description" -Value ""
        Set-RegValue -Path $dsnPath    -Name "Server"      -Value $ServerConn
        Set-RegValue -Path $dsnPath    -Name "Database"    -Value $def.Database
        Set-RegValue -Path $dsnPath    -Name "LastUser"    -Value "sa"
        Set-RegValue -Path $sourcePath -Name $def.DSN      -Value "SQL Server"
    }
    Write-OK "DSN '$($def.DSN)' -> $($def.Database) sur $ServerConn"
}

# =============================================================================
# 2. Suppression des anciens services
# =============================================================================
Write-Step 2 "Suppression des anciens services (re-installation propre)"

# Anciens noms GSP si present d'une installation precedente
foreach ($name in @("TCTRL_GSP","TLOGIN_GSP","TWORLD_GSP","TMAP_GSP","TRELAY_GSP")) {
    Remove-ServiceIfExists -Name $name
}
foreach ($svc in $services) { Remove-ServiceIfExists -Name $svc.ServiceName }
Start-Sleep -Seconds 2

# =============================================================================
# 3. Installation des services Windows
# =============================================================================
Write-Step 3 "Installation des services Windows"

foreach ($svc in $services) {
    $exePath = "$ServicesDir\$($svc.ExeName)"
    if (-not (Test-Path $exePath)) {
        Write-Warn "Executable introuvable : $exePath - service '$($svc.ServiceName)' non installe."
        continue
    }
    $scResult = sc.exe create $svc.ServiceName `
        binPath= "`"$exePath`"" `
        DisplayName= "`"$($svc.DisplayName)`"" `
        type= own `
        start= auto
    if ($LASTEXITCODE -eq 0) { Write-OK "Service '$($svc.ServiceName)' installe." }
    else                     { Write-Err "sc.exe echoue pour '$($svc.ServiceName)' (code $LASTEXITCODE)." }
}

# =============================================================================
# 4. Cles de registre Config
# IMPORTANT : doit etre APRES sc.exe create (la cle de service doit exister)
# =============================================================================
Write-Step 4 "Cles de registre Config"

foreach ($svc in $services) {
    $regPath = "HKLM:\SYSTEM\CurrentControlSet\Services\$($svc.ServiceName)\Config"
    foreach ($kv in $svc.StringVals.GetEnumerator()) {
        Set-RegValue -Path $regPath -Name $kv.Key -Value $kv.Value -Type String
    }
    foreach ($kv in $svc.DwordVals.GetEnumerator()) {
        Set-RegValue -Path $regPath -Name $kv.Key -Value $kv.Value -Type DWord
    }
    Write-OK "$($svc.ServiceName)\Config : OK"
}

# =============================================================================
# 4b. AppID COM (requis par ATL pour que m_bService = TRUE)
#   Sans ces cles, ATL detecte un lancement hors SCM, met m_bService=FALSE
#   et n'appelle pas StartServiceCtrlDispatcher => SCM erreur 1053
# =============================================================================
Write-Info "Configuration AppID COM pour chaque service..."

$appidGuids = @{
    "TControlSvr" = "{A666C778-2308-47B0-A6F4-AAE1B0BB50D8}"
    "TLoginSvr"   = "{A9C0CF53-7D54-43D7-B01C-D604FB9DF809}"
    "TWorldSvr"   = "{2DD07566-9248-4798-A96F-259263CDA0E5}"
    "TMapSvr"     = "{51AB7A30-995A-44AB-B869-7D79E92D466C}"
    "TRelaySvr"   = "{391A2583-6A42-4915-BE88-0CCE50BA382F}"
}
$appidBase = "HKLM:\SOFTWARE\Classes\AppID"

foreach ($svc in $services) {
    $guid     = $appidGuids[$svc.ServiceName]
    $guidPath = "$appidBase\$guid"
    $exeKey   = "$appidBase\$($svc.ServiceName).EXE"
    if (-not (Test-Path $guidPath)) { New-Item -Path $guidPath -Force | Out-Null }
    Set-ItemProperty -Path $guidPath -Name "(default)"    -Value $svc.ServiceName
    Set-ItemProperty -Path $guidPath -Name "LocalService" -Value $svc.ServiceName
    if (-not (Test-Path $exeKey)) { New-Item -Path $exeKey -Force | Out-Null }
    Set-ItemProperty -Path $exeKey -Name "AppID" -Value $guid
    Write-OK "$($svc.ServiceName) AppID=$guid"
}

# =============================================================================
# 5. Regles pare-feu
# =============================================================================
Write-Step 5 "Ouverture des ports pare-feu"

$fwRules = @(
    @{ Port=3616; Name="4Story-TControlSvr" },
    @{ Port=4816; Name="4Story-TLoginSvr"   },
    @{ Port=3816; Name="4Story-TWorldSvr"   },
    @{ Port=5816; Name="4Story-TMapSvr"     },
    @{ Port=4016; Name="4Story-TRelaySvr"   }
)
foreach ($fw in $fwRules) {
    netsh advfirewall firewall delete rule name="$($fw.Name)" | Out-Null
    netsh advfirewall firewall add rule name="$($fw.Name)" dir=in action=allow protocol=TCP localport=$($fw.Port) | Out-Null
    Write-OK "Pare-feu : $($fw.Name) port $($fw.Port) TCP inbound"
}

# =============================================================================
# 6. Demarrage des services dans l'ordre correct
# =============================================================================
Write-Step 6 "Demarrage des services"

$startOrder = @(
    @{ Name="TControlSvr"; TimeoutSec=20  },
    @{ Name="TLoginSvr";   TimeoutSec=20  },
    @{ Name="TWorldSvr";   TimeoutSec=20  },
    @{ Name="TRelaySvr";   TimeoutSec=20  },
    @{ Name="TMapSvr";     TimeoutSec=120 }  # Chargement long des donnees de cartes
)

foreach ($entry in $startOrder) {
    $svcName = $entry.Name
    $timeout = $entry.TimeoutSec
    $svc = Get-Service -Name $svcName -ErrorAction SilentlyContinue
    if (-not $svc) { Write-Warn "Service '$svcName' non trouve - ignore." ; continue }

    Write-Info "Demarrage de $svcName (timeout ${timeout}s)..."
    $job = Start-Job -ScriptBlock { param($n) sc.exe start $n 2>&1 } -ArgumentList $svcName

    $started = $false
    $t0 = [DateTime]::Now
    for ($i = 0; $i -lt ($timeout * 2); $i++) {
        Start-Sleep -Milliseconds 500
        $sc2   = sc.exe query $svcName 2>&1 | Out-String
        $state = if ($sc2 -match "STATE\s+:\s+\d+\s+(\S+)") { $Matches[1] } else { "?" }
        if ($state -eq "RUNNING") {
            $ms = [math]::Round(([DateTime]::Now - $t0).TotalMilliseconds)
            Write-OK "$svcName : RUNNING en ${ms}ms"
            $started = $true
            break
        } elseif ($state -eq "STOPPED") {
            $w32 = if ($sc2 -match "WIN32_EXIT_CODE\s+:\s+(\d+)") { $Matches[1] } else { "?" }
            Write-Warn "$svcName : STOPPED (W32Exit=$w32) - verifier les logs"
            break
        }
    }
    if (-not $started) {
        $sc2 = sc.exe query $svcName 2>&1 | Out-String
        if ($sc2 -match "START_PENDING") {
            Write-Warn "$svcName : toujours START_PENDING apres ${timeout}s"
        }
    }
    Receive-Job $job -ErrorAction SilentlyContinue | Out-Null
    Remove-Job $job -Force
    Start-Sleep -Seconds 2
}

# =============================================================================
# RESUME FINAL
# =============================================================================
Write-Host ""
Write-Host "############################################################" -ForegroundColor Green
Write-Host "#               ETAPE 5-6 TERMINEE                        #" -ForegroundColor Green
Write-Host "############################################################" -ForegroundColor Green
Write-Host ""
Write-Host "  IP serveur : $LocalIP" -ForegroundColor White
Write-Host "  Binaires   : $ServicesDir" -ForegroundColor White
Write-Host ""
Write-Host "  Etat des services :" -ForegroundColor White
foreach ($entry in $startOrder) {
    $svc = Get-Service -Name $entry.Name -ErrorAction SilentlyContinue
    if ($svc) {
        $color = if ($svc.Status -eq "Running") { "Green" } else { "Red" }
        Write-Host "    $($entry.Name.PadRight(15)) : $($svc.Status)" -ForegroundColor $color
    } else {
        Write-Host "    $($entry.Name.PadRight(15)) : NON INSTALLE" -ForegroundColor Yellow
    }
}
Write-Host ""
Write-Host "  Compte de test : admin / admin" -ForegroundColor White
Write-Host "  IP client      : configurez le client avec IP = $LocalIP" -ForegroundColor White
Write-Host ""
