============================================================
  4Story - Scripts d'installation et compilation
============================================================

ORDRE D'EXECUTION (en administrateur PowerShell)
-------------------------------------------------
  1-Prepare-Sources.ps1    Migration VS2005->VS2017 + patches source
  2-Compile-Server.ps1     Compilation + copie vers C:\TServices_4s\
  3-SQLServer-Database.ps1 SQL Server + restauration .bak
  4-Database-Config.ps1    Tables SQL (TMachine, TGroup, TIPADDR...)
  5-Registry-Services.ps1  ODBC + services + registre + demarrage

Pour lancer un script :
  powershell -ExecutionPolicy Bypass -File .\<script>.ps1


PRE-REQUIS
----------
  - Visual Studio 2017 avec "Desktop development with C++" (MFC + ATL)
  - SQL Server 2017 Express (ou superieur)
  - Fichiers .bak dans le dossier 'databases' a cote de 'scripts' :
        databases\tglobal_gsp.bak
        databases\tgame_gsp.bak


CONFIGURATION (modifier en haut de chaque script)
--------------------------------------------------
  $SaPassword   Mot de passe SQL sa   (defaut : Bonjour123!)
  $InstanceName Nom instance SQL      (defaut : FourStory)
  $ServerIP     IP vue par les clients (defaut : 127.0.0.1)


CHEMINS IMPORTANTS
------------------
  Sources serveur : C:\Users\Administrator\4s\TServer\
  Binaires        : C:\TServices_4s\
  Bases SQL       : C:\databases\
  Log de build    : %TEMP%\4story_build.log


CORRECTIFS APPLIQUES PAR LE SCRIPT 1
-------------------------------------
  A. _WIN32_WINNT 0x0501  (WSAID_CONNECTEX undeclared)
  B. #include <winnls.h>  (GetThreadLocale)
  C. 4s_pre_include.h     (header force-inclus)
  D. ForcedIncludeFiles   (dans les 5 .vcxproj)
  E. for(DWORD i=0; ...)  (TRelaySvr - C2065)
  F. PreMessageLoop bypass (SCM erreur 1053)
  G. CTime dwAdd decompose (crash BatchThread TMapSvr)
  H. SESSION_CLIENT TLoginSvr (fix single-machine)
  I. SESSION_CLIENT TMapSvr   (fix connexion jeu)
  J. TVERSION 0x102b          (version client TW)


PORTS UTILISES
--------------
  TControlSvr : 3616
  TLoginSvr   : 4816
  TWorldSvr   : 3816
  TMapSvr     : 5816
  TRelaySvr   : 4016


COMPTE DE TEST
--------------
  Login    : admin
  Password : admin
  (le client envoie MD5 du mot de passe)
