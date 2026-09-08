using System;
using System.IO;
using System.IO.Compression;
using System.Security.AccessControl;
using System.Security.Principal;
using System.Text;

internal static class SetupTests
{
    private static int passed;
    private static void Check(bool condition, string name) { if (!condition) throw new Exception(name); passed++; Console.WriteLine("PASS " + name); }
    private static MemoryStream Payload(params string[] names)
    {
        var bytes = new MemoryStream();
        using (var zip = new ZipArchive(bytes, ZipArchiveMode.Create, true))
            foreach (string name in names)
                using (var writer = new StreamWriter(zip.CreateEntry(name).Open())) writer.Write("fixture payload");
        bytes.Position = 0; return bytes;
    }
    private static bool Rejects(string root, params string[] names)
    {
        try { using (var bytes=Payload(names)) Setup.ExtractPayload(bytes,root,null); return false; }
        catch (IOException) { return true; }
        catch (ArgumentException) { return true; }
    }
    public static int Main()
    {
        string temporary = Path.GetFullPath(Path.GetTempPath()).TrimEnd(Path.DirectorySeparatorChar);
        string root = Path.Combine(temporary,"XDVPN-setup-test-"+Guid.NewGuid().ToString("N"));
        Directory.CreateDirectory(root);
        try
        {
            SecurityIdentifier owner; Guid operation;
            string sid=WindowsIdentity.GetCurrent().User.Value;
            string id=Guid.NewGuid().ToString("N");
            Check(Setup.ParseWorkerRequest(new[]{"--install-elevated",sid,id},out owner,out operation) && owner.Value==sid,"Canonical owner SID and operation GUID accepted");
            foreach(string invalid in new[]{"S-1-5-21-1-2-3-1001 -Command injected","BA","invalid",""})
                Check(!Setup.ParseWorkerRequest(new[]{"--install-elevated",invalid,id},out owner,out operation),"Non-canonical worker SID rejected");
            Check(!Setup.ParseWorkerRequest(new[]{"--install-elevated",sid,"../escape"},out owner,out operation),"Invalid operation path rejected");
            Check(!Setup.ParseWorkerRequest(new[]{"--install-elevated",sid,id,"extra"},out owner,out operation),"Unexpected worker arguments rejected");
            Check(!Setup.ParseWorkerRequest(new[]{"--install-elevated",sid,Guid.Empty.ToString("N")},out owner,out operation),"Empty operation rejected");
            string stage=Setup.StagePath(Guid.ParseExact(id,"N"));
            Check(Path.GetDirectoryName(stage)==Environment.GetFolderPath(Environment.SpecialFolder.ProgramFiles) && Path.GetFileName(stage)=="XDVPN-Setup-"+id,"Privileged stage is fixed beneath Program Files");
            foreach(bool directory in new[]{false,true})
            {
                var security=Setup.StageSecurity(directory,WindowsIdentity.GetCurrent().User);
                Check(security.AreAccessRulesProtected && security.GetOwner(typeof(SecurityIdentifier)).Value=="S-1-5-32-544","Staging descriptor has trusted owner and protected DACL");
                var rules=security.GetAccessRules(true,true,typeof(SecurityIdentifier));
                Check(rules.Count==3,"Staging descriptor only grants admins, SYSTEM and reader");
                foreach(FileSystemAccessRule rule in rules)
                {
                    string principal=rule.IdentityReference.Value;
                    Check(rule.AccessControlType==AccessControlType.Allow && (principal=="S-1-5-18" || principal=="S-1-5-32-544" || principal==sid),"Staging has no unexpected ACE");
                    if(principal==sid) Check((rule.FileSystemRights & (FileSystemRights.Write | FileSystemRights.Delete | FileSystemRights.ChangePermissions | FileSystemRights.TakeOwnership))==0,"Original user can read but cannot mutate elevated staging");
                }
            }
            string valid=Path.Combine(root,"valid");
            using(var bytes=Payload("install.ps1","runtime/openconnect.exe"))Setup.ExtractPayload(bytes,valid,null);
            Check(File.ReadAllText(Path.Combine(valid,"runtime/openconnect.exe"))=="fixture payload","Ordinary extract-only payload remains usable");
            Check(Rejects(valid,"install.ps1"),"Existing extraction directory rejected without replacement");
            Check(File.ReadAllText(Path.Combine(valid,"install.ps1"))=="fixture payload","Existing extracted content preserved");
            foreach(string invalid in new[]{"../escaped.txt","..\\escaped.txt","C:\\escaped.txt","file.txt:payload"})
                Check(Rejects(Path.Combine(root,Guid.NewGuid().ToString("N")),invalid),"Traversal, rooted path or alternate stream rejected");
            Check(!File.Exists(Path.Combine(root,"escaped.txt")),"Traversal never wrote outside its extraction directory");
            Check(Rejects(Path.Combine(root,"duplicate"),"same.txt","SAME.TXT"),"Duplicate Windows file aliases rejected");
            Console.WriteLine("Setup isolated checks passed: "+passed); return 0;
        }
        catch(Exception error){Console.Error.WriteLine(error);return 1;}
        finally
        {
            string resolved=Path.GetFullPath(root);
            if(Path.GetDirectoryName(resolved)==temporary && Path.GetFileName(resolved).StartsWith("XDVPN-setup-test-",StringComparison.Ordinal))Directory.Delete(resolved,true);
        }
    }
}
