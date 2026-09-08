using System.Security.Principal;
using System.Windows;
namespace XDVPN.App;

public partial class App : Application
{
    private Mutex? instance;
    private EventWaitHandle? activate;
    private RegisteredWaitHandle? wait;
    protected override void OnStartup(StartupEventArgs e)
    {
        base.OnStartup(e);
        var sid = WindowsIdentity.GetCurrent().User!.Value;
        instance = new Mutex(true, @"Local\XDVPN.App." + sid, out var first);
        activate = new EventWaitHandle(false, EventResetMode.AutoReset, @"Local\XDVPN.Show." + sid);
        if (!first) { activate.Set(); Shutdown(); return; }
        var window = new MainWindow(); MainWindow = window;
        wait = ThreadPool.RegisterWaitForSingleObject(activate, (_, _) => Dispatcher.BeginInvoke(window.ShowMain), null, Timeout.Infinite, false);
        if (!e.Args.Contains("--background")) window.Show();
    }
    protected override void OnSessionEnding(SessionEndingCancelEventArgs e) { (MainWindow as MainWindow)?.EndSession(); base.OnSessionEnding(e); }
    protected override void OnExit(ExitEventArgs e) { wait?.Unregister(null); activate?.Dispose(); instance?.Dispose(); base.OnExit(e); }
}
