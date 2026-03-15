# =============================================================================
# 3-SQLServer-Database.ps1
# 4Story - Installation SQL Server + Restauration des bases
#
#   1. Installation de SQL Server Express (instance FourStory) si absent
#   2. Restauration de TGLOBAL_GSP et TGAME_GSP depuis les fichiers .bak
#   3. Configuration du compte 'sa' (activation + mot de passe)
#
# PREREQUIS :
#   - Fournir les fichiers .bak dans le dossier 'databases' a cote de ce script,
#     OU modifier $BakDir ci-dessous pour pointer vers leur emplacement.
#   - Fichiers attendus : tglobal_gsp.bak  et  tgame_gsp.bak
#
#   Si vous avez deja une installation fonctionnelle de 4Story 3.5, vous pouvez
#   recopier les .bak depuis C:\databases\ (crees par les anciens scripts).
# =============================================================================

#Requires -RunAsAdministrator
$ErrorActionPreference = "Stop"

# --- CONFIGURATION - MODIFIER SI NECESSAIRE ---
$InstanceName = "FourStory"
$SaPassword   = "Bonjour123!"    # Mot de passe du compte SQL 'sa'
$GlobalDB     = "TGLOBAL_GSP"
$GameDB       = "TGAME_GSP"

# Dossier contenant les .bak
$ScriptDir    = Split-Path -Parent $MyInvocation.MyCommand.Path
$BakDir       = "$ScriptDir\..\databases"   # Cree un dossier 'databases' a cote de 'scripts'
$DatabaseDir  = "C:\databases"              # Repertoire SQL Server pour les fichiers .mdf/.ldf

$ServerConn   = ".\$InstanceName"

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

function Invoke-SqlCmd {
    param([string]$Query, [string]$Database = "master", [switch]$NoError)
    $args = @("-S", $ServerConn, "-U", "sa", "-P", $SaPassword, "-d", $Database, "-Q", $Query)
    $result = & sqlcmd @args 2>&1
    if ($LASTEXITCODE -ne 0 -and -not $NoError) {
        throw "sqlcmd echec (code $LASTEXITCODE) : $result"
    }
    return $result
}

function Test-SqlInstance {
    param([string]$Name)
    return ($null -ne (Get-Service -Name ("MSSQL`$$Name") -ErrorAction SilentlyContinue))
}

function Find-Installer {
    param([string]$Pattern)
    foreach ($dir in @($ScriptDir, "$ScriptDir\..")) {
        $f = Get-ChildItem $dir -Filter $Pattern -ErrorAction SilentlyContinue | Select-Object -First 1
        if ($f) { return $f.FullName }
    }
    return $null
}

# =============================================================================
# DEBUT
# =============================================================================
Write-Host ""
Write-Host "############################################################" -ForegroundColor Cyan
Write-Host "#    4Story - Etape 3 : SQL Server + Bases de donnees     #" -ForegroundColor Cyan
Write-Host "############################################################" -ForegroundColor Cyan

# =============================================================================
# 1. SQL Server Express
# =============================================================================
Write-Step 1 "SQL Server Express (instance $InstanceName)"

if (Test-SqlInstance -Name $InstanceName) {
    Write-OK "Instance SQL '$InstanceName' deja presente."
} else {
    $installer = Find-Installer "SQLServer2017-SSEI-Expr.exe"
    if (-not $installer) {
        $installer = Find-Installer "SQLEXPR*.exe"
    }
    if (-not $installer) {
        Write-Err "Installateur SQL Server introuvable."
        Write-Warn "Telechargez SQL Server 2017 Express et placez l'EXE dans $ScriptDir ou son dossier parent."
        exit 1
    }
    Write-Info "Installation depuis : $installer"
    $proc = Start-Process -FilePath $installer `
        -ArgumentList @("/Q", "/IACCEPTSQLSERVERLICENSETERMS", "/ACTION=Install",
                        "/INSTANCENAME=$InstanceName", "/FEATURES=SQLEngine",
                        "/SECURITYMODE=SQL", "/SAPWD=$SaPassword",
                        "/TCPENABLED=1", "/BROWSERSVCSTARTUPTYPE=Automatic") `
        -Wait -PassThru -NoNewWindow
    if ($proc.ExitCode -ne 0 -and $proc.ExitCode -ne 3010) {
        Write-Err "Installation SQL Server echouee (code $($proc.ExitCode))."
        exit 1
    }
    Write-OK "SQL Server installe."

    # Demarrer le service
    Start-Service "MSSQL`$$InstanceName" -ErrorAction SilentlyContinue
    Start-Sleep -Seconds 5
}

# Verifier que le service tourne
$sqlSvc = Get-Service "MSSQL`$$InstanceName" -ErrorAction SilentlyContinue
if (-not $sqlSvc) {
    Write-Err "Service SQL Server MSSQL`$$InstanceName introuvable."
    exit 1
}
if ($sqlSvc.Status -ne "Running") {
    Write-Info "Demarrage du service SQL..."
    Start-Service "MSSQL`$$InstanceName"
    Start-Sleep -Seconds 5
}
Write-OK "Service SQL : RUNNING"

# =============================================================================
# 2. Mot de passe SA
# =============================================================================
Write-Step 2 "Configuration du compte 'sa'"

# Activer l'authentification mixte et le compte sa
# Ces commandes utilisent d'abord l'auth Windows (ne necessite pas le mot de passe sa)
$saScript = @"
USE [master];
ALTER LOGIN [sa] WITH PASSWORD = N'$SaPassword';
ALTER LOGIN [sa] ENABLE;
EXEC sp_configure 'show advanced options', 1; RECONFIGURE;
EXEC sp_configure 'user connections', 0; RECONFIGURE;
"@
try {
    $r = & sqlcmd -S $ServerConn -E -Q $saScript 2>&1
    Write-OK "Compte sa configure (auth Windows)."
} catch {
    Write-Warn "Configuration sa via auth Windows echouee - tentative via sa..."
}

# Activer l'authentification SQL Server (mode mixte) via registre
$regPath = "HKLM:\SOFTWARE\Microsoft\Microsoft SQL Server\MSSQL14.$InstanceName\MSSQLServer"
if (Test-Path $regPath) {
    Set-ItemProperty -Path $regPath -Name "LoginMode" -Value 2 -Type DWord -Force
    Write-OK "Mode mixte (SQL + Windows) active."
    # Redemarrer pour appliquer
    Restart-Service "MSSQL`$$InstanceName" -Force
    Start-Sleep -Seconds 8
    Write-OK "Service SQL redémarre."
}

# =============================================================================
# 3. Restauration des bases
# =============================================================================
Write-Step 3 "Restauration des bases de donnees"

New-Item -ItemType Directory -Path $DatabaseDir -Force | Out-Null

# Noms logiques reels dans les .bak (verifies avec RESTORE FILELISTONLY)
$databases = @(
    @{ Name = $GlobalDB; BakFile = "tglobal_gsp.bak"; LogicalData = "TGLOBAL_Data"; LogicalLog = "TGLOBAL_Log" },
    @{ Name = $GameDB;   BakFile = "tgame_gsp.bak";   LogicalData = "TGAME_Data";   LogicalLog = "TGAME_Log"   }
)

foreach ($db in $databases) {
    $bakSrc = $null

    # Chercher le .bak dans le dossier du projet
    foreach ($dir in @($BakDir, $ScriptDir, "$ScriptDir\..", $DatabaseDir)) {
        $candidate = Join-Path $dir $db.BakFile
        if (Test-Path $candidate) { $bakSrc = $candidate; break }
    }

    if (-not $bakSrc) {
        Write-Warn "Fichier .bak introuvable : $($db.BakFile)"
        Write-Warn "Placez-le dans : $BakDir"
        continue
    }

    # Le service SQL Server n'a pas acces a C:\Users\...
    # On copie le .bak dans $DatabaseDir (accessible par SQL Server)
    $bakPath = Join-Path $DatabaseDir $db.BakFile
    if ($bakSrc -ne $bakPath) {
        Write-Info "Copie de $($db.BakFile) vers $DatabaseDir (droits SQL Server)..."
        Copy-Item $bakSrc $bakPath -Force
    }

    Write-Info "Restauration de $($db.Name) depuis $bakPath ..."

    $mdfPath = "$DatabaseDir\$($db.Name).mdf"
    $ldfPath = "$DatabaseDir\$($db.Name)_log.ldf"

    $restoreQuery = @"
USE [master];
IF EXISTS (SELECT name FROM sys.databases WHERE name = N'$($db.Name)')
BEGIN
    ALTER DATABASE [$($db.Name)] SET SINGLE_USER WITH ROLLBACK IMMEDIATE;
    DROP DATABASE [$($db.Name)];
END
RESTORE DATABASE [$($db.Name)]
    FROM DISK = N'$bakPath'
    WITH MOVE N'$($db.LogicalData)' TO N'$mdfPath',
         MOVE N'$($db.LogicalLog)'  TO N'$ldfPath',
         REPLACE, STATS = 10;
"@
    try {
        $result = & sqlcmd -S $ServerConn -U sa -P $SaPassword -Q $restoreQuery 2>&1
        if ($LASTEXITCODE -ne 0) { throw $result }
        Write-OK "Base $($db.Name) restauree."
    } catch {
        Write-Err "Echec restauration $($db.Name) : $_"
        Write-Warn "Verifiez que le fichier .bak est valide et compatible avec SQL Server 2017."
    }
}

# =============================================================================
# RESUME FINAL
# =============================================================================
Write-Host ""
Write-Host "############################################################" -ForegroundColor Green
Write-Host "#               ETAPE 3 TERMINEE                          #" -ForegroundColor Green
Write-Host "############################################################" -ForegroundColor Green
Write-Host ""
Write-Host "  Instance SQL  : $ServerConn" -ForegroundColor White
Write-Host "  Compte sa     : mot de passe = $SaPassword" -ForegroundColor White
Write-Host "  Bases         : $GlobalDB, $GameDB" -ForegroundColor White
Write-Host ""
Write-Host "  Passez maintenant au script 4-Database-Config.ps1." -ForegroundColor Cyan
Write-Host ""
