using System;
using System.ComponentModel;
using System.Diagnostics;
using System.Drawing;
using System.IO;
using System.IO.Compression;
using System.Reflection;
using System.Security.AccessControl;
using System.Security.Principal;
using System.Threading.Tasks;
using System.Windows.Forms;

[assembly: AssemblyTitle("XD VPN Setup")]
[assembly: AssemblyDescription("XD VPN Windows x64 preview installer")]
[assembly: AssemblyVersion("0.1.4.0")]

internal static class Setup
{
    [STAThread]
    private static int Main(string[] args)
    {
        // Packaging verification never elevates or installs a service.
        if (args.Length == 2 && args[0] == "--extract-only")
        {
            try { Extract(args[1], null); return 0; } catch { return 1; }
        }
        if (args.Length != 0)
        {
            SecurityIdentifier owner; Guid operation;
            if (!ParseWorkerRequest(args, out owner, out operation)) return 3;
            return InstallElevated(owner, operation);
        }
        Application.EnableVisualStyles();
        Application.SetCompatibleTextRenderingDefault(false);
        Application.Run(new Installer());
        return 0;
    }

    internal static bool ParseWorkerRequest(string[] args, out SecurityIdentifier owner, out Guid operation)
    {
        owner = null; operation = Guid.Empty;
        if (args.Length != 3 || args[0] != "--install-elevated" || !Guid.TryParseExact(args[2], "N", out operation) || operation == Guid.Empty) return false;
        try { owner = new SecurityIdentifier(args[1]); }
        catch (ArgumentException) { return false; }
        // Canonical SID text only; nothing supplied here is evaluated as a command.
        return owner.Value == args[1] && owner.IsAccountSid();
    }

    internal static string StagePath(Guid operation)
    {
        return Path.Combine(Environment.GetFolderPath(Environment.SpecialFolder.ProgramFiles), "XDVPN-Setup-" + operation.ToString("N"));
    }

    internal static FileSystemSecurity StageSecurity(bool directory, SecurityIdentifier reader)
    {
        FileSystemSecurity security = directory ? (FileSystemSecurity)new DirectorySecurity() : new FileSecurity();
        security.SetAccessRuleProtection(true, false);
        security.SetOwner(new SecurityIdentifier(WellKnownSidType.BuiltinAdministratorsSid, null));
        InheritanceFlags inheritance = directory ? InheritanceFlags.ContainerInherit | InheritanceFlags.ObjectInherit : InheritanceFlags.None;
        foreach (WellKnownSidType sid in new[] { WellKnownSidType.LocalSystemSid, WellKnownSidType.BuiltinAdministratorsSid })
            security.AddAccessRule(new FileSystemAccessRule(new SecurityIdentifier(sid, null), FileSystemRights.FullControl, inheritance, PropagationFlags.None, AccessControlType.Allow));
        security.AddAccessRule(new FileSystemAccessRule(reader, FileSystemRights.ReadAndExecute, inheritance, PropagationFlags.None, AccessControlType.Allow));
        return security;
    }

    private static void CheckParents(string path)
    {
        for (DirectoryInfo parent = new DirectoryInfo(path).Parent; parent != null; parent = parent.Parent)
            if (parent.Exists && (parent.Attributes & FileAttributes.ReparsePoint) != 0)
                throw new IOException("安装暂存目录的父路径不能是重解析点。");
    }

    private static void CreateStageDirectory(string path, string root, SecurityIdentifier reader)
    {
        if (!path.StartsWith(root, StringComparison.OrdinalIgnoreCase)) throw new IOException("Invalid staging path.");
        if (path != root) CreateStageDirectory(Path.GetDirectoryName(path), root, reader);
        if (!Directory.Exists(path)) Directory.CreateDirectory(path, (DirectorySecurity)StageSecurity(true, reader));
        var item = new DirectoryInfo(path);
        if ((item.Attributes & FileAttributes.ReparsePoint) != 0) throw new IOException("安装暂存目录不能是重解析点。");
        string actual = item.GetAccessControl(AccessControlSections.Access | AccessControlSections.Owner).GetSecurityDescriptorSddlForm(AccessControlSections.Access | AccessControlSections.Owner);
        string expected = StageSecurity(true, reader).GetSecurityDescriptorSddlForm(AccessControlSections.Access | AccessControlSections.Owner);
        if (actual.Replace("D:PAI(", "D:P(") != expected.Replace("D:PAI(", "D:P(")) throw new IOException("安装暂存目录权限不安全。");
    }

    internal static void Extract(string destination, SecurityIdentifier reader)
    {
        using (Stream payload = Assembly.GetExecutingAssembly().GetManifestResourceStream("XDVPN.Payload.zip"))
            ExtractPayload(payload, destination, reader);
    }

    internal static void ExtractPayload(Stream payload, string destination, SecurityIdentifier reader)
    {
        string root = Path.GetFullPath(destination).TrimEnd(Path.DirectorySeparatorChar);
        if (Directory.Exists(root) || File.Exists(root)) throw new IOException("解压目录已存在，请使用一个新目录。");
        CheckParents(root);
        if (reader == null) Directory.CreateDirectory(root);
        else CreateStageDirectory(root, root, reader);
        string prefix = root + Path.DirectorySeparatorChar;
        using (ZipArchive archive = new ZipArchive(payload, ZipArchiveMode.Read, true))
        {
            foreach (ZipArchiveEntry entry in archive.Entries)
            {
                if (entry.FullName.IndexOf(':') >= 0 || entry.FullName.IndexOfAny(Path.GetInvalidPathChars()) >= 0)
                    throw new IOException("安装包包含无效路径。");
                string path = Path.GetFullPath(Path.Combine(root, entry.FullName));
                if (!path.StartsWith(prefix, StringComparison.OrdinalIgnoreCase)) throw new IOException("安装包包含无效路径。");
                string directory = String.IsNullOrEmpty(entry.Name) ? path.TrimEnd(Path.DirectorySeparatorChar) : Path.GetDirectoryName(path);
                if (reader == null) Directory.CreateDirectory(directory); else CreateStageDirectory(directory, root, reader);
                if (String.IsNullOrEmpty(entry.Name)) continue;
                // Privileged objects receive their trusted owner/DACL at creation,
                // rather than exposing a user-owned object before a later ACL pass.
                using (Stream input = entry.Open())
                using (FileStream output = reader == null
                    ? new FileStream(path, FileMode.CreateNew, FileAccess.Write, FileShare.None)
                    : new FileStream(path, FileMode.CreateNew, FileSystemRights.Write, FileShare.None, 81920, FileOptions.None, (FileSecurity)StageSecurity(false, reader)))
                    input.CopyTo(output);
            }
        }
    }

    private static int InstallElevated(SecurityIdentifier owner, Guid operation)
    {
        if (!new WindowsPrincipal(WindowsIdentity.GetCurrent()).IsInRole(WindowsBuiltInRole.Administrator)) return 4;
        string stage = StagePath(operation);
        try
        {
            Extract(stage, owner);
            ProcessStartInfo start = new ProcessStartInfo
            {
                FileName = Path.Combine(Environment.GetFolderPath(Environment.SpecialFolder.System), @"WindowsPowerShell\v1.0\powershell.exe"),
                Arguments = "-NoLogo -NoProfile -NonInteractive -ExecutionPolicy Bypass -File \"" + Path.Combine(stage, "install.ps1") + "\" -NoLaunch -OwnerSid " + owner.Value,
                WorkingDirectory = stage,
                UseShellExecute = false,
                CreateNoWindow = true,
                RedirectStandardOutput = true,
                RedirectStandardError = true
            };
            using (Process child = Process.Start(start))
            {
                Task<string> output = child.StandardOutput.ReadToEndAsync();
                Task<string> error = child.StandardError.ReadToEndAsync();
                child.WaitForExit(); Task.WaitAll(output, error);
                if (child.ExitCode != 0)
                {
                    WriteStageLog(stage, "bootstrap.log", output.Result + "\n" + error.Result, owner);
                    if (!File.Exists(Path.Combine(stage, "install-error.txt"))) WriteStageLog(stage, "install-error.txt", error.Result, owner);
                    return child.ExitCode;
                }
            }
            // This path is fixed beneath Program Files and contains this operation's GUID.
            if (String.Equals(Path.GetFullPath(stage), StagePath(operation), StringComparison.OrdinalIgnoreCase))
            { try { Directory.Delete(stage, true); } catch { } }
            return 0;
        }
        catch (Exception error)
        {
            try { if (Directory.Exists(stage)) WriteStageLog(stage, "bootstrap-error.txt", error.Message, owner); } catch { }
            return 1;
        }
    }

    private static void WriteStageLog(string stage, string name, string text, SecurityIdentifier owner)
    {
        string path = Path.Combine(stage, name);
        using (var file = new FileStream(path, FileMode.Create, FileSystemRights.Write, FileShare.None, 4096, FileOptions.None, (FileSecurity)StageSecurity(false, owner)))
        using (var writer = new StreamWriter(file)) writer.Write(text);
    }

    private sealed class Installer : Form
    {
        private readonly Label status;
        private readonly Button install;
        private readonly ProgressBar progress;
        private bool busy;
        internal Installer()
        {
            Text = "XD VPN 安装程序";
            Icon = Icon.ExtractAssociatedIcon(Application.ExecutablePath);
            ClientSize = new Size(510, 260); FormBorderStyle = FormBorderStyle.FixedDialog;
            MaximizeBox = false; StartPosition = FormStartPosition.CenterScreen;
            Font = new Font("Microsoft YaHei UI", 10); BackColor = Color.FromArgb(245, 248, 245);
            Controls.Add(new Label { Text = "安装 XD VPN", Font = new Font(Font.FontFamily, 21, FontStyle.Bold), ForeColor = Color.FromArgb(25, 69, 54), Location = new Point(28, 24), AutoSize = true });
            Controls.Add(new Label { Text = "Windows x64 预览版\n包含客户端、后台服务和 VPN 引擎。", Location = new Point(30, 80), Size = new Size(450, 50) });
            status = new Label { Text = "安装到 Program Files\\XD VPN，安装时需要管理员授权。", Location = new Point(30, 143), Size = new Size(450, 42) };
            Controls.Add(status);
            progress = new ProgressBar { Location = new Point(30, 202), Size = new Size(295, 22), Visible = false, Style = ProgressBarStyle.Marquee };
            Controls.Add(progress);
            install = new Button { Text = "安装", Location = new Point(355, 195), Size = new Size(120, 38) };
            install.Click += Install; Controls.Add(install); AcceptButton = install;
            FormClosing += delegate(object sender, FormClosingEventArgs e) { if (busy) e.Cancel = true; };
        }
        private async void Install(object sender, EventArgs e)
        {
            if (install.Text == "完成") { Close(); return; }
            busy = true; install.Enabled = false; progress.Visible = true;
            status.Text = "正在请求管理员授权…";
            Guid operation = Guid.NewGuid();
            string stage = StagePath(operation);
            try
            {
                if (!Environment.Is64BitOperatingSystem) throw new NotSupportedException("此安装包需要 64 位 Windows。");
                foreach (Process process in Process.GetProcessesByName("XDVPN.App"))
                    using (process) throw new IOException("XD VPN 仍在运行。请从托盘菜单退出应用后重试；本次未停止服务。");
                SecurityIdentifier owner = WindowsIdentity.GetCurrent().User;
                int result = await Task.Run(() =>
                {
                    // Elevate the installer EXE itself before any privileged payload
                    // exists. The elevated process extracts its own embedded resource.
                    using (FileStream selfLock = new FileStream(Application.ExecutablePath, FileMode.Open, FileAccess.Read, FileShare.Read))
                    using (Process child = Process.Start(new ProcessStartInfo
                    {
                        FileName = Application.ExecutablePath,
                        Arguments = "--install-elevated " + owner.Value + " " + operation.ToString("N"),
                        UseShellExecute = true, Verb = "runas", WindowStyle = ProcessWindowStyle.Hidden
                    })) { child.WaitForExit(); return child.ExitCode; }
                });
                if (result != 0)
                {
                    string detail = "安装进程退出，代码 " + result + "。";
                    foreach (string file in new[] { "install-error.txt", "bootstrap-error.txt" })
                        if (File.Exists(Path.Combine(stage, file))) { detail = File.ReadAllText(Path.Combine(stage, file)); break; }
                    string[] lines = detail.Split(new[] { '\r', '\n' }, StringSplitOptions.RemoveEmptyEntries);
                    string summary = lines.Length == 0 ? "安装进程异常退出。" : lines[0];
                    if (summary.Contains("tray menu")) summary = "XD VPN 仍在运行。请从托盘菜单退出后重试。";
                    else if (summary.Contains("hash mismatch") || summary.Contains("Wintun signature")) summary = "安装包校验失败，请重新获取完整安装包后重试。";
                    else if (summary.Contains("another Windows account")) summary = "已有安装属于其他 Windows 账户，请使用原账户升级。";
                    else if (summary.Contains("cleanup is incomplete")) summary = "旧版仍有待清理的网络会话，请打开旧版完成断开后重试。";
                    throw new IOException("安装未完成：\n\n" + summary + (Directory.Exists(stage) ? "\n\n诊断目录：\n" + stage : ""));
                }
                // Only the unelevated parent launches the normal user UI. An
                // explicitly elevated invocation leaves launch to the Start menu.
                if (!new WindowsPrincipal(WindowsIdentity.GetCurrent()).IsInRole(WindowsBuiltInRole.Administrator))
                    try { Process.Start(Path.Combine(Environment.GetFolderPath(Environment.SpecialFolder.ProgramFiles), @"XD VPN\XDVPN.App.exe")); } catch { }
                status.Text = "安装完成。可从开始菜单打开 XD VPN。"; install.Text = "完成";
            }
            catch (Win32Exception error)
            {
                status.Text = "安装未完成，可点击安装重试。";
                MessageBox.Show(this, error.NativeErrorCode == 1223 ? "管理员授权已取消。尚未执行安装。" : error.Message, "XD VPN 安装", MessageBoxButtons.OK, MessageBoxIcon.Error);
            }
            catch (Exception error)
            {
                status.Text = "安装未完成，可点击安装重试。";
                MessageBox.Show(this, error.Message, "XD VPN 安装", MessageBoxButtons.OK, MessageBoxIcon.Error);
            }
            finally { busy = false; install.Enabled = true; progress.Visible = false; }
        }
    }
}
