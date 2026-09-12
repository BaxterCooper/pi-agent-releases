#requires -Version 5.1
[CmdletBinding()]
param(
    [Parameter(Position = 0)]
    [ValidateSet('install', 'uninstall', 'status')]
    [string]$Action = 'install',

    [Parameter(Position = 1)]
    [string]$Channel = 'stable',

    [switch]$AllowDowngrade
)

Set-StrictMode -Version Latest
$ErrorActionPreference = 'Stop'

# Windows PowerShell 5.1 on an older .NET defaults to SSL3/TLS 1.0, which
# github.com refuses; opt in explicitly rather than failing at the first request.
# PowerShell 7 defaults to SystemDefault, which already negotiates TLS 1.2/1.3
# and honours OS policy; pinning protocols there would only remove choices.
if ($PSVersionTable.PSVersion.Major -lt 7) {
    $protocols = [Net.ServicePointManager]::SecurityProtocol -bor [Net.SecurityProtocolType]::Tls12
    if ([Enum]::GetNames([Net.SecurityProtocolType]) -contains 'Tls13') {
        $protocols = $protocols -bor [Net.SecurityProtocolType]::Tls13
    }
    [Net.ServicePointManager]::SecurityProtocol = $protocols
}

# No transfer may exceed this; the release installer is far smaller.
$MaxDownloadBytes = 536870912

# Trust anchor. The release workflow rewrites the table below when it mirrors
# this file to BaxterCooper/pi-agent-releases, so the copy a user runs carries
# the SHA-256 of every asset of every release it can install. The published
# `.sha256` sidecar travels with the installer and is only a secondary
# consistency check; it cannot attest to the installer it accompanies.
# BEGIN PINNED
# v0.3.3 OMP.Agent.app.tar.gz 097b1ce49e65a6f212ce822129548f1f6d46c66de04a2e59f1589d03ec5c32e3
# v0.3.3 OMP.Agent.app.tar.gz.sig d146856b5a152e07edfcda6bc99ce11bf6a14f989827d5977bdde127e6790dca
# v0.3.3 OMP.Agent_0.3.3_aarch64.dmg 435b92c485f6e42582999169ade34ea3b7ad32ac3d9051f16b3f7029dc7a0740
# v0.3.3 OMP.Agent_0.3.3_aarch64.dmg.sha256 324a27f088849c142f2b057ce9059ca42d3d6f8759d1196ea3e7ce7038ad2806
# v0.3.3 OMP.Agent_0.3.3_x64-setup.exe 8fe8777c4d3d8b1ab61c31074820123c0732fe9a1a3d49eed8af5bd466544a35
# v0.3.3 OMP.Agent_0.3.3_x64-setup.exe.sha256 e2babee57883a3b2767ecaccb2fcbb97cbc9f9ac2f11961c6a04bb0d6f9d05cb
# v0.3.3 OMP.Agent_0.3.3_x64-setup.exe.sig 894b036783a59d851e022ad49f27c8ddbbb580eb962e969151aaa931f256fd94
# END PINNED

# Generated source: BaxterCooper/pi-agent apps/desktop/bootstrap/install.ps1. The
# desktop release workflow publishes this file to BaxterCooper/pi-agent-releases.
$ApiRoot = 'https://api.github.com/repos/BaxterCooper/pi-agent-releases'
$ProductName = 'OMP Agent'
# Tauri's NSIS installer keys the per-user uninstall entry by product name, so a
# renamed product leaves the previous registration installed beside the new one.
$LegacyProductNames = @('Pi Agent')
$TempRoot = $null
# The app bundles no Bun and no OMP: it runs the bundled engine with the user's
# Bun against their global `@oh-my-pi/pi-coding-agent`, and fails to launch
# without both (`src-tauri/src/omp_install.rs`). The bootstrap provisions them.
# $OmpRange mirrors the `@oh-my-pi/pi-coding-agent` dependency in
# `packages/engine/package.json`; the two must stay equal.
$OmpPackage = '@oh-my-pi/pi-coding-agent'
$OmpRange = '^18.1.17'

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

# A prefix match alone is not a pin: `.../download/v1.2.3/../../other/asset` and
# its percent-encoded spellings still start with the prefix but resolve
# elsewhere. Require the remainder to be exactly one literal asset segment.
function Assert-PinnedDownloadUri {
    param(
        [Parameter(Mandatory = $true)][string]$Value,
        [Parameter(Mandatory = $true)][string]$Prefix,
        [Parameter(Mandatory = $true)][string]$Label
    )

    if (-not $Value.StartsWith($Prefix, [StringComparison]::Ordinal)) {
        Stop-Bootstrap "$Label was not published under $Prefix."
    }
    $afterScheme = $Value -replace '^[A-Za-z][A-Za-z0-9+.-]*://', ''
    if ($afterScheme.Contains('..') -or $afterScheme.Contains('//') -or $Value -match '(?i)%2e|%2f') {
        Stop-Bootstrap "$Label contained a traversal, empty path segment or encoded separator."
    }
    $remainder = $Value.Substring($Prefix.Length)
    if ($remainder -cnotmatch '^[A-Za-z0-9._-]+$') {
        Stop-Bootstrap "$Label did not resolve to a single asset name under $Prefix."
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
                    $declaredLength = $response.Content.Headers.ContentLength
                    if ($null -ne $declaredLength -and [Int64]$declaredLength -gt $MaxDownloadBytes) {
                        Stop-Bootstrap "The download from '$current' declares $declaredLength bytes, above the $MaxDownloadBytes byte ceiling."
                    }
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
    if ($null -eq $installerSizeValue -or ([string]$installerSizeValue -notmatch '^[0-9]+$')) {
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
    if ($installerSize -gt $MaxDownloadBytes) {
        Stop-Bootstrap "Installer asset '$installerName' declares $installerSize bytes, above the $MaxDownloadBytes byte ceiling."
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

    # The release contract publishes assets under exactly one prefix; anything
    # else in the JSON is a redirected or substituted host, not this release.
    $downloadPrefix = "https://github.com/BaxterCooper/pi-agent-releases/releases/download/$tag/"
    Assert-PinnedDownloadUri -Value $installerUrl -Prefix $downloadPrefix -Label "Installer asset '$installerName'"
    Assert-PinnedDownloadUri -Value $sidecarUrl -Prefix $downloadPrefix -Label "Checksum sidecar '$installerName.sha256'"

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
function Assert-PinnedAsset {
    param(
        [Parameter(Mandatory = $true)][string]$Path,
        [Parameter(Mandatory = $true)][string]$Tag,
        [Parameter(Mandatory = $true)][string]$AssetName
    )

    if ([string]::IsNullOrWhiteSpace($PSCommandPath) -or -not (Test-Path -LiteralPath $PSCommandPath -PathType Leaf)) {
        Stop-Bootstrap 'Could not read this script to load its pinned release table.'
    }
    $lines = @(Get-Content -LiteralPath $PSCommandPath)
    $begin = [Array]::IndexOf($lines, '# BEGIN PINNED')
    $end = [Array]::IndexOf($lines, '# END PINNED')
    if ($begin -lt 0 -or $end -le $begin) {
        Stop-Bootstrap 'This script carries no pinned release table; use the copy published in BaxterCooper/pi-agent-releases.'
    }
    $expected = $null
    for ($index = $begin + 1; $index -lt $end; $index++) {
        $fields = @(([string]$lines[$index]).Trim() -split '\s+')
        if ($fields.Count -ne 4 -or $fields[0] -cne '#' -or $fields[1] -cne $Tag -or $fields[2] -cne $AssetName) {
            continue
        }
        if ($fields[3] -cnotmatch '^[0-9a-f]{64}$') {
            Stop-Bootstrap "The pinned entry for '$AssetName' in $Tag is malformed."
        }
        $expected = [string]$fields[3]
        break
    }
    if ($null -eq $expected) {
        Stop-Bootstrap "Release $Tag pins no SHA-256 for '$AssetName' in this script; refusing to install an unpinned build."
    }
    if ((Get-Sha256 -Path $Path) -cne $expected) {
        Stop-Bootstrap "The downloaded '$AssetName' did not match the SHA-256 pinned for $Tag."
    }
}

function Get-VersionRank {
    param([Parameter(Mandatory = $true)][string]$Value)

    $core = @((($Value -split '\+', 2)[0]) -split '-', 2)
    $numbers = @(([string]$core[0]) -split '\.')
    if ($numbers.Count -ne 3) {
        return $null
    }
    $rank = New-Object 'System.Collections.Generic.List[int]'
    foreach ($number in $numbers) {
        if ([string]$number -cnotmatch '^(0|[1-9][0-9]*)$') {
            return $null
        }
        $rank.Add([int]$number)
    }
    $prerelease = @()
    if ($core.Count -gt 1 -and -not [string]::IsNullOrEmpty([string]$core[1])) {
        $prerelease = @(([string]$core[1]) -split '\.')
        foreach ($identifier in $prerelease) {
            if ([string]$identifier -cnotmatch '^[0-9A-Za-z-]+$') {
                return $null
            }
        }
    }
    return [pscustomobject]@{
        Core = $rank.ToArray()
        Prerelease = $prerelease
    }
}

# SemVer 11.4: numeric identifiers compare numerically, alphanumerics compare in
# ASCII order, and a numeric identifier always sorts below an alphanumeric one.
function Compare-PrereleaseIdentifier {
    param(
        [Parameter(Mandatory = $true)][AllowEmptyString()][string]$Left,
        [Parameter(Mandatory = $true)][AllowEmptyString()][string]$Right
    )

    $leftNumeric = $Left -cmatch '^[0-9]+$'
    $rightNumeric = $Right -cmatch '^[0-9]+$'
    if ($leftNumeric -and $rightNumeric) {
        $first = [decimal]$Left
        $second = [decimal]$Right
        if ($first -eq $second) {
            return 0
        }
        return $(if ($first -gt $second) { 1 } else { -1 })
    }
    if ($leftNumeric) {
        return -1
    }
    if ($rightNumeric) {
        return 1
    }
    $ordinal = [string]::CompareOrdinal($Left, $Right)
    if ($ordinal -eq 0) {
        return 0
    }
    return $(if ($ordinal -gt 0) { 1 } else { -1 })
}

function Compare-SemanticVersion {
    param(
        [Parameter(Mandatory = $true)][string]$Left,
        [Parameter(Mandatory = $true)][string]$Right
    )

    $first = Get-VersionRank -Value $Left
    $second = Get-VersionRank -Value $Right
    # Fail closed: a version this installer cannot rank is not proof that the
    # release is newer, so treat it as a downgrade and demand -AllowDowngrade.
    if ($null -eq $first -or $null -eq $second) {
        return 1
    }
    for ($index = 0; $index -lt $first.Core.Length; $index++) {
        if ($first.Core[$index] -ne $second.Core[$index]) {
            return $(if ($first.Core[$index] -gt $second.Core[$index]) { 1 } else { -1 })
        }
    }
    $leftPrerelease = @($first.Prerelease)
    $rightPrerelease = @($second.Prerelease)
    # A prerelease sorts below the release with the same core version.
    if ($leftPrerelease.Count -eq 0 -or $rightPrerelease.Count -eq 0) {
        if ($leftPrerelease.Count -eq $rightPrerelease.Count) {
            return 0
        }
        return $(if ($leftPrerelease.Count -eq 0) { 1 } else { -1 })
    }
    $shared = [Math]::Min($leftPrerelease.Count, $rightPrerelease.Count)
    for ($index = 0; $index -lt $shared; $index++) {
        $order = Compare-PrereleaseIdentifier -Left ([string]$leftPrerelease[$index]) -Right ([string]$rightPrerelease[$index])
        if ($order -ne 0) {
            return $order
        }
    }
    if ($leftPrerelease.Count -eq $rightPrerelease.Count) {
        return 0
    }
    return $(if ($leftPrerelease.Count -gt $rightPrerelease.Count) { 1 } else { -1 })
}

# The launcher's own search order (`omp_install.rs:67-78`): `$BUN_INSTALL\bin`
# first, because a GUI launch inherits a PATH that often predates the install.
function Find-BunExecutable {
    $candidates = @()
    if ($env:BUN_INSTALL) { $candidates += (Join-Path $env:BUN_INSTALL 'bin\bun.exe') }
    $onPath = @(Get-Command -Name 'bun.exe' -CommandType Application -ErrorAction SilentlyContinue)
    if ($onPath.Count -gt 0) { $candidates += [string]$onPath[0].Source }
    if ($env:USERPROFILE) { $candidates += (Join-Path $env:USERPROFILE '.bun\bin\bun.exe') }
    foreach ($candidate in $candidates) {
        if (Test-Path -LiteralPath $candidate -PathType Leaf) { return $candidate }
    }
    return $null
}

# The global root the launcher links the engine against
# (`omp_install.rs:117-130`), read straight from the installed manifest.
function Get-InstalledOmpVersion {
    param([Parameter(Mandatory = $true)][string]$BunPath)

    $roots = @()
    if ($env:BUN_INSTALL) { $roots += $env:BUN_INSTALL }
    if ($env:USERPROFILE) { $roots += (Join-Path $env:USERPROFILE '.bun') }
    $roots += [string](Split-Path -Parent (Split-Path -Parent $BunPath))
    foreach ($root in $roots) {
        if ([string]::IsNullOrWhiteSpace($root)) { continue }
        $manifest = Join-Path $root ('install\global\node_modules\' + $OmpPackage.Replace('/', '\') + '\package.json')
        if (-not (Test-Path -LiteralPath $manifest -PathType Leaf)) { continue }
        $found = [regex]::Match((Get-Content -LiteralPath $manifest -Raw), '"version"\s*:\s*"([^"]+)"')
        if ($found.Success -and (Test-SemanticVersion -Value $found.Groups[1].Value)) {
            return $found.Groups[1].Value
        }
    }
    return $null
}

# `^MAJOR.MINOR.PATCH`: at or above the pin and below the next major.
function Test-OmpVersionInRange {
    param([Parameter(Mandatory = $true)][string]$Version)

    $minimum = $OmpRange.TrimStart('^')
    if (($Version -split '\.')[0] -cne ($minimum -split '\.')[0]) { return $false }
    return (Compare-SemanticVersion -Left $Version -Right $minimum) -ge 0
}

# Idempotent: an existing Bun and an in-range OMP are left exactly as they are.
function Install-LaunchPrerequisite {
    $bun = Find-BunExecutable
    if ($null -eq $bun) {
        Write-Output 'Installing Bun, which the OMP Agent launcher requires.'
        $bunExit = Invoke-Executable -FilePath 'powershell.exe' `
            -Arguments '-NoProfile -ExecutionPolicy Bypass -Command "irm bun.sh/install.ps1|iex"' `
            -Purpose 'Bun installer'
        if ($bunExit -ne 0) {
            Stop-Bootstrap "The Bun installer failed with exit code $bunExit; install Bun and re-run."
        }
        $bun = Find-BunExecutable
        if ($null -eq $bun) { Stop-Bootstrap 'Bun is still not installed; install Bun and re-run.' }
    }
    $version = Get-InstalledOmpVersion -BunPath $bun
    if ($null -ne $version -and (Test-OmpVersionInRange -Version $version)) { return }
    Write-Output "Installing $OmpPackage@$OmpRange, which the OMP Agent launcher requires."
    $exitCode = Invoke-Executable -FilePath $bun -Arguments "add -g `"$OmpPackage@$OmpRange`"" -Purpose 'OMP package installer'
    if ($exitCode -ne 0) {
        Stop-Bootstrap "Could not install $OmpPackage@$OmpRange; run 'bun add -g $OmpPackage@$OmpRange' and re-run."
    }
    $version = Get-InstalledOmpVersion -BunPath $bun
    if ($null -eq $version -or -not (Test-OmpVersionInRange -Version $version)) {
        Stop-Bootstrap "$OmpPackage@$OmpRange is not installed under the Bun global root; the app cannot start without it."
    }
}

function Invoke-Install {
    Assert-WindowsX64
    # Before anything is downloaded or replaced: an app that cannot find Bun
    # and a global OMP installs cleanly and then fails at launch.
    Install-LaunchPrerequisite
    $release = Get-Release -RequestedChannel $Channel

    # An older tag surfacing as the resolved release must not silently replace a
    # patched build; require an explicit choice to go backwards.
    if (-not $AllowDowngrade) {
        $installed = Get-SinglePiAgentEntry -Purpose 'compare the installed version' -Optional
        if ($null -ne $installed -and (Compare-SemanticVersion -Left ([string]$installed.DisplayVersion) -Right $release.Version) -gt 0) {
            Stop-Bootstrap "Installed $ProductName $($installed.DisplayVersion) is newer than release $($release.Version); re-run with -AllowDowngrade to replace it."
        }
    }

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
        Assert-PinnedAsset -Path $installerPath -Tag $release.Tag -AssetName $release.InstallerName
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
# `-Optional` reports a malformed or ambiguous registration as absent instead of
# aborting: a broken leftover entry must not stop a fresh install from running.
# Callers that act on the entry itself leave it off and keep the hard failure.
function Get-SinglePiAgentEntry {
    param(
        [Parameter(Mandatory = $true)][string]$Purpose,
        [switch]$Optional
    )

    $reject = {
        param([string]$Message)
        if ($Optional) {
            Write-Warning "Ignoring the current-user OMP Agent registration: $Message"
            return
        }
        Stop-Bootstrap $Message
    }
    $entries = @(Get-PiAgentUninstallEntries)
    if ($entries.Count -eq 0) {
        return $null
    }
    if ($entries.Count -ne 1) {
        & $reject "Found multiple current-user OMP Agent uninstall entries while attempting to $Purpose."
        return $null
    }
    if ([string]::IsNullOrWhiteSpace($entries[0].DisplayVersion) -or -not (Test-SemanticVersion -Value $entries[0].DisplayVersion)) {
        & $reject "The current-user OMP Agent uninstall entry had no valid semantic DisplayVersion while attempting to $Purpose."
        return $null
    }
    if ([string]::IsNullOrWhiteSpace($entries[0].InstallLocation)) {
        & $reject "The current-user OMP Agent uninstall entry had no InstallLocation while attempting to $Purpose."
        return $null
    }
    try {
        $canonicalInstallLocation = Get-CanonicalInstallLocation -Value $entries[0].InstallLocation
    }
    catch {
        if (-not $Optional) {
            throw
        }
        Write-Warning "Ignoring the current-user OMP Agent registration: $($_.Exception.Message)"
        return $null
    }
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
