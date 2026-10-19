using System;
using System.Diagnostics;
using System.IO;
using System.Reflection;
using System.Windows.Forms;

namespace AntigravityLocalSetup
{
    internal static class Program
    {
        private static readonly string[] ResourceNames = new[]
        {
            "Payload.Installer",
            "Payload.Worker",
            "Payload.Agent",
            "Payload.Pack"
        };

        [STAThread]
        private static int Main(string[] args)
        {
            string tempRoot = Path.Combine(Path.GetTempPath(), "AntigravityLocalSetup_" + Guid.NewGuid().ToString("N"));
            try
            {
                string internalDir = Path.Combine(tempRoot, "_internal");
                Directory.CreateDirectory(internalDir);
                string installer = Path.Combine(internalDir, "installer.ps1");
                Extract("Payload.Installer", installer);
                Extract("Payload.Worker", Path.Combine(internalDir, "worker.ps1"));
                Extract("Payload.Agent", Path.Combine(internalDir, "local_agent.py"));
                Extract("Payload.Pack", Path.Combine(internalDir, "pack.json"));

                if (args != null && args.Length > 0 && string.Equals(args[0], "--self-test", StringComparison.OrdinalIgnoreCase))
                {
                    foreach (string resource in ResourceNames)
                    {
                        if (Assembly.GetExecutingAssembly().GetManifestResourceStream(resource) == null) return 20;
                    }
                    string[] files = Directory.GetFiles(internalDir);
                    if (files.Length != 4) return 21;
                    foreach (string file in files)
                    {
                        FileInfo fi = new FileInfo(file);
                        if (!fi.Exists || fi.Length == 0) return 22;
                    }
                    return 0;
                }

                string powershell = Path.Combine(Environment.GetFolderPath(Environment.SpecialFolder.System), @"WindowsPowerShell\v1.0\powershell.exe");
                if (!File.Exists(powershell)) powershell = "powershell.exe";

                ProcessStartInfo psi = new ProcessStartInfo();
                psi.FileName = powershell;
                psi.Arguments = "-NoProfile -ExecutionPolicy Bypass -WindowStyle Hidden -File \"" + installer + "\"";
                psi.UseShellExecute = false;
                psi.CreateNoWindow = true;
                psi.WorkingDirectory = tempRoot;

                using (Process process = Process.Start(psi))
                {
                    if (process == null) throw new InvalidOperationException("The installer process could not be started.");
                    process.WaitForExit();
                    return process.ExitCode;
                }
            }
            catch (Exception ex)
            {
                try
                {
                    MessageBox.Show("The installer could not start.\r\n\r\n" + ex.Message, "Antigravity Local Installer", MessageBoxButtons.OK, MessageBoxIcon.Error);
                }
                catch { }
                return 1;
            }
            finally
            {
                try { if (Directory.Exists(tempRoot)) Directory.Delete(tempRoot, true); } catch { }
            }
        }

        private static void Extract(string resourceName, string destination)
        {
            Assembly assembly = Assembly.GetExecutingAssembly();
            using (Stream source = assembly.GetManifestResourceStream(resourceName))
            {
                if (source == null) throw new InvalidOperationException("Installer resource is missing: " + resourceName);
                using (FileStream target = new FileStream(destination, FileMode.Create, FileAccess.Write, FileShare.None))
                {
                    source.CopyTo(target);
                }
            }
        }
    }
}
