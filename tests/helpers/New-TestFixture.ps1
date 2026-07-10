function New-TestFixture {
    [CmdletBinding()]
    param([Parameter(Mandatory)][string]$Root)

    $rootPath = [IO.Path]::GetFullPath($Root)
    $cache = Join-Path $rootPath 'cache-a'
    $nested = Join-Path $cache 'nested'
    $documents = Join-Path $rootPath 'documents'
    $denied = Join-Path $rootPath 'denied'
    New-Item -ItemType Directory -Path $nested,$documents,$denied -Force | Out-Null

    $primary = Join-Path $cache 'a.bin'
    [IO.File]::WriteAllBytes($primary, (New-Object byte[] 2048))
    [IO.File]::WriteAllBytes((Join-Path $nested 'b.bin'), (New-Object byte[] 1024))
    [IO.File]::WriteAllBytes((Join-Path $documents 'report.txt'), (New-Object byte[] 512))

    $linkPath = Join-Path $rootPath 'link-to-documents'
    $junctionCreated = $false
    try {
        New-Item -ItemType Junction -Path $linkPath -Target $documents -ErrorAction Stop | Out-Null
        $junctionCreated = $true
    } catch {}

    $hardLinksCreated = $false
    try {
        New-Item -ItemType HardLink -Path (Join-Path $rootPath 'hardlink-a.bin') -Target $primary -ErrorAction Stop | Out-Null
        New-Item -ItemType HardLink -Path (Join-Path $rootPath 'hardlink-b.bin') -Target $primary -ErrorAction Stop | Out-Null
        $hardLinksCreated = $true
    } catch {
        Remove-Item -LiteralPath (Join-Path $rootPath 'hardlink-a.bin') -Force -ErrorAction SilentlyContinue
        Remove-Item -LiteralPath (Join-Path $rootPath 'hardlink-b.bin') -Force -ErrorAction SilentlyContinue
    }

    return [pscustomobject]@{
        Root = $rootPath
        LinkPath = $linkPath
        JunctionCreated = $junctionCreated
        HardLinksCreated = $hardLinksCreated
        DeniedPath = $denied
        DeniedCreated = $false
    }
}
