param([Parameter(Mandatory)][string]$PackageDirectory)
$ErrorActionPreference = 'Stop'
$PackageDirectory = [IO.Path]::GetFullPath($PackageDirectory)
Add-Type -TypeDefinition @'
using System;
using System.Runtime.InteropServices;
public static class SeafileExtensionTest {
    [DllImport("kernel32.dll", CharSet = CharSet.Unicode, SetLastError = true)]
    static extern IntPtr LoadLibrary(string path);
    [DllImport("kernel32.dll", SetLastError = true)]
    static extern IntPtr GetProcAddress(IntPtr dll, string symbol);
    [DllImport("kernel32.dll")] static extern bool FreeLibrary(IntPtr dll);
    [UnmanagedFunctionPointer(CallingConvention.StdCall)]
    delegate int Factory(ref Guid clsid, ref Guid iid, out IntPtr result);
    public static void Validate(string path) {
        var dll = LoadLibrary(path);
        if (dll == IntPtr.Zero) throw new Exception("Extension cannot load: " + Marshal.GetLastWin32Error());
        try {
            var symbol = GetProcAddress(dll, "DllGetClassObject");
            if (symbol == IntPtr.Zero) throw new Exception("COM class factory export missing");
            var call = Marshal.GetDelegateForFunctionPointer<Factory>(symbol);
            var iid = new Guid("00000001-0000-0000-C000-000000000046");
            foreach (var tail in new[] {"06", "07", "08", "09", "10", "11", "12"}) {
                var clsid = new Guid("D14BEDD3-4E05-4F2F-B0DE-C0381E6AE6" + tail);
                IntPtr factory;
                var result = call(ref clsid, ref iid, out factory);
                if (result != 0 || factory == IntPtr.Zero) throw new Exception("Cannot instantiate factory " + clsid);
                Marshal.Release(factory);
            }
        } finally { FreeLibrary(dll); }
    }
}
'@
[SeafileExtensionTest]::Validate((Join-Path $PackageDirectory 'seafile_shell_ext64.dll'))
# Use an isolated registry subtree and placeholder executable; never register
# an Explorer handler or start a daemon on the validation runner.
$root = 'HKCU:\Software\SeafileNextIntegrationTests\' + [Guid]::NewGuid().ToString('N')
$exe = Join-Path $PackageDirectory 'seafile-applet.exe'
[IO.File]::WriteAllText($exe, 'isolated registry fixture')
$script = Join-Path $PackageDirectory 'WindowsIntegration.ps1'
try {
    & $script -Action Install -PackageDirectory $PackageDirectory -RegistryRoot $root
    $class = Join-Path $root 'Classes\CLSID\{D14BEDD3-4E05-4F2F-B0DE-C0381E6AE606}\InProcServer32'
    if ((Get-Item -LiteralPath $class).GetValue('') -ne (Join-Path $PackageDirectory 'seafile_shell_ext64.dll')) { throw 'Wrong extension path' }
    $menu = Join-Path $root 'Classes\*\shellex\ContextMenuHandlers\SeafileNext'
    if ((Get-Item -LiteralPath $menu).GetValue('') -ne '{D14BEDD3-4E05-4F2F-B0DE-C0381E6AE606}') { throw 'File menu not registered' }
    $protocol = Join-Path $root 'Classes\seafile\shell\open\command'
    if ((Get-Item -LiteralPath $protocol).GetValue('') -ne ('"' + $exe + '" --open-local-file "%1"')) { throw 'Protocol command is not quoted correctly' }
    $overlays = Join-Path $root 'Microsoft\Windows\CurrentVersion\Explorer\ShellIconOverlayIdentifiers'
    if (@(Get-ChildItem $overlays).Count -ne 6) { throw 'Sync and lock overlays missing' }
    & $script -Action Uninstall -PackageDirectory $PackageDirectory -RegistryRoot $root
    if (Test-Path -LiteralPath $class) { throw 'Owned class registration survived uninstall' }
    if (Test-Path -LiteralPath $menu) { throw 'Owned menu registration survived uninstall' }
    if (Test-Path -LiteralPath $protocol) { throw 'Owned protocol registration survived uninstall' }
    & $script -Action Install -PackageDirectory $PackageDirectory -RegistryRoot $root
    Set-Item -LiteralPath $class -Value 'C:\AnotherInstall\seafile_shell_ext64.dll'
    Set-Item -LiteralPath $protocol -Value '"C:\AnotherInstall\seafile-applet.exe" --open-local-file "%1"'
    & $script -Action Uninstall -PackageDirectory $PackageDirectory -RegistryRoot $root
    if ((Get-Item -LiteralPath $class).GetValue('') -ne 'C:\AnotherInstall\seafile_shell_ext64.dll') { throw 'Another installation was removed' }
    if ((Get-Item -LiteralPath $protocol).GetValue('') -ne '"C:\AnotherInstall\seafile-applet.exe" --open-local-file "%1"') { throw 'Another protocol handler was removed' }
    Write-Host 'Extension load, seven COM factories, six overlays, protocol quoting, uninstall and ownership guards passed.'
} finally {
    Remove-Item -LiteralPath $root -Recurse -Force -ErrorAction SilentlyContinue
    Remove-Item -LiteralPath $exe -Force
}
