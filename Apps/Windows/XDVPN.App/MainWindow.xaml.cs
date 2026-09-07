using System.ComponentModel;
using System.Diagnostics;
using System.Drawing;
using System.Runtime.InteropServices;
using System.Windows;
using System.Windows.Controls;
using System.Windows.Input;
using System.Windows.Threading;
using XDVPN.Core;
using XDVPN.Platform;
using Forms = System.Windows.Forms;
namespace XDVPN.App;

public partial class MainWindow : Window
{
    private readonly VpnModel model = new();
    private readonly DispatcherTimer timer = new() { Interval = TimeSpan.FromSeconds(2) };
    private readonly Forms.NotifyIcon tray;
    private readonly Forms.ToolStripMenuItem action;
    private bool quitting;
    public MainWindow()
    {
        InitializeComponent(); DataContext=model; LoadProfile();
        tray=new Forms.NotifyIcon{ Text="XD VPN", Icon=CreateIcon(), Visible=true, ContextMenuStrip=new Forms.ContextMenuStrip() };
        tray.DoubleClick+=(_,_)=>ShowMain();tray.ContextMenuStrip.Items.Add("打开 XD VPN",null,(_,_)=>ShowMain());
        action=new Forms.ToolStripMenuItem("连接工作网络",null,async(_,_)=>await model.Act());tray.ContextMenuStrip.Items.Add(action);
        tray.ContextMenuStrip.Items.Add(new Forms.ToolStripSeparator());tray.ContextMenuStrip.Items.Add("退出并断开",null,(_,_)=>Quit());
        model.PropertyChanged+=(_,_)=>{action.Text=model.ActionTitle;action.Enabled=model.CanAct;tray.Text="XD VPN · "+model.Title;};
        timer.Tick+=async(_,_)=>await model.Poll();timer.Start();_ = model.Poll();
        PreviewKeyDown+=async(_,e)=>{if(Keyboard.Modifiers==ModifierKeys.Control&&e.Key==Key.K){e.Handled=true;await model.Act();}else if(Keyboard.Modifiers==ModifierKeys.Control&&e.Key==Key.Q){e.Handled=true;Quit();}};
    }
    public void ShowMain(){Show();WindowState=WindowState.Normal;Activate();}
    private void WindowClosing(object? sender,CancelEventArgs e){if(!quitting){e.Cancel=true;Hide();Password.Clear();}}
    public void EndSession(){quitting=true;timer.Stop();model.Dispose();tray.Visible=false;tray.Icon?.Dispose();tray.Dispose();}
    private void Quit(){EndSession();System.Windows.Application.Current.Shutdown();}
    private void Navigate(object sender,RoutedEventArgs e)
    {
        if(ConnectionPage is null)return;
        var page=(sender as RadioButton)?.Tag as string;
        ConnectionPage.Visibility=page=="Connection"?Visibility.Visible:Visibility.Collapsed;
        ProfilePage.Visibility=page=="Profile"?Visibility.Visible:Visibility.Collapsed;
        QualityPage.Visibility=page=="Quality"?Visibility.Visible:Visibility.Collapsed;
        ActivityPage.Visibility=page=="Activity"?Visibility.Visible:Visibility.Collapsed;
        PageTitle.Text=page switch{"Profile"=>"VPN 配置","Quality"=>"连接质量","Activity"=>"连接日志",_=>"工作网络，一键就绪。"};
        Eyebrow.Text=page switch{"Profile"=>"MAKE IT YOURS","Quality"=>"CONNECTION QUALITY","Activity"=>"CONNECTION JOURNAL",_=>"A LITTLE CLOSER TO WORK"};
        Password.Clear();if(page=="Profile")LoadProfile();
    }
    private void LoadProfile(){ProfileName.Text=model.Profile.Name;Server.Text=model.Profile.Server;Username.Text=model.Profile.Username;AuthGroup.Text=model.Profile.AuthGroup;}
    private async void ConnectionAction(object sender,RoutedEventArgs e)=>await model.Act();
    private async void RefreshService(object sender,RoutedEventArgs e)=>await model.Poll();
    private void SaveProfile(object sender,RoutedEventArgs e)
    {
        try{model.SaveProfile(new(ProfileName.Text,Server.Text,Username.Text,AuthGroup.Text),Password.Password);Password.Clear();ConnectionNav.IsChecked=true;}
        catch(Exception ex)when(ex is ArgumentException or IOException or System.ComponentModel.Win32Exception or UnauthorizedAccessException){model.Report(ex.Message);}
    }
    private void ForgetPassword(object sender,RoutedEventArgs e)
    {
        if(System.Windows.MessageBox.Show(this,"删除此配置保存在 Windows 中的 VPN 密码？","忘记密码",MessageBoxButton.OKCancel,MessageBoxImage.Question)!=MessageBoxResult.OK)return;
        try{model.ForgetPassword();Password.Clear();}catch(System.ComponentModel.Win32Exception ex){model.Report(ex.Message);}
    }
    private async void AutoChanged(object sender,RoutedEventArgs e){try{await model.SetAuto(AutoToggle.IsChecked==true);}catch(Exception ex)when(ex is IOException or OperationCanceledException or UnauthorizedAccessException){model.Report("保存偏好失败："+ex.Message);}}
    private void StartupChanged(object sender,RoutedEventArgs e){try{model.SetStartup(StartupToggle.IsChecked==true);}catch(Exception ex)when(ex is IOException or UnauthorizedAccessException){model.Report("保存登录启动设置失败："+ex.Message);}}
    private void CopyLogs(object sender,RoutedEventArgs e){try{Clipboard.SetText(string.Join(Environment.NewLine,model.Events));}catch(ExternalException){model.Report("剪贴板暂时不可用，请重试。");}}
    private void ClearLogs(object sender,RoutedEventArgs e)=>model.ClearEvents();
    private void OpenLogs(object sender,RoutedEventArgs e){var dir=Path.Combine(Paths.UserData,"logs");Directory.CreateDirectory(dir);Process.Start(new ProcessStartInfo(dir){UseShellExecute=true});}
    private static Icon CreateIcon()
    {
        using var bitmap=new Bitmap(32,32);using var graphics=Graphics.FromImage(bitmap);graphics.SmoothingMode=System.Drawing.Drawing2D.SmoothingMode.AntiAlias;
        using var brush=new SolidBrush(Color.FromArgb(34,120,88));graphics.FillPolygon(brush,new[]{new PointF(16,2),new PointF(29,7),new PointF(27,22),new PointF(16,30),new PointF(5,22),new PointF(3,7)});
        using var pen=new Pen(Color.White,3);graphics.DrawLines(pen,new[]{new PointF(9,16),new PointF(14,21),new PointF(23,11)});
        var handle=bitmap.GetHicon();try{using var borrowed=System.Drawing.Icon.FromHandle(handle);return (System.Drawing.Icon)borrowed.Clone();}finally{DestroyIcon(handle);}
    }
    [DllImport("user32.dll")]private static extern bool DestroyIcon(IntPtr icon);
}
