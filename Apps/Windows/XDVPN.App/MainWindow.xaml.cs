using System.ComponentModel;
using System.Diagnostics;
using System.Drawing;
using System.Runtime.InteropServices;
using System.Windows;
using System.Windows.Controls;
using System.Windows.Input;
using System.Windows.Media.Animation;
using System.Windows.Threading;
using XDVPN.Core;
using XDVPN.Platform;
using Forms = System.Windows.Forms;
namespace XDVPN.App;

public partial class MainWindow : Window
{
    private readonly VpnModel model;
    private readonly DispatcherTimer timer = new() { Interval = TimeSpan.FromSeconds(1) };
    private readonly Forms.NotifyIcon? tray;
    private readonly Forms.ToolStripMenuItem? action, trayAuto;
    private ConnectionState? previousState;
    private bool? previousDataVerified;
    private bool quitting, ended, reveal, syncingPassword;
    private int ticks;
    private string page = "Connection";
    public MainWindow() : this(new VpnModel(), true) { }

    // Rendering tests use a fake model and disable all runtime integration.
    public MainWindow(VpnModel model, bool startRuntime)
    {
        this.model = model;
        InitializeComponent(); DataContext = model; LoadProfile();
        model.ProfileRequested += NavigateToProfile;
        model.PropertyChanged += ModelChanged;
        model.Events.CollectionChanged += EventsChanged;
        if (startRuntime)
        {
            Width = Math.Min(Width, SystemParameters.WorkArea.Width);
            Height = Math.Min(Height, SystemParameters.WorkArea.Height);
            MinWidth = Math.Min(MinWidth, SystemParameters.WorkArea.Width);
            MinHeight = Math.Min(MinHeight, SystemParameters.WorkArea.Height);
            tray = new Forms.NotifyIcon { Text = "XD VPN", Icon = CreateIcon(model.State, model.DataVerified), Visible = true, ContextMenuStrip = new Forms.ContextMenuStrip() };
            tray.DoubleClick += (_, _) => ShowMain();
            tray.ContextMenuStrip.Items.Add("打开 XD VPN", null, (_, _) => ShowMain());
            action = new Forms.ToolStripMenuItem(model.ActionTitle, null, async (_, _) => await model.Act());
            tray.ContextMenuStrip.Items.Add(action);
            trayAuto = new Forms.ToolStripMenuItem("自动连接", null, async (_, _) => await ChangeAuto(!model.AutoConnect));
            tray.ContextMenuStrip.Items.Add(trayAuto);
            tray.ContextMenuStrip.Items.Add(new Forms.ToolStripSeparator());
            tray.ContextMenuStrip.Items.Add("VPN 配置", null, (_, _) => { ShowMain(); ShowPage("Profile"); });
            tray.ContextMenuStrip.Items.Add("连接日志", null, (_, _) => { ShowMain(); ShowPage("Activity"); });
            tray.ContextMenuStrip.Items.Add(new Forms.ToolStripSeparator());
            tray.ContextMenuStrip.Items.Add("退出并断开", null, (_, _) => Quit());
            timer.Tick += async (_, _) => { model.Tick(); if (++ticks % 2 == 0) await model.Poll(); };
            timer.Start(); _ = model.Poll();
            Activated += (_, _) => model.RefreshCredentials();
        }
        PreviewKeyDown += async (_, e) =>
        {
            if (Keyboard.Modifiers != ModifierKeys.Control) return;
            if (e.Key == Key.K) { e.Handled = true; await model.Act(); }
            else if (e.Key == Key.S && page == "Profile" && model.CanEdit) { e.Handled = true; SaveProfile(this, new RoutedEventArgs()); }
            else if (e.Key == Key.Q && startRuntime) { e.Handled = true; Quit(); }
        };
        ModelChanged(null, new PropertyChangedEventArgs(""));
    }
    public void ShowMain() { Show(); if (WindowState == WindowState.Minimized) WindowState = WindowState.Normal; Activate(); }
    private void WindowClosing(object? sender, CancelEventArgs e)
    {
        if (!quitting) { e.Cancel = true; Hide(); ClearPassword(); }
    }
    public void EndSession()
    {
        if (ended) return;
        ended = quitting = true; timer.Stop();
        model.ProfileRequested -= NavigateToProfile; model.PropertyChanged -= ModelChanged; model.Events.CollectionChanged -= EventsChanged;
        model.Dispose();
        if (tray is not null) { tray.Visible = false; tray.Icon?.Dispose(); tray.ContextMenuStrip?.Dispose(); tray.Dispose(); }
    }
    private void Quit() { EndSession(); System.Windows.Application.Current.Shutdown(); }
    private void NavigateToProfile() { ShowMain(); ShowPage("Profile"); Username.Focus(); }
    private void Navigate(object sender, RoutedEventArgs e)
    {
        if (ConnectionPage is null) return;
        SelectPage((sender as RadioButton)?.Tag as string ?? "Connection");
    }
    public void ShowPage(string name)
    {
        var navigation = name switch { "Profile" => ProfileNav, "Quality" => QualityNav, "Activity" => ActivityNav, _ => ConnectionNav };
        if (navigation.IsChecked != true) navigation.IsChecked = true;
        else SelectPage(name);
    }
    private void SelectPage(string name)
    {
        if (page != name) { ClearPassword(); if (name == "Profile") LoadProfile(); }
        page = name;
        ConnectionPage.Visibility = name == "Connection" ? Visibility.Visible : Visibility.Collapsed;
        ProfilePage.Visibility = name == "Profile" ? Visibility.Visible : Visibility.Collapsed;
        QualityPage.Visibility = name == "Quality" ? Visibility.Visible : Visibility.Collapsed;
        ActivityPage.Visibility = name == "Activity" ? Visibility.Visible : Visibility.Collapsed;
        PageTitle.Text = name switch { "Profile" => "VPN 配置", "Quality" => "连接质量", "Activity" => "连接日志", _ => "工作网络，一键就绪。" };
        Eyebrow.Text = name switch { "Profile" => "MAKE IT YOURS", "Quality" => "CONNECTION QUALITY", "Activity" => "CONNECTION JOURNAL", _ => "A LITTLE CLOSER TO WORK" };
        PageScroll.ScrollToTop();
        PageScroll.VerticalScrollBarVisibility = name == "Activity" ? ScrollBarVisibility.Disabled : ScrollBarVisibility.Auto;
        UpdateLayoutSizing();
    }
    private void LoadProfile()
    {
        ProfileName.Text = model.Profile.Name; Server.Text = model.Profile.Server;
        Username.Text = model.Profile.Username; AuthGroup.Text = model.Profile.AuthGroup;
        UpdatePasswordPlaceholder();
    }
    private void ContentSizeChanged(object sender, SizeChangedEventArgs e) => UpdateLayoutSizing();
    private void UpdateLayoutSizing()
    {
        if (DashboardColumns is null) return;
        bool narrow = MainContent.ActualWidth < 660;
        ProfileColumn.Width = new GridLength(narrow ? 0 : 226);
        DashboardGap.Width = new GridLength(narrow ? 0 : 18);
        Grid.SetRow(ProfileSummary, narrow ? 1 : 0); Grid.SetColumn(ProfileSummary, narrow ? 0 : 2);
        ProfileSummary.Margin = new Thickness(0, narrow ? 18 : 0, 0, 0);
        QualityMetrics.Columns = MainContent.ActualWidth < 520 ? 1 : 3;
        foreach (Border card in QualityMetrics.Children) card.Margin = QualityMetrics.Columns == 1 ? new Thickness(0, 0, 0, 10) : new Thickness(0, 0, card == QualityMetrics.Children[2] ? 0 : 10, 0);
        ActivityPage.Height = Math.Max(280, PageScroll.ActualHeight - 4);
        SidebarMessage.Visibility = RootLayout.ActualHeight < 670 ? Visibility.Collapsed : Visibility.Visible;
    }
    private void ModelChanged(object? sender, PropertyChangedEventArgs e)
    {
        if (ended) return;
        if (action is not null) { action.Text = model.ActionTitle; action.Enabled = model.CanAct; }
        if (trayAuto is not null) { trayAuto.Checked = model.AutoConnect; trayAuto.Enabled = model.CanChangePreferences; }
        if (tray is not null) tray.Text = "XD VPN · " + model.Title;
        if (previousState != model.State || previousDataVerified != model.DataVerified)
        {
            previousState = model.State;
            previousDataVerified = model.DataVerified;
            if (tray is not null) { var old = tray.Icon; tray.Icon = CreateIcon(model.State, model.DataVerified); old?.Dispose(); }
            OrbitRotation.BeginAnimation(System.Windows.Media.RotateTransform.AngleProperty, model.IsProgress && SystemParameters.ClientAreaAnimation
                ? new DoubleAnimation(0, 360, TimeSpan.FromSeconds(2)) { RepeatBehavior = RepeatBehavior.Forever } : null);
        }
        UpdatePasswordPlaceholder();
    }
    private void EventsChanged(object? sender, System.Collections.Specialized.NotifyCollectionChangedEventArgs e)
    {
        if (page != "Activity" || model.Events.Count == 0) return;
        // Preserve reading position when the user has deliberately scrolled upward.
        var scroll = FindVisualChild<ScrollViewer>(ActivityList);
        if (scroll is null || scroll.ScrollableHeight - scroll.VerticalOffset < 24)
            Dispatcher.BeginInvoke(() => { if (!ended && model.Events.Count > 0) ActivityList.ScrollIntoView(model.Events[^1]); });
    }
    private static T? FindVisualChild<T>(DependencyObject root) where T : DependencyObject
    {
        for (int i = 0; i < System.Windows.Media.VisualTreeHelper.GetChildrenCount(root); i++)
        {
            var child = System.Windows.Media.VisualTreeHelper.GetChild(root, i);
            if (child is T value) return value;
            var nested = FindVisualChild<T>(child); if (nested is not null) return nested;
        }
        return null;
    }
    private async void ConnectionAction(object sender, RoutedEventArgs e) => await model.Act();
    private async void RefreshService(object sender, RoutedEventArgs e) => await model.Poll();
    private void OpenProfile(object sender, RoutedEventArgs e) => ShowPage("Profile");
    private void OpenActivity(object sender, RoutedEventArgs e) => ShowPage("Activity");
    private void DismissIssue(object sender, RoutedEventArgs e) => model.DismissIssue();
    private void SaveProfile(object sender, RoutedEventArgs e)
    {
        try { model.SaveProfile(new(ProfileName.Text, Server.Text, Username.Text, AuthGroup.Text), Password.Password); ClearPassword(); ShowPage("Connection"); }
        catch (Exception ex) when (IsUiError(ex)) { model.Report(ex.Message); PageScroll.ScrollToTop(); }
    }
    private void ForgetPassword(object sender, RoutedEventArgs e)
    {
        if (System.Windows.MessageBox.Show(this, "删除此配置保存在 Windows 中的 VPN 密码？", "忘记密码", MessageBoxButton.OKCancel, MessageBoxImage.Question) != MessageBoxResult.OK) return;
        try { model.ForgetPassword(); ClearPassword(); } catch (Exception ex) when (IsUiError(ex)) { model.Report(ex.Message); }
    }
    private static bool IsUiError(Exception ex) => ex is ArgumentException or IOException or Win32Exception or UnauthorizedAccessException or OperationCanceledException or TimeoutException or System.Security.SecurityException;
    private async Task ChangeAuto(bool value)
    {
        try { await model.SetAuto(value); } catch (Exception ex) when (IsUiError(ex)) { model.Report("保存偏好失败：" + ex.Message); }
        finally { AutoToggle.GetBindingExpression(System.Windows.Controls.Primitives.ToggleButton.IsCheckedProperty)?.UpdateTarget(); }
    }
    private async void AutoChanged(object sender, RoutedEventArgs e) => await ChangeAuto(AutoToggle.IsChecked == true);
    private void StartupChanged(object sender, RoutedEventArgs e)
    {
        try { model.SetStartup(StartupToggle.IsChecked == true); } catch (Exception ex) when (IsUiError(ex)) { model.Report("保存登录启动设置失败：" + ex.Message); }
        finally { StartupToggle.GetBindingExpression(System.Windows.Controls.Primitives.ToggleButton.IsCheckedProperty)?.UpdateTarget(); }
    }
    private void TogglePassword(object sender, RoutedEventArgs e)
    {
        reveal = !reveal;
        syncingPassword = true; RevealedPassword.Text = reveal ? Password.Password : ""; syncingPassword = false;
        Password.Visibility = reveal ? Visibility.Collapsed : Visibility.Visible;
        RevealedPassword.Visibility = reveal ? Visibility.Visible : Visibility.Collapsed;
        RevealButton.Content = reveal ? "隐藏" : "显示";
        System.Windows.Automation.AutomationProperties.SetName(RevealButton, reveal ? "隐藏密码" : "显示密码");
        UpdatePasswordPlaceholder();
    }
    private void PasswordChanged(object sender, RoutedEventArgs e) => UpdatePasswordPlaceholder();
    private void RevealedPasswordChanged(object sender, TextChangedEventArgs e)
    {
        if (!syncingPassword && reveal) Password.Password = RevealedPassword.Text;
        UpdatePasswordPlaceholder();
    }
    private void UpdatePasswordPlaceholder()
    {
        if (PasswordPlaceholder is null) return;
        PasswordPlaceholder.Text = model.HasPassword ? "******" : "输入 VPN 密码";
        PasswordPlaceholder.Visibility = Password.Password.Length == 0 ? Visibility.Visible : Visibility.Collapsed;
    }
    private void ClearPassword()
    {
        Password.Clear(); syncingPassword = true; RevealedPassword.Clear(); syncingPassword = false;
        reveal = false; Password.Visibility = Visibility.Visible; RevealedPassword.Visibility = Visibility.Collapsed;
        RevealButton.Content = "显示"; System.Windows.Automation.AutomationProperties.SetName(RevealButton, "显示密码");
        UpdatePasswordPlaceholder();
    }
    private void CopyLogs(object sender, RoutedEventArgs e)
    {
        try { Clipboard.SetText(string.Join(Environment.NewLine, model.Events.Select(row => row.CopyText))); model.ShowToast("日志已复制"); }
        catch (ExternalException) { model.Report("剪贴板暂时不可用，请重试。"); }
    }
    private void ClearLogs(object sender, RoutedEventArgs e) => model.ClearEvents();
    private void OpenLogs(object sender, RoutedEventArgs e)
    {
        try { var dir = Path.Combine(Paths.UserData, "logs"); Directory.CreateDirectory(dir); Process.Start(new ProcessStartInfo(dir) { UseShellExecute = true }); }
        catch (Exception ex) when (IsUiError(ex)) { model.Report("无法打开日志目录：" + ex.Message); }
    }
    private static Icon CreateIcon(ConnectionState state, bool verified)
    {
        using var bitmap = new Bitmap(32, 32); using var graphics = Graphics.FromImage(bitmap);
        graphics.SmoothingMode = System.Drawing.Drawing2D.SmoothingMode.AntiAlias;
        var color = state switch { ConnectionState.Connected => verified ? Color.FromArgb(34, 120, 88) : Color.FromArgb(148, 107, 55), ConnectionState.Connecting or ConnectionState.Recovering => Color.FromArgb(50, 108, 176), ConnectionState.Failed => Color.FromArgb(180, 69, 56), _ => Color.FromArgb(98, 109, 122) };
        using var brush = new SolidBrush(color);
        graphics.FillPolygon(brush, [new PointF(16, 2), new PointF(29, 7), new PointF(27, 22), new PointF(16, 30), new PointF(5, 22), new PointF(3, 7)]);
        using var pen = new Pen(Color.White, 2.7f);
        if (state == ConnectionState.Connected && verified) graphics.DrawLines(pen, [new PointF(9, 16), new PointF(14, 21), new PointF(23, 11)]);
        else if (state is ConnectionState.Failed or ConnectionState.Connected) { graphics.DrawLine(pen, 16, 9, 16, 17); graphics.DrawEllipse(pen, 15, 21, 1, 1); }
        else if (state is ConnectionState.WaitingNetwork or ConnectionState.WaitingRetry) { graphics.DrawLine(pen, 12, 10, 12, 22); graphics.DrawLine(pen, 20, 10, 20, 22); }
        else if (state is ConnectionState.Connecting or ConnectionState.Recovering) graphics.DrawArc(pen, 9, 9, 14, 14, 20, 280);
        else { graphics.DrawLine(pen, 11, 11, 21, 21); graphics.DrawLine(pen, 21, 11, 11, 21); }
        var handle = bitmap.GetHicon();
        try { using var borrowed = System.Drawing.Icon.FromHandle(handle); return (System.Drawing.Icon)borrowed.Clone(); }
        finally { DestroyIcon(handle); }
    }
    [DllImport("user32.dll")] private static extern bool DestroyIcon(IntPtr icon);
}
