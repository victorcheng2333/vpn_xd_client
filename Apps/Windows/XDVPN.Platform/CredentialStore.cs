using System.ComponentModel;
using System.Runtime.InteropServices;
using XDVPN.Core;
namespace XDVPN.Platform;

public static class CredentialStore
{
    public static string? Read(VpnProfile profile)
    {
        if (!CredRead(profile.CredentialKey, 1, 0, out var pointer))
        { if (Marshal.GetLastWin32Error() == 1168) return null; throw new Win32Exception(); }
        try { var value = Marshal.PtrToStructure<Credential>(pointer); return Marshal.PtrToStringUni(value.Blob, checked((int)value.BlobSize / 2)); }
        finally { CredFree(pointer); }
    }
    public static void Save(VpnProfile profile, string password)
    {
        VpnProfile.ValidatePassword(password);
        var buffer = Marshal.StringToCoTaskMemUni(password);
        try
        {
            var value = new Credential { Type = 1, TargetName = profile.CredentialKey, UserName = profile.Username, BlobSize = checked((uint)password.Length * 2), Blob = buffer, Persist = 2 };
            if (!CredWrite(ref value, 0)) throw new Win32Exception();
        }
        finally { Marshal.ZeroFreeCoTaskMemUnicode(buffer); }
    }
    public static void Delete(VpnProfile profile)
    { if (!CredDelete(profile.CredentialKey, 1, 0) && Marshal.GetLastWin32Error() != 1168) throw new Win32Exception(); }
    [StructLayout(LayoutKind.Sequential, CharSet = CharSet.Unicode)] private struct Credential
    {
        public uint Flags, Type; public string? TargetName, Comment; public long LastWritten;
        public uint BlobSize; public IntPtr Blob; public uint Persist, AttributeCount; public IntPtr Attributes;
        public string? TargetAlias, UserName;
    }
    [DllImport("advapi32.dll", EntryPoint = "CredReadW", CharSet = CharSet.Unicode, SetLastError = true)] private static extern bool CredRead(string name, uint type, uint flags, out IntPtr credential);
    [DllImport("advapi32.dll", EntryPoint = "CredWriteW", CharSet = CharSet.Unicode, SetLastError = true)] private static extern bool CredWrite(ref Credential credential, uint flags);
    [DllImport("advapi32.dll", EntryPoint = "CredDeleteW", CharSet = CharSet.Unicode, SetLastError = true)] private static extern bool CredDelete(string name, uint type, uint flags);
    [DllImport("advapi32.dll")] private static extern void CredFree(IntPtr buffer);
}
