# =============================================================================
# 4-Database-Config.ps1
# 4Story - Configuration des bases de donnees
#
#   TMACHINE  — nom de machine du serveur (bMachineID=1)
#   TGROUP    — mot de passe DB + DSN du groupe 1
#   TIPADDR   — IP du serveur pour les clients (szIPAddr)
#   TACCOUNT  — compte de test (admin / MD5(admin))
#
# Prerequis : avoir execute 3-SQLServer-Database.ps1
# =============================================================================

#Requires -RunAsAdministrator
$ErrorActionPreference = "Stop"

# --- CONFIGURATION ---
$InstanceName = "FourStory"
$SaPassword   = "Bonjour123!"
$GlobalDB     = "TGLOBAL_GSP"
$GameDB       = "TGAME_GSP"
$GameDSN      = "TGAME_GSP"
$ServerConn   = ".\$InstanceName"

# IP vue par les clients (127.0.0.1 pour test local, IP reelle pour acces externe)
$ServerIP     = "127.0.0.1"
$MachineName  = $env:COMPUTERNAME

$TestLogin    = "admin"
$TestPassMD5  = "21232f297a57a5a743894a0e4a801fc3"  # MD5("admin")

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

function Invoke-Sql {
    param([string]$Query, [string]$DB = "master")
    $result = & sqlcmd -S $ServerConn -U sa -P $SaPassword -d $DB -Q $Query 2>&1
    if ($LASTEXITCODE -ne 0) { throw "sqlcmd echec : $result" }
    return $result
}

# =============================================================================
# DEBUT
# =============================================================================
Write-Host ""
Write-Host "############################################################" -ForegroundColor Cyan
Write-Host "#    4Story - Etape 4 : Configuration des bases           #" -ForegroundColor Cyan
Write-Host "############################################################" -ForegroundColor Cyan

try {
    Invoke-Sql -Query "SELECT 1" | Out-Null
    Write-OK "Connexion SQL OK : $ServerConn"
} catch {
    Write-Err "Impossible de se connecter a $ServerConn avec le compte sa."
    exit 1
}

foreach ($db in @($GlobalDB, $GameDB)) {
    $r = & sqlcmd -S $ServerConn -U sa -P $SaPassword -Q "SELECT name FROM sys.databases WHERE name='$db'" 2>&1
    if ($r -match $db) { Write-OK "Base $db : presente" }
    else               { Write-Err "Base $db introuvable - executez d'abord 3-SQLServer-Database.ps1" ; exit 1 }
}

# =============================================================================
# 1. TMACHINE — mettre a jour le nom de la machine (bMachineID=1)
# =============================================================================
Write-Step 1 "TGLOBAL_GSP.TMACHINE"

Invoke-Sql -DB $GlobalDB -Query "UPDATE TMACHINE SET szNAME='$MachineName' WHERE bMachineID=1;"
$r = Invoke-Sql -DB $GlobalDB -Query "SELECT bMachineID, szNAME FROM TMACHINE;"
Write-Host $r
Write-OK "TMACHINE bMachineID=1 -> '$MachineName'"

# =============================================================================
# 2. TGROUP — mettre a jour DSN et mot de passe (bGroupID=1)
# =============================================================================
Write-Step 2 "TGLOBAL_GSP.TGROUP"

Invoke-Sql -DB $GlobalDB -Query "UPDATE TGROUP SET szDSN='$GameDSN', szUserID='sa', szPasswd='$SaPassword' WHERE bGroupID=1;"
$r = Invoke-Sql -DB $GlobalDB -Query "SELECT bGroupID, szNAME, szDSN, szUserID FROM TGROUP;"
Write-Host $r
Write-OK "TGROUP bGroupID=1 : DSN=$GameDSN, user=sa"

# =============================================================================
# 3. TIPADDR — IP du serveur pour les clients
#   szIPAddr  = IP publique/locale vue par les clients
#   szPriAddr = IP interne (loopback)
# =============================================================================
Write-Step 3 "TGLOBAL_GSP.TIPADDR"

Invoke-Sql -DB $GlobalDB -Query "UPDATE TIPADDR SET szIPAddr='$ServerIP', szPriAddr='127.0.0.1', bActive=1 WHERE bMachineID=1;"
$r = Invoke-Sql -DB $GlobalDB -Query "SELECT bMachineID, szIPAddr, szPriAddr, bActive FROM TIPADDR;"
Write-Host $r
Write-OK "TIPADDR bMachineID=1 -> szIPAddr=$ServerIP"

# =============================================================================
# 4. TACCOUNT — compte de test
#   szPasswd = MD5 du mot de passe (le client envoie le hash avant envoi)
# =============================================================================
Write-Step 4 "TGLOBAL_GSP.TACCOUNT (compte de test)"

$r = & sqlcmd -S $ServerConn -U sa -P $SaPassword -d $GlobalDB -Q "SELECT szUserID FROM TACCOUNT WHERE szUserID='$TestLogin'" 2>&1
if ($r -match $TestLogin) {
    Invoke-Sql -DB $GlobalDB -Query "UPDATE TACCOUNT SET szPasswd='$TestPassMD5', bCheck=0 WHERE szUserID='$TestLogin';"
    Write-OK "TACCOUNT '$TestLogin' : mot de passe mis a jour"
} else {
    Invoke-Sql -DB $GlobalDB -Query "INSERT INTO TACCOUNT (szUserID, szPasswd, bCheck) VALUES ('$TestLogin', '$TestPassMD5', 0);"
    Write-OK "TACCOUNT '$TestLogin' : cree (MD5='$TestPassMD5')"
}
$r = Invoke-Sql -DB $GlobalDB -Query "SELECT TOP 5 dwUserID, szUserID, szPasswd FROM TACCOUNT;"
Write-Host $r

# =============================================================================
# RESUME FINAL
# =============================================================================
Write-Host ""
Write-Host "############################################################" -ForegroundColor Green
Write-Host "#               ETAPE 4 TERMINEE                          #" -ForegroundColor Green
Write-Host "############################################################" -ForegroundColor Green
Write-Host ""
Write-Host "  Serveur IP  : $ServerIP (szIPAddr dans TIPADDR)" -ForegroundColor White
Write-Host "  Machine     : $MachineName" -ForegroundColor White
Write-Host "  Compte test : $TestLogin / admin" -ForegroundColor White
Write-Host ""
Write-Host "  ATTENTION : Pour acces depuis une autre machine, changez" -ForegroundColor Yellow
Write-Host "  ServerIP = IP reelle en haut du script." -ForegroundColor Yellow
Write-Host ""
Write-Host "  Passez maintenant au script 5-Registry-Services.ps1." -ForegroundColor Cyan
Write-Host ""
