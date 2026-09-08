using System.Security.AccessControl;
using System.Security.Principal;
namespace XDVPN.Platform;

public static class ServiceDataSecurity
{
    // The installer's binding SID and route journal are authority-bearing data.
    // Refuse stale or pre-created permissive ACLs before reading either of them.
    public static void Validate(string root, bool includeChildren = true)
    {
        var directory = new DirectoryInfo(root);
        ValidateEntry(directory, requireProtected: true);
        ValidateEntry(new FileInfo(Path.Combine(root, "owner.sid")));
        if (!includeChildren)
        {
            // Hook processes run while trusted writers update journals/logs. The
            // service validated existing descendants before starting those writers.
            foreach (var name in new[] { "sessions", "logs" })
            {
                var child = new DirectoryInfo(Path.Combine(root, name));
                if (child.Exists) ValidateEntry(child);
            }
            return;
        }
        // Logs are writable by SYSTEM too; a legacy permissive child must not
        // turn append/rotation into a privileged write through a reparse point.
        var pending = new Stack<FileSystemInfo>(); pending.Push(directory);
        var count = 0;
        while (pending.TryPop(out var entry))
        {
            if (++count > 20000) throw new IOException("服务数据目录过大，请修复安装。");
            ValidateEntry(entry);
            if (entry is DirectoryInfo folder)
                foreach (var child in folder.EnumerateFileSystemInfos()) pending.Push(child);
        }
    }
    private static void ValidateEntry(FileSystemInfo entry, bool requireProtected = false)
    {
        entry.Refresh();
        if (!entry.Exists || (entry.Attributes & FileAttributes.ReparsePoint) != 0) throw new IOException("服务数据路径不受信任，请修复安装。");
        FileSystemSecurity security = entry is DirectoryInfo directory ? directory.GetAccessControl() : ((FileInfo)entry).GetAccessControl();
        ValidateDescriptor(security, requireProtected);
    }
    internal static void ValidateDescriptor(FileSystemSecurity security, bool requireProtected = false)
    {
        bool Trusted(IdentityReference? identity) => identity is SecurityIdentifier sid &&
            (sid.IsWellKnown(WellKnownSidType.LocalSystemSid) || sid.IsWellKnown(WellKnownSidType.BuiltinAdministratorsSid));
        if (!Trusted(security.GetOwner(typeof(SecurityIdentifier))) || (requireProtected && !security.AreAccessRulesProtected))
            throw new IOException("服务数据所有权不受信任，请修复安装。");
        var systemCanRead = false;
        foreach (FileSystemAccessRule rule in security.GetAccessRules(true, true, typeof(SecurityIdentifier)))
        {
            if (rule.AccessControlType == AccessControlType.Deny)
                throw new IOException("服务数据包含冲突的拒绝权限，请修复安装。");
            if (rule.AccessControlType == AccessControlType.Allow && !Trusted(rule.IdentityReference))
                throw new IOException("服务数据允许非特权账户访问，请修复安装。");
            if (rule.IdentityReference is SecurityIdentifier sid && sid.IsWellKnown(WellKnownSidType.LocalSystemSid) &&
                rule.AccessControlType == AccessControlType.Allow && (rule.PropagationFlags & PropagationFlags.InheritOnly) == 0 && (rule.FileSystemRights & FileSystemRights.FullControl) == FileSystemRights.FullControl)
                systemCanRead = true;
        }
        if (!systemCanRead) throw new IOException("服务数据权限不完整，请修复安装。");
    }
}
