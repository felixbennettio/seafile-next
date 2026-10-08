[CmdletBinding()]
param(
    [ValidateSet('Install', 'Uninstall')][string]$Action = 'Install',
    [string]$PackageDirectory = $PSScriptRoot,
    [string]$RegistryRoot = 'HKLM:\Software'
)
$ErrorActionPreference = 'Stop'
$PackageDirectory = [IO.Path]::GetFullPath($PackageDirectory)
$dll = Join-Path $PackageDirectory 'seafile_shell_ext64.dll'
$exe = Join-Path $PackageDirectory 'seafile-applet.exe'
if ($RegistryRoot -eq 'HKLM:\Software') {
    $principal = [Security.Principal.WindowsPrincipal][Security.Principal.WindowsIdentity]::GetCurrent()
    if (-not $principal.IsInRole([Security.Principal.WindowsBuiltInRole]::Administrator)) {
        throw 'Run Install-WindowsIntegration.cmd or Uninstall-WindowsIntegration.cmd to grant Windows integration access.'
    }
}
if ($Action -eq 'Install' -and (-not (Test-Path $dll) -or -not (Test-Path $exe))) {
    throw 'Keep the integration files in the extracted Seafile Next application folder.'
}
$classes = Join-Path $RegistryRoot 'Classes'
$approved = Join-Path $RegistryRoot 'Microsoft\Windows\CurrentVersion\Shell Extensions\Approved'
$overlays = Join-Path $RegistryRoot 'Microsoft\Windows\CurrentVersion\Explorer\ShellIconOverlayIdentifiers'
$handlers = @(
    @{ Guid = '{D14BEDD3-4E05-4F2F-B0DE-C0381E6AE606}'; Name = 'SeafileNext'; Icon = $false },
    @{ Guid = '{D14BEDD3-4E05-4F2F-B0DE-C0381E6AE607}'; Name = 'SeafileNextNormal'; Icon = $true },
    @{ Guid = '{D14BEDD3-4E05-4F2F-B0DE-C0381E6AE608}'; Name = 'SeafileNextSyncing'; Icon = $true },
    @{ Guid = '{D14BEDD3-4E05-4F2F-B0DE-C0381E6AE609}'; Name = 'SeafileNextError'; Icon = $true },
    @{ Guid = '{D14BEDD3-4E05-4F2F-B0DE-C0381E6AE610}'; Name = 'SeafileNextPaused'; Icon = $true },
    @{ Guid = '{D14BEDD3-4E05-4F2F-B0DE-C0381E6AE611}'; Name = 'SeafileNextLockedByMe'; Icon = $true },
    @{ Guid = '{D14BEDD3-4E05-4F2F-B0DE-C0381E6AE612}'; Name = 'SeafileNextLockedByOthers'; Icon = $true }
)
function Set-Default([string]$Path, [string]$Value) {
    New-Item -Path $Path -Force | Out-Null
    Set-Item -LiteralPath $Path -Value $Value
}
function Default-Value([string]$Path) {
    if (Test-Path -LiteralPath $Path) { (Get-Item -LiteralPath $Path).GetValue('') }
}
foreach ($handler in $handlers) {
    $clsid = Join-Path $classes "CLSID\$($handler.Guid)"
    $server = Join-Path $clsid 'InProcServer32'
    $overlay = Join-Path $overlays $handler.Name
    if ($Action -eq 'Install') {
        Set-Default $clsid $handler.Name
        Set-Default $server $dll
        New-ItemProperty -Path $server -Name ThreadingModel -Value Apartment -PropertyType String -Force | Out-Null
        New-Item -Path $approved -Force | Out-Null
        New-ItemProperty -Path $approved -Name $handler.Guid -Value $handler.Name -PropertyType String -Force | Out-Null
        if ($handler.Icon) { Set-Default $overlay $handler.Guid }
    } elseif ((Default-Value $server) -eq $dll) {
        Remove-Item -LiteralPath $clsid -Recurse -Force
        if (Test-Path $approved) { Remove-ItemProperty -Path $approved -Name $handler.Guid -ErrorAction SilentlyContinue }
        if ((Default-Value $overlay) -eq $handler.Guid) { Remove-Item -LiteralPath $overlay -Recurse -Force }
    }
}
foreach ($kind in @('*', 'Directory', 'Directory\Background', 'Folder')) {
    $path = Join-Path $classes "$kind\shellex\ContextMenuHandlers\SeafileNext"
    if ($Action -eq 'Install') { Set-Default $path $handlers[0].Guid }
    elseif ((Default-Value $path) -eq $handlers[0].Guid -and (Default-Value (Join-Path $classes "CLSID\$($handlers[0].Guid)\InProcServer32")) -ne $dll) {
        # A later Seafile installation owns the shared COM identifier; preserve it.
        if (-not (Test-Path (Join-Path $classes "CLSID\$($handlers[0].Guid)"))) { Remove-Item -LiteralPath $path -Recurse -Force }
    }
}
$protocol = Join-Path $classes 'seafile'
$command = '"' + $exe + '" --open-local-file "%1"'
if ($Action -eq 'Install') {
    Set-Default $protocol 'URL:Seafile Next local file'
    New-ItemProperty -Path $protocol -Name 'URL Protocol' -Value '' -PropertyType String -Force | Out-Null
    Set-Default (Join-Path $protocol 'shell\open\command') $command
} elseif ((Default-Value (Join-Path $protocol 'shell\open\command')) -eq $command) {
    Remove-Item -LiteralPath $protocol -Recurse -Force
}
if ($RegistryRoot -eq 'HKLM:\Software') {
    Add-Type -TypeDefinition 'using System; using System.Runtime.InteropServices; public static class SeafileShellNotification { [DllImport("shell32.dll")] public static extern void SHChangeNotify(uint e, uint f, IntPtr a, IntPtr b); }'
    [SeafileShellNotification]::SHChangeNotify(0x08000000, 0, [IntPtr]::Zero, [IntPtr]::Zero)
}
Write-Host "Seafile Next Windows integration: $Action completed. Sign out and back in if Explorer still has an older extension loaded."
