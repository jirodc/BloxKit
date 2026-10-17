// RobloxManager.exe: opens Roblox Manager as its own app (its own taskbar icon,
// pinnable, "Roblox Manager" in Task Manager) with no console window.
// It runs RobloxManager.ps1 from the same folder inside this process, using the
// PowerShell that comes with Windows, so the script stays readable and editable.
// Build it with tools\build-app.ps1.
using System;
using System.IO;
using System.Reflection;
using System.Threading;
using System.Windows.Forms;
using System.Management.Automation;
using System.Management.Automation.Runspaces;

[assembly: AssemblyTitle("Roblox Manager")]
[assembly: AssemblyProduct("Roblox Manager")]
[assembly: AssemblyDescription("Open several Roblox accounts, watch them, and keep them from going idle.")]
[assembly: AssemblyVersion("1.0.0.0")]
[assembly: AssemblyFileVersion("1.0.0.0")]

static class Program
{
    [STAThread]
    static int Main(string[] args)
    {
        string exe = Application.ExecutablePath;
        string script = Path.Combine(Path.GetDirectoryName(exe), "RobloxManager.ps1");
        if (!File.Exists(script))
        {
            MessageBox.Show("RobloxManager.ps1 wasn't found next to this app:\n" + script +
                "\n\nKeep RobloxManager.exe in the same folder as the other files.", "Roblox Manager",
                MessageBoxButtons.OK, MessageBoxIcon.Error);
            return 1;
        }
        // The script uses this for "Open when Windows starts" and for restarting itself.
        Environment.SetEnvironmentVariable("RML_LAUNCHER", exe);

        InitialSessionState iss = InitialSessionState.CreateDefault();
        iss.ExecutionPolicy = Microsoft.PowerShell.ExecutionPolicy.Bypass;   // for this app only, like the .bat's -ExecutionPolicy Bypass
        iss.ApartmentState = ApartmentState.STA;                              // the window needs it
        iss.ThreadOptions = PSThreadOptions.UseCurrentThread;
        Runspace rs = RunspaceFactory.CreateRunspace(iss);
        try
        {
            rs.Open();
            using (PowerShell ps = PowerShell.Create())
            {
                ps.Runspace = rs;
                ps.AddCommand(script);
                foreach (string a in args)
                {
                    // The script only takes switches: -Minimized (from Windows startup), -NoRoblox.
                    if (a.StartsWith("-") && a.Length > 1) ps.AddParameter(a.Substring(1));
                }
                ps.Invoke();
            }
            return 0;
        }
        catch (Exception e)
        {
            if (!ErrorAlreadyShown(rs))
            {
                Exception inner = e;
                while (inner.InnerException != null) inner = inner.InnerException;
                MessageBox.Show("Sorry, Roblox Manager couldn't start:\n\n" + inner.Message, "Roblox Manager",
                    MessageBoxButtons.OK, MessageBoxIcon.Error);
            }
            return 1;
        }
        finally
        {
            rs.Dispose();
        }
    }

    static bool ErrorAlreadyShown(Runspace rs)
    {
        // The script's own error box (its trap) sets this after telling the user.
        try { return rs.SessionStateProxy.GetVariable("RmlErrorShown") is bool && (bool)rs.SessionStateProxy.GetVariable("RmlErrorShown"); }
        catch { return false; }
    }
}
