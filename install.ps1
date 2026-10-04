# Installe ou met à jour Braise sur Windows, dans PowerShell :
#   irm https://raw.githubusercontent.com/TomRetouret/braise-releases/main/install.ps1 | iex
# Version précise : $env:BRAISE_VERSION = "v0.6.0"; irm ... | iex
#
# Ce que fait ce script, et rien d'autre :
#   1. lit la dernière version publiée sur github.com/TomRetouret/braise-releases ;
#   2. télécharge l'installateur et vérifie son empreinte SHA-256 ;
#   3. l'exécute en silence, pour ton compte seulement (aucun droit administrateur) ;
#   4. ouvre Braise.
# Désinstaller : Paramètres, Applications, Braise, Désinstaller.

$ErrorActionPreference = "Stop"
$ProgressPreference = "SilentlyContinue"

$Owner = if ($env:BRAISE_OWNER) { $env:BRAISE_OWNER } else { "TomRetouret" }
$Repo = if ($env:BRAISE_REPO) { $env:BRAISE_REPO } else { "braise-releases" }
$Version = if ($env:BRAISE_VERSION) { $env:BRAISE_VERSION } else { "latest" }
$Api = if ($env:BRAISE_API) { $env:BRAISE_API } else { "https://api.github.com" }

function Ok($m) { Write-Host "  " -NoNewline; Write-Host "✓" -ForegroundColor Green -NoNewline; Write-Host " $m" }
function Fail($m) { Write-Host ""; Write-Host "Installation interrompue : $m" -ForegroundColor Red; exit 1 }

if (-not [Environment]::Is64BitOperatingSystem) { Fail "Braise pour Windows existe en 64 bits seulement." }
[Net.ServicePointManager]::SecurityProtocol = [Net.SecurityProtocolType]::Tls12

Write-Host ""
Write-Host "Braise · tes projets, allumés."
Write-Host ""

$url = if ($Version -eq "latest") { "$Api/repos/$Owner/$Repo/releases/latest" } else { "$Api/repos/$Owner/$Repo/releases/tags/$Version" }
try { $rel = Invoke-RestMethod -Uri $url -Headers @{ Accept = "application/vnd.github+json" } }
catch { Fail "impossible de lire les versions sur github.com/$Owner/$Repo (connexion, VPN ?)." }

$setup = $rel.assets | Where-Object { $_.name -like "*_x64-setup.exe" } | Select-Object -First 1
$sums = $rel.assets | Where-Object { $_.name -eq "SHA256SUMS.txt" } | Select-Object -First 1
if (-not $setup) { Fail "aucune version Windows de Braise publiée pour l'instant." }
if (-not $sums) { Fail "la version $($rel.tag_name) n'a pas de fichier d'empreintes, installation refusée." }
Ok "Version $($rel.tag_name) trouvée"

$tmp = Join-Path ([IO.Path]::GetTempPath()) ("braise-" + [Guid]::NewGuid().ToString("N"))
New-Item -ItemType Directory -Path $tmp | Out-Null
try {
  $file = Join-Path $tmp $setup.name
  try { Invoke-WebRequest -Uri $setup.browser_download_url -OutFile $file -UseBasicParsing }
  catch { Fail "le téléchargement a échoué." }

  $line = (Invoke-RestMethod -Uri $sums.browser_download_url) -split "`n" | Where-Object { $_ -match ("\s\*?" + [regex]::Escape($setup.name) + "\s*$") } | Select-Object -First 1
  $expected = if ($line) { ($line -split "\s+")[0].ToLower() } else { "" }
  $actual = (Get-FileHash -Algorithm SHA256 -Path $file).Hash.ToLower()
  if (-not $expected -or $expected -ne $actual) { Fail "l'empreinte SHA-256 ne correspond pas : fichier abîmé ou modifié." }
  Ok "Empreinte SHA-256 vérifiée"

  $running = Get-Process -Name "braise" -ErrorAction SilentlyContinue
  if ($running) {
    Write-Host "  Braise est ouvert : on le ferme pour le remplacer."
    $running | ForEach-Object { $_.CloseMainWindow() | Out-Null }
    Start-Sleep -Seconds 3
    Get-Process -Name "braise" -ErrorAction SilentlyContinue | Stop-Process -Force
  }

  # Installateur NSIS, mode silencieux, pour l'utilisateur courant.
  Unblock-File -Path $file -ErrorAction SilentlyContinue
  $p = Start-Process -FilePath $file -ArgumentList "/S" -Wait -PassThru
  if ($p.ExitCode -ne 0) { Fail "l'installateur s'est arrêté (code $($p.ExitCode))." }
  Ok "Installé pour ton compte"
}
finally {
  Remove-Item -Recurse -Force $tmp -ErrorAction SilentlyContinue
}

Write-Host ""
Write-Host "Braise $($rel.tag_name) est prêt. Il se mettra à jour tout seul."
$exe = @(
  (Join-Path $env:LOCALAPPDATA "Braise\braise.exe"),
  (Join-Path $env:LOCALAPPDATA "Programs\Braise\braise.exe")
) | Where-Object { Test-Path $_ } | Select-Object -First 1
if ($exe) { Start-Process -FilePath $exe } else { Write-Host "Ouvre-le depuis le menu Démarrer." }
