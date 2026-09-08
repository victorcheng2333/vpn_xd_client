using System.Globalization;
using System.Windows;
using System.Windows.Media;
using XDVPN.Core;
namespace XDVPN.App;

public sealed class LatencyChart : FrameworkElement
{
    public static readonly DependencyProperty SamplesProperty = DependencyProperty.Register(nameof(Samples), typeof(IReadOnlyList<LogEntry>), typeof(LatencyChart), new FrameworkPropertyMetadata(null, FrameworkPropertyMetadataOptions.AffectsRender));
    public IReadOnlyList<LogEntry>? Samples { get => (IReadOnlyList<LogEntry>?)GetValue(SamplesProperty); set => SetValue(SamplesProperty, value); }
    protected override void OnRender(DrawingContext drawing)
    {
        base.OnRender(drawing);
        var muted = new SolidColorBrush(Color.FromRgb(105, 119, 111));
        void Label(string text, double x, double y)
        {
            var formatted = new FormattedText(text, CultureInfo.CurrentCulture, FlowDirection.LeftToRight, new Typeface("Segoe UI"), 11, muted, VisualTreeHelper.GetDpi(this).PixelsPerDip);
            drawing.DrawText(formatted, new Point(x, y));
        }
        var samples = Samples?.Where(e => e.DurationMs is >= 0 && e.Time >= DateTimeOffset.UtcNow.AddHours(-24)).ToArray() ?? [];
        if (samples.Length == 0) { Label("暂无成功连接样本", Math.Max(0, (ActualWidth - 100) / 2), ActualHeight / 2 - 8); return; }
        double left = 45, top = 12, width = Math.Max(1, ActualWidth - left - 16), height = Math.Max(1, ActualHeight - top - 27);
        double maximum = Math.Max(1, Math.Ceiling(samples.Max(e => e.DurationMs!.Value) / 1000));
        var grid = new Pen(new SolidColorBrush(Color.FromRgb(230, 234, 227)), 1);
        for (int row = 0; row <= 2; row++)
        {
            double y = top + height * row / 2;
            drawing.DrawLine(grid, new Point(left, y), new Point(left + width, y));
            Label($"{maximum * (2 - row) / 2:0.#} 秒", 0, y - 7);
        }
        var now = DateTimeOffset.UtcNow;
        for (int column = 0; column <= 4; column++)
        {
            double x = left + width * column / 4;
            Label(now.AddHours(-24 + column * 6).ToLocalTime().ToString("HH:mm"), x - 14, top + height + 8);
        }
        var green = new SolidColorBrush(Color.FromRgb(34, 120, 88));
        foreach (var sample in samples)
        {
            double x = left + width * Math.Clamp(1 - (now - sample.Time).TotalHours / 24, 0, 1);
            double y = top + height * (1 - sample.DurationMs!.Value / 1000 / maximum);
            drawing.DrawEllipse(green, null, new Point(x, y), 3.5, 3.5);
        }
    }
}
