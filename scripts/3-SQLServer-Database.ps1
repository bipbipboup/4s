# =============================================================================
# 3-SQLServer-Database.ps1
# 4Story - Installation SQL Server 2022 Express + Restauration des bases
# =============================================================================

#Requires -RunAsAdministrator
$ErrorActionPreference = "Stop"

# --- CONFIGURATION ---
$InstanceName = "FourStory"
$SaPassword   = "ChangeThisStrongPassword!"   # change ca
$GlobalDB     = "TGLOBAL_GSP"
$GameDB       = "TGAME_GSP"

$ScriptDir    = Split-Path -Parent $MyInvocation.MyCommand.Path
$BakDir       = "$ScriptDir\..\databases"
$DatabaseDir  = "C:\databases"
$ServerConn   = ".\$InstanceName"

# ================= FONCTIONS =================
function Write-Step { param($Num, $Message)
    Write-Host "`n============================================================" -ForegroundColor Yellow
    Write-Host "  Etape $Num : $Message" -ForegroundColor Yellow
    Write-Host "============================================================" -ForegroundColor Yellow
}

function Write-Info { param($M) Write-Host "  [*] $M" -ForegroundColor Cyan }
function Write-OK   { param($M) Write-Host "  [+] $M" -ForegroundColor Green }
function Write-Warn { param($M) Write-Host "  [!] $M" -ForegroundColor Yellow }
function Write-Err  { param($M) Write-Host "  [-] $M" -ForegroundColor Red }

function Ensure-SqlServerModule {
    if (-not (Get-Module -ListAvailable SqlServer)) {
        Write-Info "Module 'SqlServer' absent - installation..."
        # Forcer l'installation du provider NuGet en mode non-interactif
        [Net.ServicePointManager]::SecurityProtocol = [Net.SecurityProtocolType]::Tls12
        Install-PackageProvider -Name NuGet -MinimumVersion 2.8.5.201 -Force -Scope CurrentUser | Out-Null
        Set-PSRepository -Name PSGallery -InstallationPolicy Trusted
        Install-Module SqlServer -Force -Scope CurrentUser -AllowClobber
    }
    Import-Module SqlServer -Force
    Write-OK "Module SqlServer pret"
}

function Test-SqlInstance {
    return (Get-Service "MSSQL`$$InstanceName" -ErrorAction SilentlyContinue)
}

# ================= TELECHARGEMENT VIA CURL =================
function Get-FileOptimized {
    param(
        [string]$Url,
        [string]$Destination
    )

    if (Test-Path $Destination) {
        Write-Warn "Fichier existant detecte, suppression : $Destination"
        Remove-Item $Destination -Force -ErrorAction Stop
    }

    Write-Info "Telechargement via curl : $Url"
    & curl.exe -L --progress-bar --fail -o $Destination $Url
    if ($LASTEXITCODE -ne 0) { throw "curl a echoue (code $LASTEXITCODE)" }

    Write-OK "Telechargement termine : $Destination"
}

# ================= INSTALL SQL 2022 EXPRESS =================
function Install-Sql {
    Write-Info "Telechargement et installation de SQL Server 2022 Express..."
    $sqlUrl = "https://download.microsoft.com/download/E/A/E/EAE6F7FC-767A-4038-A954-49B8B05D04EB/Express%2064BIT/SQLEXPR_x64_ENU.exe"
    $sqlExe = "$env:TEMP\SQLEXPR2022.exe"
    Get-FileOptimized -Url $sqlUrl -Destination $sqlExe

    $sqlArgs = @(
        "/Q",
        "/ACTION=Install",
        "/FEATURES=SQLEngine",
        "/INSTANCENAME=$InstanceName",
        "/SECURITYMODE=SQL",
        "/SAPWD=$SaPassword",
        "/TCPENABLED=1",
        "/IACCEPTSQLSERVERLICENSETERMS"
    )
    Start-Process $sqlExe -ArgumentList $sqlArgs -Wait -NoNewWindow
    Start-Service "MSSQL`$$InstanceName"
    Start-Sleep 5
    Write-OK "SQL Server 2022 Express installe"
}

function Enable-MixedMode {
    Write-Info "Activation du mode mixte et configuration du compte sa..."
    $query = @"
ALTER LOGIN [sa] WITH PASSWORD=N'$SaPassword', CHECK_POLICY=ON;
EXEC sp_configure 'show advanced options', 1; RECONFIGURE;
EXEC sp_configure 'user connections', 0; RECONFIGURE;
"@
    Invoke-Sqlcmd -ServerInstance $ServerConn -Query $query -TrustServerCertificate -ErrorAction Stop

    $regBase = Get-ChildItem "HKLM:\SOFTWARE\Microsoft\Microsoft SQL Server" |
                   Where-Object { $_.PSChildName -match "^MSSQL\d+\.$InstanceName$" } |
                   Select-Object -First 1 -ExpandProperty PSPath
    $regPath = "$regBase\MSSQLServer"
    if (Test-Path $regPath) {
        Set-ItemProperty -Path $regPath -Name "LoginMode" -Value 2 -Type DWord -Force
        Restart-Service "MSSQL`$$InstanceName" -Force
        Start-Sleep 8
        Write-OK "Mode mixte active et service redemarre"
    }
}

function Restore-Database {
    param([string]$Name, [string]$BakFile, [string]$LogicalData, [string]$LogicalLog)

    $bak = Join-Path $BakDir $BakFile
    if (-not (Test-Path $bak)) {
        Write-Warn "Fichier .bak introuvable : $BakFile"
        return
    }

    New-Item -ItemType Directory -Path $DatabaseDir -Force | Out-Null
    $targetBak = Join-Path $DatabaseDir $BakFile
    Copy-Item $bak $targetBak -Force

    $mdf = "$DatabaseDir\$Name.mdf"
    $ldf = "$DatabaseDir\$Name`_log.ldf"

    Write-Info "Restauration de $Name..."
    $query = @"
IF EXISTS (SELECT * FROM sys.databases WHERE name = '$Name')
BEGIN
    ALTER DATABASE [$Name] SET SINGLE_USER WITH ROLLBACK IMMEDIATE;
    DROP DATABASE [$Name];
END
RESTORE DATABASE [$Name]
FROM DISK = '$targetBak'
WITH MOVE '$LogicalData' TO '$mdf',
     MOVE '$LogicalLog'  TO '$ldf',
     REPLACE;
"@
    Invoke-Sqlcmd -ServerInstance $ServerConn -Username "sa" -Password $SaPassword -Query $query -TrustServerCertificate -ErrorAction Stop
    Write-OK "Base $Name restauree"
}

# ================= EXECUTION =================
Write-Host ""
Write-Host "############################################################" -ForegroundColor Cyan
Write-Host "#    4Story - Etape 3 : SQL Server 2022 Express + Bases   #" -ForegroundColor Cyan
Write-Host "############################################################" -ForegroundColor Cyan

Write-Step 1 "Preparation module SqlServer"
Ensure-SqlServerModule

Write-Step 2 "SQL Server Express (instance $InstanceName)"
if (-not (Test-SqlInstance)) {
    Install-Sql
} else {
    Write-OK "Instance SQL '$InstanceName' deja presente"
}

Write-Step 3 "Configuration compte sa et mode mixte"
Enable-MixedMode

Write-Step 4 "Restauration des bases"
$databases = @(
    @{ Name=$GlobalDB; BakFile="tglobal_gsp.bak"; LogicalData="TGLOBAL_Data"; LogicalLog="TGLOBAL_Log" },
    @{ Name=$GameDB;   BakFile="tgame_gsp.bak";   LogicalData="TGAME_Data";   LogicalLog="TGAME_Log" }
)

foreach ($db in $databases) {
    Restore-Database $db.Name $db.BakFile $db.LogicalData $db.LogicalLog
}

# ================= RESUME FINAL =================
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
