# Client updater - right-click -> Run with PowerShell.
param(
	[string]$ManifestUrl = "",
	[switch]$Mods
)

$ErrorActionPreference = "Stop"
$ProgressPreference = "Continue"
$here = $PSScriptRoot
if (-not $here) { $here = (Get-Location).Path }
if (-not $ManifestUrl) { $ManifestUrl = "https://raw.githubusercontent.com/FalseFrontKlefo/Reborn/main/manifest.json" }
$ManifestUrl = $ManifestUrl.TrimEnd("/", "\")

try { [Net.ServicePointManager]::SecurityProtocol = [Net.ServicePointManager]::SecurityProtocol -bor [Net.SecurityProtocolType]::Tls12 } catch {}
Add-Type -AssemblyName System.IO.Compression.FileSystem

function Get-Hash($path) {
	(Get-FileHash -LiteralPath $path -Algorithm SHA256).Hash.ToUpper()
}

function Fetch([string]$url, [string]$dest) {
	if ($url -match "^https?://") {
		if ($dest) {
			if (Get-Command curl.exe -ErrorAction SilentlyContinue) {
				& curl.exe -L --fail --show-error -# -o $dest $url
				if ($LASTEXITCODE -ne 0) { throw "download failed (curl exit code $LASTEXITCODE)" }
			} else {
				Invoke-WebRequest $url -OutFile $dest -UseBasicParsing
			}
		} else {
			return (Invoke-WebRequest $url -UseBasicParsing).Content
		}
	} else {
		if (-not (Test-Path -LiteralPath $url)) { throw "not found: $url" }
		if ($dest) { Copy-Item -LiteralPath $url -Destination $dest -Force }
		else { return (Get-Content -LiteralPath $url -Raw) }
	}
}

function Sibling([string]$name) {
	$ManifestUrl -replace "[^/\\]+$", $name
}

function Resolve-Source([string]$src) {
	if ($src -match "^https?://" -or ($src -match "[/\\]" -and (Test-Path -LiteralPath $src))) { return $src }
	return (Sibling $src)
}

function Remove-Tree([string]$path) {
	if (-not (Test-Path -LiteralPath $path)) { return }
	try { [System.IO.Directory]::Delete($path, $true) }
	catch { Remove-Item -LiteralPath $path -Recurse -Force }
}

function Expand-ModsZip([string]$zip, [string]$dest) {
	$archive = [System.IO.Compression.ZipFile]::OpenRead($zip)
	try {
		$total = $archive.Entries.Count
		$rooted = $false
		foreach ($e in $archive.Entries) { if ($e.FullName -match "^Mods[\\/]") { $rooted = $true; break } }
	} finally { $archive.Dispose() }
	$target = if ($rooted) { $dest } else { Join-Path $dest "Mods" }
	[System.IO.Directory]::CreateDirectory($target) | Out-Null

	$tar = "$env:SystemRoot\System32\tar.exe"
	if (Test-Path -LiteralPath $tar) {
		# tar -v lists each extracted file on stderr; count the lines for progress.
		$eap = $ErrorActionPreference
		$ErrorActionPreference = "Continue"
		$n = 0
		$last = 0L
		$watch = [System.Diagnostics.Stopwatch]::StartNew()
		& $tar -xvf $zip -C $target 2>&1 | ForEach-Object {
			$n++
			if (($watch.ElapsedMilliseconds - $last) -ge 200) {
				$last = $watch.ElapsedMilliseconds
				Write-Progress -Activity "Extracting mods" -Status "$n / $total files" -PercentComplete ([Math]::Min(99, [int](100 * $n / $total)))
			}
		}
		$code = $LASTEXITCODE
		$ErrorActionPreference = $eap
		if ($code -ne 0) { throw "extract failed (tar exit code $code)" }
	} else {
		Expand-Archive -LiteralPath $zip -DestinationPath $target -Force
	}
	Write-Progress -Activity "Extracting mods" -Completed
}

$tmpExe = Join-Path $here "FalseFront.exe.new"
$zip = Join-Path $here "mods.tmp.zip"

$code = 0
try {
	if (Get-Process FalseFront, FalseFrontServer -ErrorAction SilentlyContinue) {
		throw "The game is running - close it and run this again."
	}

	$manifest = (Fetch $ManifestUrl) | ConvertFrom-Json
	$entry = $manifest.files."FalseFront.exe"
	if (-not $entry) { throw "manifest has no FalseFront.exe" }
	$want = ([string]$entry.sha256).ToUpper()
	if ($want -notmatch "^[0-9A-F]{64}$") { throw "manifest has no valid sha256 for FalseFront.exe" }

	if (-not $Mods) { $Mods = (Read-Host "Download the Mods folder too? (y/n)") -match "^y" }

	$local = Join-Path $here "FalseFront.exe"
	$have = if (Test-Path -LiteralPath $local) { Get-Hash $local } else { "" }
	if ($have -eq $want) {
		Write-Host ("FalseFront.exe up to date (" + $have.Substring(0, 12) + "...)")
	} else {
		if ($have) {
			Write-Host ("FalseFront.exe outdated (" + $have.Substring(0, 12) + "... -> " + $want.Substring(0, 12) + "...), downloading")
		} else {
			Write-Host ("Installing FalseFront.exe (" + $want.Substring(0, 12) + "...)")
		}
		$src = [string]$entry.url
		if (-not $src) { $src = "FalseFront.exe" }
		Fetch (Resolve-Source $src) $tmpExe
		if ((Get-Hash $tmpExe) -ne $want) { throw "downloaded file hash mismatch" }
		Move-Item -LiteralPath $tmpExe -Destination $local -Force
		Write-Host "Updated."
	}

	if ($Mods) {
		if (-not $manifest.mods) {
			Write-Host "No mods archive in the manifest."
		} else {
			$src = [string]$manifest.mods.url
			if (-not $src) { $src = "Mods.zip" }
			$wantZip = ([string]$manifest.mods.sha256).ToUpper()
			Write-Host "Downloading mods"
			Fetch (Resolve-Source $src) $zip
			if ($wantZip -and (Get-Hash $zip) -ne $wantZip) { throw "mods archive hash mismatch" }
			$modsDir = Join-Path $here "Mods"
			Write-Host "Replacing Mods folder"
			Remove-Tree $modsDir
			Write-Host "Extracting mods"
			Expand-ModsZip $zip $here
			if (-not (Test-Path -LiteralPath $modsDir)) { throw "mods archive did not contain a Mods folder" }
			Write-Host "Mods installed."
		}
	}
} catch {
	Write-Host $_.Exception.Message
	$code = 2
} finally {
	Remove-Item -LiteralPath $tmpExe, $zip -Force -ErrorAction SilentlyContinue
}

try { Read-Host "Press Enter to close" | Out-Null } catch {}
exit $code
