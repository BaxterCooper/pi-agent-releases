#requires -Version 5.1
[CmdletBinding()]
param(
    [Parameter(Position = 0)]
    [ValidateSet('install', 'uninstall', 'status')]
    [string]$Action = 'install',

    [Parameter(Position = 1)]
    [string]$Channel = 'stable'
)

Set-StrictMode -Version Latest
$ErrorActionPreference = 'Stop'

# Generated source: BaxterCooper/pi-agent apps/desktop/bootstrap/install.ps1. The
# desktop release workflow publishes this file to BaxterCooper/pi-agent-releases.
$ApiRoot = 'https://api.github.com/repos/BaxterCooper/pi-agent-releases'
$ProductName = 'OMP Agent'
# Tauri's NSIS installer keys the per-user uninstall entry by product name, so a
# renamed product leaves the previous registration installed beside the new one.
$LegacyProductNames = @('Pi Agent')
$TempRoot = $null

function Stop-Bootstrap {
    param([Parameter(Mandatory = $true)][string]$Message)

    throw "OMP Agent bootstrap: $Message"
}

function Get-PropertyValue {
    param(
        [Parameter(Mandatory = $true)][AllowNull()]$Object,
        [Parameter(Mandatory = $true)][string]$Name
    )

    if ($null -eq $Object) {
        return $null
    }

    $property = $Object.PSObject.Properties[$Name]
    if ($null -eq $property) {
        return $null
    }

    return $property.Value
}
function Test-SemanticVersion {
    param([Parameter(Mandatory = $true)][string]$Value)

    $pattern = '^(0|[1-9][0-9]*)\.(0|[1-9][0-9]*)\.(0|[1-9][0-9]*)(?:-(?:0|[1-9][0-9]*|[0-9A-Za-z-]*[A-Za-z-][0-9A-Za-z-]*)(?:\.(?:0|[1-9][0-9]*|[0-9A-Za-z-]*[A-Za-z-][0-9A-Za-z-]*))*)?(?:\+[0-9A-Za-z-]+(?:\.[0-9A-Za-z-]+)*)?$'
    return $Value -match $pattern
}

function Assert-HttpsUri {
    param(
        [Parameter(Mandatory = $true)][string]$Value,
        [Parameter(Mandatory = $true)][string]$Label
    )

    if ([string]::IsNullOrWhiteSpace($Value)) {
        Stop-Bootstrap "$Label did not contain a URL."
    }

    try {
        $uri = [Uri]$Value
    }
    catch {
        Stop-Bootstrap "$Label was not a valid URL."
    }

    if (-not $uri.IsAbsoluteUri -or $uri.Scheme -cne 'https' -or [string]::IsNullOrWhiteSpace($uri.Host) -or -not [string]::IsNullOrEmpty($uri.UserInfo)) {
        Stop-Bootstrap "$Label must be an HTTPS URL without embedded credentials."
    }
}

function New-HttpsClient {
    $handler = New-Object System.Net.Http.HttpClientHandler
    $handler.AllowAutoRedirect = $false

    $client = New-Object System.Net.Http.HttpClient($handler)
    $client.Timeout = [TimeSpan]::FromSeconds(60)
    $client.DefaultRequestHeaders.UserAgent.ParseAdd('pi-agent-bootstrap/1.0')
    $client.DefaultRequestHeaders.Accept.ParseAdd('application/vnd.github+json')
    return [pscustomobject]@{
        Handler = $handler
        Client = $client
    }
}

function Invoke-HttpsText {
    param([Parameter(Mandatory = $true)][Uri]$Uri)

    Assert-HttpsUri -Value $Uri.AbsoluteUri -Label 'Download URL'
    $http = New-HttpsClient
    $client = $http.Client
    $current = $Uri

    try {
        for ($attempt = 0; $attempt -lt 6; $attempt++) {
            $response = $null
            try {
                try {
                    $response = $client.GetAsync($current, [System.Net.Http.HttpCompletionOption]::ResponseHeadersRead).GetAwaiter().GetResult()
                }
                catch {
                    Stop-Bootstrap "HTTPS request to '$current' could not be completed: $($_.Exception.Message)"
                }

                $statusCode = [int]$response.StatusCode
                if ($statusCode -in @(301, 302, 303, 307, 308)) {
                    $location = $response.Headers.Location
                    if ($null -eq $location) {
                        Stop-Bootstrap "HTTPS request to '$current' redirected without a Location header."
                    }
                    if (-not $location.IsAbsoluteUri) {
                        $location = [Uri]::new($current, $location)
                    }
                    Assert-HttpsUri -Value $location.AbsoluteUri -Label 'Redirect URL'
                    $current = $location
                    continue
                }

                if (-not $response.IsSuccessStatusCode) {
                    Stop-Bootstrap "HTTPS request to '$current' failed with HTTP $statusCode."
                }

                try {
                    $bytes = $response.Content.ReadAsByteArrayAsync().GetAwaiter().GetResult()
                    $encoding = New-Object System.Text.UTF8Encoding($false, $true)
                    return $encoding.GetString($bytes)
                }
                catch {
                    Stop-Bootstrap "HTTPS response from '$current' could not be read as UTF-8: $($_.Exception.Message)"
                }
            }
            finally {
                if ($null -ne $response) {
                    $response.Dispose()
                }
            }
        }

        Stop-Bootstrap "HTTPS request to '$Uri' redirected too many times."
    }
    finally {
        $client.Dispose()
        $http.Handler.Dispose()
    }
}
function Invoke-HttpsDownload {
    param(
        [Parameter(Mandatory = $true)][Uri]$Uri,
        [Parameter(Mandatory = $true)][string]$Destination
    )

    Assert-HttpsUri -Value $Uri.AbsoluteUri -Label 'Download URL'
    $http = New-HttpsClient
    $client = $http.Client
    $current = $Uri
    $downloaded = $false
    $destinationCreated = $false

    try {
        for ($attempt = 0; $attempt -lt 6; $attempt++) {
            $response = $null
            $stream = $null
            $fileStream = $null
            try {
                try {
                    $response = $client.GetAsync($current, [System.Net.Http.HttpCompletionOption]::ResponseHeadersRead).GetAwaiter().GetResult()
                }
                catch {
                    Stop-Bootstrap "HTTPS request to '$current' could not be completed: $($_.Exception.Message)"
                }

                $statusCode = [int]$response.StatusCode
                if ($statusCode -in @(301, 302, 303, 307, 308)) {
                    $location = $response.Headers.Location
                    if ($null -eq $location) {
                        Stop-Bootstrap "HTTPS request to '$current' redirected without a Location header."
                    }
                    if (-not $location.IsAbsoluteUri) {
                        $location = [Uri]::new($current, $location)
                    }
                    Assert-HttpsUri -Value $location.AbsoluteUri -Label 'Redirect URL'
                    $current = $location
                    continue
                }

                if (-not $response.IsSuccessStatusCode) {
                    Stop-Bootstrap "HTTPS request to '$current' failed with HTTP $statusCode."
                }

                try {
                    $stream = $response.Content.ReadAsStreamAsync().GetAwaiter().GetResult()
                    $fileStream = [IO.File]::Open($Destination, [IO.FileMode]::CreateNew, [IO.FileAccess]::Write, [IO.FileShare]::None)
                    $destinationCreated = $true
                    [void]($stream.CopyToAsync($fileStream).GetAwaiter().GetResult())
                    $downloaded = $true
                    return
                }
                catch {
                    Stop-Bootstrap "HTTPS download from '$current' could not be written: $($_.Exception.Message)"
                }
            }
            finally {
                if ($null -ne $fileStream) {
                    $fileStream.Dispose()
                }
                if ($null -ne $stream) {
                    $stream.Dispose()
                }
                if ($null -ne $response) {
                    $response.Dispose()
                }
            }
        }

        Stop-Bootstrap "HTTPS request to '$Uri' redirected too many times."
    }
    finally {
        if (-not $downloaded -and $destinationCreated -and (Test-Path -LiteralPath $Destination)) {
            Remove-Item -LiteralPath $Destination -Force -ErrorAction SilentlyContinue
        }
        $client.Dispose()
        $http.Handler.Dispose()
    }
}


function Get-Release {
    param([Parameter(Mandatory = $true)][string]$RequestedChannel)

    if ($RequestedChannel -ceq 'stable' -or $RequestedChannel -ceq 'latest') {
        $endpoint = "$ApiRoot/releases/latest"
    }
    else {
        if (-not (Test-SemanticVersion -Value $RequestedChannel)) {
            Stop-Bootstrap "Channel must be 'stable', 'latest', or an exact semantic version such as 1.2.3."
        }
        $endpoint = "$ApiRoot/releases/tags/v$RequestedChannel"
    }

    $releaseText = Invoke-HttpsText -Uri ([Uri]$endpoint)
    try {
        $release = ConvertFrom-Json -InputObject $releaseText
    }
    catch {
        Stop-Bootstrap 'GitHub Releases returned malformed JSON.'
    }

    $tagValue = Get-PropertyValue -Object $release -Name 'tag_name'
    $assetsValue = Get-PropertyValue -Object $release -Name 'assets'
    $draft = Get-PropertyValue -Object $release -Name 'draft'
    $publishedAt = Get-PropertyValue -Object $release -Name 'published_at'
    $publishedAtText = ''
    if ($null -ne $publishedAt) {
        $publishedAtText = [System.Convert]::ToString($publishedAt, [System.Globalization.CultureInfo]::InvariantCulture)
    }
    if ($tagValue -isnot [string] -or [string]::IsNullOrWhiteSpace($tagValue) -or $null -eq $assetsValue -or $draft -isnot [bool] -or $draft -or $null -eq $publishedAt -or [string]::IsNullOrWhiteSpace($publishedAtText)) {
        Stop-Bootstrap 'The selected GitHub release was missing valid publication metadata or assets.'
    }
    $assets = @($assetsValue)
    if ($assets.Count -eq 0) {
        Stop-Bootstrap 'The selected GitHub release did not contain any assets.'
    }

    $tag = [string]$tagValue
    if ($tag.Length -lt 2 -or $tag[0] -cne 'v') {
        Stop-Bootstrap "Release tag '$tag' was not a supported semantic version tag."
    }
    $version = $tag.Substring(1)
    if (-not (Test-SemanticVersion -Value $version)) {
        Stop-Bootstrap "Release tag '$tag' was not a supported semantic version tag."
    }
    if ($RequestedChannel -cne 'stable' -and $RequestedChannel -cne 'latest' -and $tag -cne "v$RequestedChannel") {
        Stop-Bootstrap "GitHub returned tag '$tag' instead of the requested tag 'v$RequestedChannel'."
    }

    $installerPattern = '^[^/\\\x00-\x1F"]+_x64-setup\.exe$'
    $installerAssets = @($assets | Where-Object {
        $nameValue = Get-PropertyValue -Object $_ -Name 'name'
        $nameValue -is [string] -and $nameValue -cmatch $installerPattern
    })
    if ($installerAssets.Count -ne 1) {
        Stop-Bootstrap "Expected exactly one x64 NSIS installer asset, found $($installerAssets.Count)."
    }

    $installer = $installerAssets[0]
    $installerNameValue = Get-PropertyValue -Object $installer -Name 'name'
    $installerSizeValue = Get-PropertyValue -Object $installer -Name 'size'
    if ($installerNameValue -isnot [string] -or [string]::IsNullOrWhiteSpace($installerNameValue)) {
        Stop-Bootstrap 'The selected installer asset did not contain a valid name.'
    }
    $installerName = [string]$installerNameValue
    if ($installerSizeValue -eq $null -or ([string]$installerSizeValue -notmatch '^[0-9]+$')) {
        Stop-Bootstrap "Installer asset '$installerName' had no valid declared size."
    }
    try {
        $installerSize = [Int64]::Parse([string]$installerSizeValue, [Globalization.CultureInfo]::InvariantCulture)
    }
    catch {
        Stop-Bootstrap "Installer asset '$installerName' had no valid declared size."
    }
    if ($installerSize -le 0) {
        Stop-Bootstrap "Installer asset '$installerName' had no positive declared size."
    }

    $sidecarAssets = @($assets | Where-Object {
        $nameValue = Get-PropertyValue -Object $_ -Name 'name'
        $nameValue -is [string] -and $nameValue -ceq "$installerName.sha256"
    })
    if ($sidecarAssets.Count -ne 1) {
        Stop-Bootstrap "Expected exactly one checksum sidecar named '$installerName.sha256', found $($sidecarAssets.Count)."
    }

    $installerUrlValue = Get-PropertyValue -Object $installer -Name 'browser_download_url'
    $sidecarUrlValue = Get-PropertyValue -Object $sidecarAssets[0] -Name 'browser_download_url'
    if ($installerUrlValue -isnot [string] -or $sidecarUrlValue -isnot [string]) {
        Stop-Bootstrap "The selected release assets did not contain download URLs."
    }
    $installerUrl = [string]$installerUrlValue
    $sidecarUrl = [string]$sidecarUrlValue
    Assert-HttpsUri -Value $installerUrl -Label "Installer asset '$installerName'"
    Assert-HttpsUri -Value $sidecarUrl -Label "Checksum sidecar '$installerName.sha256'"

    return [pscustomobject]@{
        Tag = $tag
        Version = $version
        InstallerName = $installerName
        InstallerSize = $installerSize
        InstallerUri = [Uri]$installerUrl
        SidecarUri = [Uri]$sidecarUrl
    }
}

function Get-Sha256 {
    param([Parameter(Mandatory = $true)][string]$Path)

    $sha = [Security.Cryptography.SHA256]::Create()
    $stream = $null
    try {
        try {
            $stream = [IO.File]::OpenRead($Path)
            $bytes = $sha.ComputeHash($stream)
            return ([BitConverter]::ToString($bytes).Replace('-', '')).ToLowerInvariant()
        }
        catch {
            Stop-Bootstrap "Could not compute a SHA-256 digest for '$Path': $($_.Exception.Message)"
        }
    }
    finally {
        if ($null -ne $stream) {
            $stream.Dispose()
        }
        $sha.Dispose()
    }
}
function Assert-ChecksumSidecar {
    param(
        [Parameter(Mandatory = $true)][string]$InstallerPath,
        [Parameter(Mandatory = $true)][string]$SidecarPath,
        [Parameter(Mandatory = $true)][string]$InstallerName
    )

    $hash = Get-Sha256 -Path $InstallerPath
    if ($hash -cnotmatch '^[0-9a-f]{64}$') {
        Stop-Bootstrap 'Could not compute a valid lowercase SHA-256 digest for the installer.'
    }

    $expected = [Text.Encoding]::UTF8.GetBytes("$hash  $InstallerName`n")
    try {
        $actual = [IO.File]::ReadAllBytes($SidecarPath)
    }
    catch {
        Stop-Bootstrap "Could not read checksum sidecar '$InstallerName.sha256': $($_.Exception.Message)"
    }
    if ($actual.Length -ne $expected.Length) {
        Stop-Bootstrap "Checksum sidecar '$InstallerName.sha256' had invalid byte-for-byte contents."
    }
    for ($index = 0; $index -lt $expected.Length; $index++) {
        if ($actual[$index] -ne $expected[$index]) {
            Stop-Bootstrap "Checksum sidecar '$InstallerName.sha256' did not match the downloaded installer."
        }
    }
}
function Invoke-Install {
    Assert-WindowsX64
    $release = Get-Release -RequestedChannel $Channel

    $script:TempRoot = Join-Path ([IO.Path]::GetTempPath()) ("pi-agent-bootstrap-" + [Guid]::NewGuid().ToString('N'))
    New-Item -ItemType Directory -Path $script:TempRoot -Force | Out-Null
    try {
        $installerPath = Join-Path $script:TempRoot 'pi-agent-installer.exe'
        $sidecarPath = Join-Path $script:TempRoot 'pi-agent-installer.sha256'
        Invoke-HttpsDownload -Uri $release.InstallerUri -Destination $installerPath
        Invoke-HttpsDownload -Uri $release.SidecarUri -Destination $sidecarPath

        $installerInfo = Get-Item -LiteralPath $installerPath -ErrorAction Stop
        if ($installerInfo.PSIsContainer) {
            Stop-Bootstrap 'The downloaded installer was not a regular file.'
        }
        $downloadedSize = [Int64]$installerInfo.Length
        if ($downloadedSize -ne $release.InstallerSize) {
            Stop-Bootstrap "Downloaded installer size $downloadedSize did not match the release-declared size $($release.InstallerSize)."
        }
        Assert-ChecksumSidecar -InstallerPath $installerPath -SidecarPath $sidecarPath -InstallerName $release.InstallerName

        $exitCode = Invoke-Executable -FilePath $installerPath -Arguments '/S' -Purpose 'OMP Agent installer'
        if ($exitCode -ne 0) {
            Stop-Bootstrap "The OMP Agent installer failed with exit code $exitCode."
        }

        $entry = Get-SinglePiAgentEntry -Purpose 'verify the installation'
        if ($null -eq $entry) {
            Stop-Bootstrap 'The installer completed but did not register OMP Agent for the current user.'
        }
        if ($entry.DisplayVersion -cne $release.Version) {
            Stop-Bootstrap "Installed OMP Agent DisplayVersion '$($entry.DisplayVersion)' did not match release version '$($release.Version)'."
        }
        Write-Output "OMP Agent version $($entry.DisplayVersion) installed for the current user."
        Remove-LegacyInstallations
    }
    finally {
        if ($null -ne $script:TempRoot -and (Test-Path -LiteralPath $script:TempRoot)) {
            Remove-Item -LiteralPath $script:TempRoot -Recurse -Force -ErrorAction SilentlyContinue
        }
    }
}


function Get-PiAgentUninstallEntries {
    param([string]$DisplayName = $ProductName)
    $roots = @(
        'HKCU:\Software\Microsoft\Windows\CurrentVersion\Uninstall',
        'HKCU:\Software\WOW6432Node\Microsoft\Windows\CurrentVersion\Uninstall'
    )
    $entries = @()

    foreach ($root in $roots) {
        if (-not (Test-Path -LiteralPath $root)) {
            continue
        }
        foreach ($key in @(Get-ChildItem -LiteralPath $root -ErrorAction Stop)) {
            $properties = Get-ItemProperty -LiteralPath $key.PSPath -ErrorAction Stop
            $displayNameValue = Get-PropertyValue -Object $properties -Name 'DisplayName'
            if ($displayNameValue -isnot [string] -or $displayNameValue -cne $DisplayName) {
                continue
            }
            $displayVersionValue = Get-PropertyValue -Object $properties -Name 'DisplayVersion'
            $installLocationValue = Get-PropertyValue -Object $properties -Name 'InstallLocation'
            $quietUninstallValue = Get-PropertyValue -Object $properties -Name 'QuietUninstallString'
            $uninstallValue = Get-PropertyValue -Object $properties -Name 'UninstallString'
            $entries += [pscustomobject]@{
                KeyPath = [string]$key.PSPath
                DisplayVersion = if ($displayVersionValue -is [string]) { $displayVersionValue } else { '' }
                InstallLocation = if ($installLocationValue -is [string]) { $installLocationValue } else { '' }
                QuietUninstallString = if ($quietUninstallValue -is [string]) { $quietUninstallValue } else { '' }
                UninstallString = if ($uninstallValue -is [string]) { $uninstallValue } else { '' }
            }
        }
    }

    return $entries
}
function Get-CanonicalInstallLocation {
    param(
        [Parameter(Mandatory = $true)][string]$Value,
        [string]$DisplayName = $ProductName
    )

    $normalizedValue = $Value
    if ($normalizedValue.IndexOf('"') -ge 0) {
        if ($normalizedValue.Length -lt 2 -or $normalizedValue[0] -cne '"' -or $normalizedValue[$normalizedValue.Length - 1] -cne '"' -or $normalizedValue.Substring(1, $normalizedValue.Length - 2).IndexOf('"') -ge 0) {
            Stop-Bootstrap "The current-user $DisplayName uninstall entry had an invalid quoted InstallLocation."
        }
        $normalizedValue = $normalizedValue.Substring(1, $normalizedValue.Length - 2)
    }
    if ([string]::IsNullOrWhiteSpace($normalizedValue) -or $normalizedValue -match '[\x00-\x1F]' -or $normalizedValue -notmatch '^[A-Za-z]:\\') {
        Stop-Bootstrap "The current-user $DisplayName uninstall entry had an invalid absolute InstallLocation."
    }
    $localAppData = [Environment]::GetEnvironmentVariable('LOCALAPPDATA', 'Process')
    if ([string]::IsNullOrWhiteSpace($localAppData) -or $localAppData -notmatch '^[A-Za-z]:\\') {
        Stop-Bootstrap 'LOCALAPPDATA was not an absolute Windows path.'
    }

    try {
        $localRootInfo = New-Object IO.DirectoryInfo($localAppData)
        $locationInfo = New-Object IO.DirectoryInfo($normalizedValue)
        if (-not $localRootInfo.Exists -or -not $locationInfo.Exists) {
            Stop-Bootstrap "The current-user $DisplayName InstallLocation did not exist."
        }
        if (($locationInfo.Attributes -band [IO.FileAttributes]::ReparsePoint) -ne 0) {
            Stop-Bootstrap "The current-user $DisplayName InstallLocation was a reparse point."
        }
        $separator = [IO.Path]::DirectorySeparatorChar
        $localRootPath = $localRootInfo.FullName.TrimEnd($separator)
        $locationPath = $locationInfo.FullName.TrimEnd($separator)
        $localRootPrefix = $localRootPath + $separator
        if (-not $locationPath.StartsWith($localRootPrefix, [StringComparison]::OrdinalIgnoreCase)) {
            Stop-Bootstrap "The current-user $DisplayName InstallLocation was outside LOCALAPPDATA."
        }
        return $locationPath
    }
    catch {
        Stop-Bootstrap "The current-user $DisplayName InstallLocation could not be validated: $($_.Exception.Message)"
    }
}
function Get-SinglePiAgentEntry {
    param([Parameter(Mandatory = $true)][string]$Purpose)

    $entries = @(Get-PiAgentUninstallEntries)
    if ($entries.Count -eq 0) {
        return $null
    }
    if ($entries.Count -ne 1) {
        Stop-Bootstrap "Found multiple current-user OMP Agent uninstall entries while attempting to $Purpose."
    }
    if ([string]::IsNullOrWhiteSpace($entries[0].DisplayVersion) -or -not (Test-SemanticVersion -Value $entries[0].DisplayVersion)) {
        Stop-Bootstrap "The current-user OMP Agent uninstall entry had no valid semantic DisplayVersion while attempting to $Purpose."
    }
    if ([string]::IsNullOrWhiteSpace($entries[0].InstallLocation)) {
        Stop-Bootstrap "The current-user OMP Agent uninstall entry had no InstallLocation while attempting to $Purpose."
    }
    $canonicalInstallLocation = Get-CanonicalInstallLocation -Value $entries[0].InstallLocation
    [void]($entries[0].InstallLocation = $canonicalInstallLocation)
    return $entries[0]
}
function Split-UninstallCommand {
    param([Parameter(Mandatory = $true)][string]$CommandLine)

    $expanded = [Environment]::ExpandEnvironmentVariables($CommandLine)
    if ([string]::IsNullOrWhiteSpace($expanded) -or $expanded -match '[\x00-\x1F]') {
        Stop-Bootstrap 'The registered OMP Agent uninstall command was empty or contained control characters.'
    }
    $line = $expanded.Trim()

    $filePath = $null
    $arguments = ''
    if ($line.StartsWith('"', [StringComparison]::Ordinal)) {
        $closingQuote = $line.IndexOf('"', 1)
        if ($closingQuote -lt 0) {
            Stop-Bootstrap 'The registered OMP Agent uninstall command had an unterminated quoted executable path.'
        }
        $filePath = $line.Substring(1, $closingQuote - 1)
        $afterQuote = $line.Substring($closingQuote + 1)
        if ($afterQuote.Length -gt 0 -and -not [Char]::IsWhiteSpace($afterQuote[0])) {
            Stop-Bootstrap 'The registered OMP Agent uninstall command had characters directly after the quoted executable path.'
        }
        $arguments = $afterQuote.Trim()
    }
    else {
        $match = [Regex]::Match($line, '^(?<file>[^\s"]+)(?:\s+(?<args>.*))?$')
        if (-not $match.Success) {
            Stop-Bootstrap 'The registered OMP Agent uninstall command could not be parsed safely.'
        }
        $filePath = $match.Groups['file'].Value
        if ($match.Groups['args'].Success) {
            $arguments = $match.Groups['args'].Value
        }
    }

    if ([string]::IsNullOrWhiteSpace($filePath) -or $filePath.Contains('"') -or $filePath -notmatch '^[A-Za-z]:\\') {
        Stop-Bootstrap 'The registered OMP Agent uninstall command had an invalid absolute executable path.'
    }

    try {
        $extension = [IO.Path]::GetExtension($filePath)
    }
    catch {
        Stop-Bootstrap 'The registered OMP Agent uninstall command had an invalid executable path.'
    }
    if ([string]::IsNullOrWhiteSpace($extension) -or $extension.ToLowerInvariant() -cne '.exe' -or -not [IO.File]::Exists($filePath)) {
        Stop-Bootstrap 'The registered OMP Agent uninstall command did not point to an existing executable file.'
    }


    return [pscustomobject]@{
        FilePath = $filePath
        Arguments = $arguments
    }
}
function Get-CanonicalUninstallerPath {
    param(
        [Parameter(Mandatory = $true)]$Entry,
        [Parameter(Mandatory = $true)]$ParsedCommand
    )

    $expectedPath = Join-Path -Path $Entry.InstallLocation -ChildPath 'uninstall.exe'
    try {
        $expectedItem = Get-Item -LiteralPath $expectedPath -Force -ErrorAction Stop
        $parsedItem = Get-Item -LiteralPath $ParsedCommand.FilePath -Force -ErrorAction Stop
        if ($expectedItem.PSIsContainer -or $parsedItem.PSIsContainer) {
            Stop-Bootstrap 'The registered OMP Agent uninstaller was not a regular file.'
        }
        if (($expectedItem.Attributes -band [IO.FileAttributes]::ReparsePoint) -ne 0 -or ($parsedItem.Attributes -band [IO.FileAttributes]::ReparsePoint) -ne 0) {
            Stop-Bootstrap 'The registered OMP Agent uninstaller was a reparse point.'
        }
        if ([String]::Compare($expectedItem.FullName, $parsedItem.FullName, [StringComparison]::OrdinalIgnoreCase) -ne 0) {
            Stop-Bootstrap 'The registered OMP Agent uninstall command did not point to the exact per-user uninstaller.'
        }
        return $expectedItem.FullName
    }
    catch {
        Stop-Bootstrap "The registered OMP Agent uninstaller could not be validated: $($_.Exception.Message)"
    }
}
function Invoke-Executable {
    param(
        [Parameter(Mandatory = $true)][string]$FilePath,
        [Parameter(Mandatory = $true)][string]$Arguments,
        [Parameter(Mandatory = $true)][string]$Purpose
    )

    $startInfo = New-Object System.Diagnostics.ProcessStartInfo
    $startInfo.FileName = $FilePath
    $startInfo.Arguments = $Arguments
    $startInfo.UseShellExecute = $false
    $startInfo.CreateNoWindow = $true
    $process = $null
    try {
        $process = [System.Diagnostics.Process]::Start($startInfo)
        if ($null -eq $process) {
            Stop-Bootstrap "Could not start the $Purpose."
        }
        $process.WaitForExit()
        return $process.ExitCode
    }
    catch {
        Stop-Bootstrap "Could not run the ${Purpose}: $($_.Exception.Message)"
    }
    finally {
        if ($null -ne $process) {
            $process.Dispose()
        }
    }
}
function Assert-WindowsX64 {
    if ([Environment]::OSVersion.Platform -ne [PlatformID]::Win32NT) {
        Stop-Bootstrap 'This bootstrap supports Windows x64 only.'
    }
    $processArchitecture = [Environment]::GetEnvironmentVariable('PROCESSOR_ARCHITECTURE', 'Process')
    $nativeArchitecture = [Environment]::GetEnvironmentVariable('PROCESSOR_ARCHITEW6432', 'Process')
    $effectiveArchitecture = if ([string]::IsNullOrWhiteSpace($nativeArchitecture)) {
        $processArchitecture
    }
    else {
        $nativeArchitecture
    }
    if ([string]::IsNullOrWhiteSpace($effectiveArchitecture) -or $effectiveArchitecture.ToUpperInvariant() -cne 'AMD64') {
        Stop-Bootstrap 'This bootstrap supports Windows x64 only (ARM64 and x86 are not supported).'
    }
}





function Invoke-RegisteredUninstaller {
    param(
        [Parameter(Mandatory = $true)]$Entry,
        [Parameter(Mandatory = $true)][string]$DisplayName
    )
    $entry = $Entry
    $command = if (-not [string]::IsNullOrWhiteSpace($entry.QuietUninstallString)) {
        $entry.QuietUninstallString
    }
    else {
        $entry.UninstallString
    }
    if ([string]::IsNullOrWhiteSpace($command)) {
        Stop-Bootstrap 'The current-user OMP Agent uninstall entry had neither QuietUninstallString nor UninstallString.'
    }

    $parsed = Split-UninstallCommand -CommandLine $command
    $uninstallerPath = Get-CanonicalUninstallerPath -Entry $entry -ParsedCommand $parsed
    $exitCode = Invoke-Executable -FilePath $uninstallerPath -Arguments '/S' -Purpose 'registered OMP Agent uninstaller'
    if ($exitCode -ne 0) {
        Stop-Bootstrap "The registered $DisplayName uninstaller failed with exit code $exitCode."
    }

    $deadline = [System.Diagnostics.Stopwatch]::GetTimestamp() + ([System.Diagnostics.Stopwatch]::Frequency * 60)
    $remaining = @()
    do {
        $remaining = @(Get-PiAgentUninstallEntries -DisplayName $DisplayName)
        if ($remaining.Count -eq 0) {
            Write-Output "$DisplayName was uninstalled for the current user."
            return
        }
        if ([System.Diagnostics.Stopwatch]::GetTimestamp() -ge $deadline) {
            break
        }
        Start-Sleep -Milliseconds 250
    } while ($true)
    if ($remaining.Count -gt 1) {
        Stop-Bootstrap "The registered uninstaller completed but multiple current-user $DisplayName uninstall entries remain."
    }
    Stop-Bootstrap "The registered uninstaller completed but the current-user $DisplayName uninstall entry remains."
}

# Runs after a verified install. The silent NSIS uninstaller only purges
# %APPDATA%/%LOCALAPPDATA%\<bundle id> when its interactive checkbox is set, so
# removing the superseded product leaves the shared user data in place. A
# superseded entry that cannot be removed is reported, never fatal.
function Remove-LegacyInstallations {
    foreach ($legacyName in $LegacyProductNames) {
        try {
            $entries = @(Get-PiAgentUninstallEntries -DisplayName $legacyName)
            if ($entries.Count -eq 0) {
                continue
            }
            if ($entries.Count -ne 1) {
                throw "found $($entries.Count) current-user uninstall entries"
            }
            $entry = $entries[0]
            if ([string]::IsNullOrWhiteSpace($entry.InstallLocation)) {
                throw 'the uninstall entry had no InstallLocation'
            }
            [void]($entry.InstallLocation = (Get-CanonicalInstallLocation -Value $entry.InstallLocation -DisplayName $legacyName))
            Write-Output "Removing superseded $legacyName installation."
            Invoke-RegisteredUninstaller -Entry $entry -DisplayName $legacyName
        }
        catch {
            Write-Warning "Left the superseded $legacyName installation in place; remove it from Windows Settings manually: $($_.Exception.Message)"
        }
    }
}

function Invoke-Uninstall {
    Assert-WindowsX64
    $entry = Get-SinglePiAgentEntry -Purpose 'uninstall OMP Agent'
    if ($null -ne $entry) {
        Invoke-RegisteredUninstaller -Entry $entry -DisplayName $ProductName
    }
    else {
        Write-Output 'OMP Agent is not installed for the current user.'
    }
    Remove-LegacyInstallations
}

function Invoke-Status {
    Assert-WindowsX64
    $entry = Get-SinglePiAgentEntry -Purpose 'read status'
    if ($null -eq $entry) {
        Write-Output 'OMP Agent is not installed for the current user.'
        return
    }
    Write-Output "OMP Agent version $($entry.DisplayVersion)"
}

if ($Action -ne 'install' -and $PSBoundParameters.ContainsKey('Channel')) {
    Stop-Bootstrap 'Channel is only accepted with the install action.'
}

switch ($Action) {
    'install' { Invoke-Install }
    'uninstall' { Invoke-Uninstall }
    'status' { Invoke-Status }
}
