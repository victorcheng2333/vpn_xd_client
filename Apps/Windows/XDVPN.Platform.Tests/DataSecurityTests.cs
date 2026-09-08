using System.Security.AccessControl;
using System.Security.Principal;
using XDVPN.Platform;

internal static class DataSecurityTests
{
    public static void Run()
    {
        var admin = new SecurityIdentifier(WellKnownSidType.BuiltinAdministratorsSid, null);
        var system = new SecurityIdentifier(WellKnownSidType.LocalSystemSid, null);
        var everyone = new SecurityIdentifier(WellKnownSidType.WorldSid, null);
        DirectorySecurity Descriptor()
        {
            var d = new DirectorySecurity(); d.SetOwner(admin); d.SetAccessRuleProtection(true, false);
            foreach (var sid in new[] { admin, system }) d.AddAccessRule(new FileSystemAccessRule(sid, FileSystemRights.FullControl, InheritanceFlags.ContainerInherit | InheritanceFlags.ObjectInherit, PropagationFlags.None, AccessControlType.Allow));
            return d;
        }
        void Rejected(DirectorySecurity d, string name, bool protect = false)
        {
            try { ServiceDataSecurity.ValidateDescriptor(d, protect); }
            catch (IOException) { Console.WriteLine("PASS data trust rejects " + name); return; }
            throw new Exception("Unsafe data ACL accepted: " + name);
        }
        ServiceDataSecurity.ValidateDescriptor(Descriptor(), true); Console.WriteLine("PASS data trust accepts installer Admin/SYSTEM descriptor");
        var all = Descriptor(); all.AddAccessRule(new FileSystemAccessRule(everyone, FileSystemRights.FullControl, AccessControlType.Allow)); Rejected(all, "pre-created explicit Everyone FullControl");
        var read = Descriptor(); read.AddAccessRule(new FileSystemAccessRule(everyone, FileSystemRights.Read, AccessControlType.Allow)); Rejected(read, "unexpected read grants on private data");
        var owner = Descriptor(); owner.SetOwner(everyone); Rejected(owner, "untrusted owner");
        var inherited = Descriptor(); inherited.SetAccessRuleProtection(false, true); Rejected(inherited, "inheriting data root", true);
        var missing = Descriptor(); missing.PurgeAccessRules(system); Rejected(missing, "missing SYSTEM access");
        var deny = Descriptor(); deny.AddAccessRule(new FileSystemAccessRule(everyone, FileSystemRights.FullControl, AccessControlType.Deny)); Rejected(deny, "conflicting Everyone Deny");
        var inheritOnly = Descriptor(); inheritOnly.PurgeAccessRules(system); inheritOnly.AddAccessRule(new FileSystemAccessRule(system, FileSystemRights.FullControl, InheritanceFlags.ContainerInherit, PropagationFlags.InheritOnly, AccessControlType.Allow)); Rejected(inheritOnly, "SYSTEM grant applies only to children");
        Console.WriteLine("8/8 data trust tests passed");
    }
}
