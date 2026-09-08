using System.Text.Json;
using XDVPN.Core;
namespace XDVPN.Platform;

public sealed class RollingLog(string directory)
{
    private readonly object gate = new();
    public void Write(LogEntry entry)
    {
        lock (gate)
        {
            Directory.CreateDirectory(directory);
            var current = Path.Combine(directory, "activity.jsonl");
            if (File.Exists(current) && new FileInfo(current).Length >= 1024 * 1024)
            {
                for (var i = 3; i >= 1; i--)
                {
                    var from = i == 1 ? current : Path.Combine(directory, $"activity.{i - 1}.jsonl");
                    var to = Path.Combine(directory, $"activity.{i}.jsonl");
                    if (File.Exists(from)) File.Move(from, to, true);
                }
            }
            File.AppendAllText(current, JsonSerializer.Serialize(entry) + "\n");
        }
    }
    public IEnumerable<LogEntry> ReadRecent()
    {
        if (!Directory.Exists(directory)) yield break;
        foreach (var file in Directory.EnumerateFiles(directory, "activity*.jsonl"))
            foreach (var line in File.ReadLines(file))
            {
                LogEntry? entry; try { entry = JsonSerializer.Deserialize<LogEntry>(line); } catch (JsonException) { continue; }
                if (entry is not null && entry.Time >= DateTimeOffset.UtcNow.AddHours(-24)) yield return entry;
            }
    }
}
