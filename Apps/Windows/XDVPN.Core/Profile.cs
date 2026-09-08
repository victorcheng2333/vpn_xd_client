using System.Security.Cryptography;
using System.Text;

namespace XDVPN.Core;

public sealed record VpnProfile(string Name = "工作网络", string Server = "vpn.xindong.com:8443", string Username = "", string AuthGroup = "")
{
    public VpnProfile Validate()
    {
        foreach (var field in new[] { Name, Server, Username, AuthGroup })
            if (field is null || Encoding.UTF8.GetByteCount(field) > 1024 || field.Any(char.IsControl))
                throw new ArgumentException("配置字段过长或包含控制字符。");
        var server = Server.Trim();
        if (!server.Contains("://", StringComparison.Ordinal)) server = "https://" + server;
        if (!Uri.TryCreate(server, UriKind.Absolute, out var uri) || uri.Scheme != "https" ||
            string.IsNullOrEmpty(uri.Host) || uri.Host.StartsWith('-') || uri.Port is < 1 or > 65535 ||
            uri.UserInfo.Length != 0 || uri.Query.Length != 0 || uri.Fragment.Length != 0 || server.Any(char.IsWhiteSpace) || server.Contains('\\'))
            throw new ArgumentException("请输入 HTTPS VPN 服务器，可包含端口和路径。");
        if (string.IsNullOrWhiteSpace(Username)) throw new ArgumentException("请填写 VPN 账号。");
        return this with { Name = string.IsNullOrWhiteSpace(Name) ? "工作网络" : Name.Trim(), Server = uri.AbsoluteUri, Username = Username.Trim(), AuthGroup = AuthGroup.Trim() };
    }

    public static void ValidatePassword(string password)
    {
        if (password is null || Encoding.UTF8.GetByteCount(password) is < 1 or > 4095 || password.IndexOfAny(['\0', '\r', '\n']) >= 0)
            throw new ArgumentException("密码为空、过长或包含不支持的字符。");
    }

    public string CredentialKey => "XDVPN/" + Convert.ToHexString(SHA256.HashData(Encoding.UTF8.GetBytes($"{Server}\n{Username}\n{AuthGroup}")));
}
