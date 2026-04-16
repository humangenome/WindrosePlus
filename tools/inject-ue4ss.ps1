# inject-ue4ss.ps1 - Inject UE4SS.dll into a running process via CreateRemoteThread + LoadLibraryW
# This bypasses the QueueUserAPC issue where dedicated servers never enter an alertable wait
param(
    [Parameter(Mandatory=$true)]
    [int]$ProcessId,

    [Parameter(Mandatory=$true)]
    [string]$DllPath
)

# Resolve full path
$DllPath = [System.IO.Path]::GetFullPath($DllPath)
if (-not (Test-Path -LiteralPath $DllPath)) {
    Write-Error "DLL not found: $DllPath"
    exit 1
}

# P/Invoke signatures
Add-Type -TypeDefinition @"
using System;
using System.Runtime.InteropServices;

public class Injector {
    [DllImport("kernel32.dll", SetLastError = true)]
    public static extern IntPtr OpenProcess(uint dwDesiredAccess, bool bInheritHandle, int dwProcessId);

    [DllImport("kernel32.dll", SetLastError = true)]
    public static extern IntPtr VirtualAllocEx(IntPtr hProcess, IntPtr lpAddress, uint dwSize, uint flAllocationType, uint flProtect);

    [DllImport("kernel32.dll", SetLastError = true)]
    public static extern bool WriteProcessMemory(IntPtr hProcess, IntPtr lpBaseAddress, byte[] lpBuffer, uint nSize, out int lpNumberOfBytesWritten);

    [DllImport("kernel32.dll", SetLastError = true)]
    public static extern IntPtr CreateRemoteThread(IntPtr hProcess, IntPtr lpThreadAttributes, uint dwStackSize, IntPtr lpStartAddress, IntPtr lpParameter, uint dwCreationFlags, out int lpThreadId);

    [DllImport("kernel32.dll", SetLastError = true)]
    public static extern IntPtr GetModuleHandle(string lpModuleName);

    [DllImport("kernel32.dll", SetLastError = true)]
    public static extern IntPtr GetProcAddress(IntPtr hModule, string lpProcName);

    [DllImport("kernel32.dll", SetLastError = true)]
    public static extern uint WaitForSingleObject(IntPtr hHandle, uint dwMilliseconds);

    [DllImport("kernel32.dll", SetLastError = true)]
    public static extern bool CloseHandle(IntPtr hObject);

    [DllImport("kernel32.dll", SetLastError = true)]
    public static extern bool VirtualFreeEx(IntPtr hProcess, IntPtr lpAddress, uint dwSize, uint dwFreeType);
}
"@

$PROCESS_ALL_ACCESS = 0x001F0FFF
$MEM_COMMIT = 0x1000
$MEM_RESERVE = 0x2000
$MEM_RELEASE = 0x8000
$PAGE_READWRITE = 0x04

# Open target process
$hProcess = [Injector]::OpenProcess($PROCESS_ALL_ACCESS, $false, $ProcessId)
if ($hProcess -eq [IntPtr]::Zero) {
    Write-Error "Failed to open process $ProcessId (error: $([System.Runtime.InteropServices.Marshal]::GetLastWin32Error()))"
    exit 1
}

try {
    # Get LoadLibraryW address (same in all processes due to ASLR base sharing for kernel32)
    $kernel32 = [Injector]::GetModuleHandle("kernel32.dll")
    $loadLibraryAddr = [Injector]::GetProcAddress($kernel32, "LoadLibraryW")
    if ($loadLibraryAddr -eq [IntPtr]::Zero) {
        Write-Error "Failed to get LoadLibraryW address"
        exit 1
    }

    # Encode DLL path as UTF-16LE (what LoadLibraryW expects)
    $dllBytes = [System.Text.Encoding]::Unicode.GetBytes($DllPath + "`0")
    $dllBytesSize = [uint32]$dllBytes.Length

    # Allocate memory in target process for the DLL path
    $remoteMem = [Injector]::VirtualAllocEx($hProcess, [IntPtr]::Zero, $dllBytesSize, ($MEM_COMMIT -bor $MEM_RESERVE), $PAGE_READWRITE)
    if ($remoteMem -eq [IntPtr]::Zero) {
        Write-Error "Failed to allocate memory in target process"
        exit 1
    }

    # Write DLL path to target process memory
    $bytesWritten = 0
    $writeResult = [Injector]::WriteProcessMemory($hProcess, $remoteMem, $dllBytes, $dllBytesSize, [ref]$bytesWritten)
    if (-not $writeResult) {
        Write-Error "Failed to write DLL path to target process"
        exit 1
    }

    # Create remote thread calling LoadLibraryW with our DLL path
    $threadId = 0
    $hThread = [Injector]::CreateRemoteThread($hProcess, [IntPtr]::Zero, 0, $loadLibraryAddr, $remoteMem, 0, [ref]$threadId)
    if ($hThread -eq [IntPtr]::Zero) {
        Write-Error "Failed to create remote thread (error: $([System.Runtime.InteropServices.Marshal]::GetLastWin32Error()))"
        exit 1
    }

    # Wait for injection to complete (30 second timeout)
    $waitResult = [Injector]::WaitForSingleObject($hThread, 30000)
    if ($waitResult -ne 0) {
        Write-Error "Remote thread timed out or failed (wait result: $waitResult)"
        exit 1
    }

    # Clean up
    [Injector]::CloseHandle($hThread) | Out-Null
    [Injector]::VirtualFreeEx($hProcess, $remoteMem, 0, $MEM_RELEASE) | Out-Null

    Write-Output "UE4SS injected successfully into PID $ProcessId"
}
finally {
    [Injector]::CloseHandle($hProcess) | Out-Null
}
