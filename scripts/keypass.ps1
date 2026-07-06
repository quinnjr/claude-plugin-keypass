# keypass.ps1 — Windows Credential Manager backend for keypass.
# Called by the keypass sh dispatcher; same contract:
#   get -> secret on stdout, set <- secret on stdin, del,
#   export <key>... -> sh export lines on stdout (one process, one Add-Type).
# Zero dependencies: raw advapi32 CredRead/CredWrite/CredDelete via Add-Type.
param(
    [Parameter(Mandatory)][ValidateSet('get', 'set', 'del', 'export')][string]$Cmd,
    [Parameter(Mandatory)][string]$Service,
    [Parameter(ValueFromRemainingArguments)][string[]]$Keys
)
$ErrorActionPreference = 'Stop'
if (-not $Keys) {
    [Console]::Error.WriteLine('keypass: no key given')
    exit 64
}
# Key names are interpolated into eval'd export lines — reject non-identifiers.
foreach ($k in $Keys) {
    if ($k -notmatch '^[A-Za-z_][A-Za-z0-9_]*$') {
        [Console]::Error.WriteLine("keypass: invalid key name '$k' (must match [A-Za-z_][A-Za-z0-9_]*)")
        exit 64
    }
}

Add-Type -Namespace KeyPass -Name CredMan -MemberDefinition @'
[StructLayout(LayoutKind.Sequential, CharSet = CharSet.Unicode)]
public struct CREDENTIAL {
    public uint Flags;
    public uint Type;
    public string TargetName;
    public string Comment;
    public System.Runtime.InteropServices.ComTypes.FILETIME LastWritten;
    public uint CredentialBlobSize;
    public IntPtr CredentialBlob;
    public uint Persist;
    public uint AttributeCount;
    public IntPtr Attributes;
    public string TargetAlias;
    public string UserName;
}
[DllImport("advapi32.dll", CharSet = CharSet.Unicode, SetLastError = true)]
public static extern bool CredReadW(string target, uint type, uint flags, out IntPtr credential);
[DllImport("advapi32.dll", CharSet = CharSet.Unicode, SetLastError = true)]
public static extern bool CredWriteW(ref CREDENTIAL credential, uint flags);
[DllImport("advapi32.dll", CharSet = CharSet.Unicode, SetLastError = true)]
public static extern bool CredDeleteW(string target, uint type, uint flags);
[DllImport("advapi32.dll")]
public static extern void CredFree(IntPtr buffer);
'@

$CRED_TYPE_GENERIC = 1
$CRED_PERSIST_LOCAL_MACHINE = 2

# Returns the secret, or $null if the credential genuinely does not exist
# (ERROR_NOT_FOUND). Throws on any other CredRead failure so callers can tell
# "missing" apart from "keyring locked / access denied".
function Get-KeypassSecret([string]$target) {
    $ptr = [IntPtr]::Zero
    if (-not [KeyPass.CredMan]::CredReadW($target, $CRED_TYPE_GENERIC, 0, [ref]$ptr)) {
        $err = [System.Runtime.InteropServices.Marshal]::GetLastWin32Error()
        if ($err -eq 1168) { return $null }  # ERROR_NOT_FOUND
        throw "CredRead failed for '$target' (Win32 error $err)"
    }
    try {
        $cred = [System.Runtime.InteropServices.Marshal]::PtrToStructure($ptr, [type][KeyPass.CredMan+CREDENTIAL])
        return [System.Runtime.InteropServices.Marshal]::PtrToStringUni($cred.CredentialBlob, [int]($cred.CredentialBlobSize / 2))
    }
    finally {
        [KeyPass.CredMan]::CredFree($ptr)
    }
}

switch ($Cmd) {
    'get' {
        $key = $Keys[0]
        try { $secret = Get-KeypassSecret "$Service/$key" }
        catch { [Console]::Error.WriteLine("keypass: keyring unavailable — $_"); exit 1 }
        if ($null -eq $secret) {
            [Console]::Error.WriteLine("keypass: missing $Service/$key")
            exit 1
        }
        [Console]::Out.Write($secret)
    }
    'set' {
        $key = $Keys[0]
        $secret = [Console]::In.ReadToEnd().TrimEnd("`r", "`n")
        $blob = [System.Runtime.InteropServices.Marshal]::StringToCoTaskMemUni($secret)
        $cred = New-Object -TypeName 'KeyPass.CredMan+CREDENTIAL'
        $cred.Type = $CRED_TYPE_GENERIC
        $cred.TargetName = "$Service/$key"
        $cred.CredentialBlobSize = [uint32]($secret.Length * 2)
        $cred.CredentialBlob = $blob
        $cred.Persist = $CRED_PERSIST_LOCAL_MACHINE
        $cred.UserName = $key
        try {
            if (-not [KeyPass.CredMan]::CredWriteW([ref]$cred, 0)) {
                $err = [System.Runtime.InteropServices.Marshal]::GetLastWin32Error()
                [Console]::Error.WriteLine("keypass: CredWrite failed (Win32 error $err)")
                exit 1
            }
        }
        finally {
            [System.Runtime.InteropServices.Marshal]::ZeroFreeCoTaskMemUnicode($blob)
        }
    }
    'del' {
        $key = $Keys[0]
        if (-not [KeyPass.CredMan]::CredDeleteW("$Service/$key", $CRED_TYPE_GENERIC, 0)) {
            $err = [System.Runtime.InteropServices.Marshal]::GetLastWin32Error()
            if ($err -ne 1168) {  # anything but ERROR_NOT_FOUND is a real failure
                [Console]::Error.WriteLine("keypass: delete failed for '$Service/$key' (Win32 error $err)")
                exit 1
            }
            # absent key -> success (idempotent, matches secret-tool/security)
        }
    }
    'export' {
        $rc = 0
        foreach ($k in $Keys) {
            try { $secret = Get-KeypassSecret "$Service/$k" }
            catch { [Console]::Error.WriteLine("keypass: keyring unavailable for $Service/$k"); $rc = 1; continue }
            if ($null -eq $secret) {
                [Console]::Error.WriteLine("keypass: missing $Service/$k")
                $rc = 1
                continue
            }
            # format must match the sh export arm — `export K='v'` with '\''
            # single-quote escaping; change both or eval diverges per-OS
            $quoted = $secret -replace "'", "'\''"
            [Console]::Out.Write("export $k='$quoted'`n")
        }
        exit $rc
    }
}
