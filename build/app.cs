using System;
using System.Collections.Generic;
using System.Diagnostics;
using System.Drawing;
using System.IO;
using System.Net;
using System.Net.Sockets;
using System.Text;
using System.Threading;
using System.Threading.Tasks;
using System.Web.Script.Serialization;
using System.Windows.Forms;

namespace AntigravityLocalApp
{
    internal sealed class InstallState
    {
        public string route { get; set; }
        public string model { get; set; }
        public string model_path { get; set; }
        public string litert_backend { get; set; }
        public string ollama { get; set; }
        public int port { get; set; }
    }

    internal sealed class LocalRuntime : IDisposable
    {
        private readonly string root;
        private readonly string python;
        private readonly string agent;
        private readonly string modelRoot;
        private readonly string ollama;
        private readonly string model;
        private readonly string route;
        private readonly string modelPath;
        private readonly string liteRTBackend;
        private readonly int preferredPort;
        private Process server;
        private int activePort;

        public LocalRuntime(string rootPath)
        {
            root = rootPath;
            python = Path.Combine(root, @"runtime\python\python.exe");
            modelRoot = Path.Combine(root, "models");
            string statePath = Path.Combine(root, "install-state.json");

            if (!File.Exists(statePath)) throw new FileNotFoundException("Install state was not found.", statePath);
            JavaScriptSerializer serializer = new JavaScriptSerializer();
            InstallState state = serializer.Deserialize<InstallState>(File.ReadAllText(statePath));
            if (state == null) throw new InvalidDataException("Install state could not be read.");

            route = String.IsNullOrWhiteSpace(state.route) ? "Ollama" : state.route;
            ollama = state.ollama;
            model = state.model;
            modelPath = state.model_path;
            liteRTBackend = String.IsNullOrWhiteSpace(state.litert_backend) ? "gpu" : state.litert_backend;
            preferredPort = state.port > 0 ? state.port : 11435;
            agent = Path.Combine(root, String.Equals(route, "LiteRT", StringComparison.OrdinalIgnoreCase) ? "litert_agent.py" : "local_agent.py");

            if (!File.Exists(python)) throw new FileNotFoundException("Private Python was not found.", python);
            if (!File.Exists(agent)) throw new FileNotFoundException("Antigravity agent was not found.", agent);
            if (String.Equals(route, "LiteRT", StringComparison.OrdinalIgnoreCase))
            {
                if (String.IsNullOrWhiteSpace(modelPath) || !File.Exists(modelPath)) throw new FileNotFoundException("LiteRT model was not found.", modelPath);
            }
            else
            {
                if (String.IsNullOrWhiteSpace(ollama) || !File.Exists(ollama)) throw new FileNotFoundException("Ollama was not found.", ollama);
                if (String.IsNullOrWhiteSpace(model)) throw new InvalidDataException("Installed model id is missing.");
            }
        }

        public string Run(string prompt, Action<string> status, int timeoutMs)
        {
            if (String.IsNullOrWhiteSpace(prompt)) prompt = "Reply with only: OK";
            status("Starting local model...");
            bool isLiteRT = String.Equals(route, "LiteRT", StringComparison.OrdinalIgnoreCase);
            if (!isLiteRT) EnsureServer(timeoutMs > 60000 ? 60000 : timeoutMs);
            status("Running model...");

            ProcessStartInfo psi = new ProcessStartInfo();
            psi.FileName = python;
            psi.Arguments = Quote(agent);
            psi.WorkingDirectory = root;
            psi.UseShellExecute = false;
            psi.CreateNoWindow = true;
            psi.RedirectStandardOutput = true;
            psi.RedirectStandardError = true;
            psi.EnvironmentVariables["ANTIGRAVITY_LOCAL_PROMPT"] = prompt;
            if (isLiteRT)
            {
                psi.EnvironmentVariables["ANTIGRAVITY_LITERT_MODEL_PATH"] = modelPath;
                psi.EnvironmentVariables["ANTIGRAVITY_LITERT_BACKEND"] = liteRTBackend;
            }
            else
            {
                psi.EnvironmentVariables["ANTIGRAVITY_LOCAL_MODEL"] = model;
                psi.EnvironmentVariables["ANTIGRAVITY_LOCAL_BASE_URL"] = "http://127.0.0.1:" + activePort.ToString() + "/v1";
            }

            StringBuilder stdout = new StringBuilder();
            StringBuilder stderr = new StringBuilder();
            using (Process p = new Process())
            {
                p.StartInfo = psi;
                p.OutputDataReceived += delegate(object sender, DataReceivedEventArgs e) { if (e.Data != null) stdout.AppendLine(e.Data); };
                p.ErrorDataReceived += delegate(object sender, DataReceivedEventArgs e) { if (e.Data != null) stderr.AppendLine(e.Data); };
                if (!p.Start()) throw new InvalidOperationException("The Antigravity process could not be started.");
                p.BeginOutputReadLine();
                p.BeginErrorReadLine();
                if (!p.WaitForExit(timeoutMs))
                {
                    try { p.Kill(); } catch { }
                    throw new TimeoutException("The local model took too long to respond.");
                }
                p.WaitForExit();
                if (p.ExitCode != 0)
                {
                    string err = stderr.ToString().Trim();
                    throw new InvalidOperationException(String.IsNullOrWhiteSpace(err) ? "The local model returned an error." : err);
                }
            }

            string output = stdout.ToString().Trim();
            if (String.IsNullOrWhiteSpace(output)) throw new InvalidOperationException("The local model returned no output.");
            return output;
        }

        private void EnsureServer(int timeoutMs)
        {
            if (server != null && !server.HasExited && ApiReady(activePort)) return;

            activePort = FindFreePort(preferredPort, preferredPort + 30);
            ProcessStartInfo psi = new ProcessStartInfo();
            psi.FileName = ollama;
            psi.Arguments = "serve";
            psi.UseShellExecute = false;
            psi.CreateNoWindow = true;
            psi.EnvironmentVariables["OLLAMA_HOST"] = "127.0.0.1:" + activePort.ToString();
            psi.EnvironmentVariables["OLLAMA_MODELS"] = modelRoot;

            server = new Process();
            server.StartInfo = psi;
            if (!server.Start()) throw new InvalidOperationException("The local model service could not be started.");

            Stopwatch sw = Stopwatch.StartNew();
            while (sw.ElapsedMilliseconds < timeoutMs)
            {
                if (server.HasExited) throw new InvalidOperationException("The local model service stopped during startup.");
                if (ApiReady(activePort)) return;
                Thread.Sleep(400);
            }
            throw new TimeoutException("The local model service did not become ready.");
        }

        private bool ApiReady(int port)
        {
            try
            {
                HttpWebRequest req = (HttpWebRequest)WebRequest.Create("http://127.0.0.1:" + port.ToString() + "/api/version");
                req.Method = "GET";
                req.Timeout = 1500;
                using (HttpWebResponse res = (HttpWebResponse)req.GetResponse())
                {
                    return ((int)res.StatusCode >= 200 && (int)res.StatusCode < 300);
                }
            }
            catch { return false; }
        }

        private static int FindFreePort(int start, int end)
        {
            for (int port = start; port <= end; port++)
            {
                TcpListener listener = null;
                try
                {
                    listener = new TcpListener(IPAddress.Loopback, port);
                    listener.Start();
                    listener.Stop();
                    return port;
                }
                catch
                {
                    try { if (listener != null) listener.Stop(); } catch { }
                }
            }
            throw new InvalidOperationException("No private local port is available.");
        }

        private static string Quote(string value)
        {
            return "\"" + value.Replace("\"", "\\\"") + "\"";
        }

        public void Dispose()
        {
            if (server != null)
            {
                try { if (!server.HasExited) server.Kill(); } catch { }
                try { server.Dispose(); } catch { }
                server = null;
            }
        }
    }

    internal sealed class MainForm : Form
    {
        private readonly Button run;
        private readonly Label statusTitle;
        private readonly Label statusText;
        private readonly Label nextStep;
        private readonly LocalRuntime runtime;

        public MainForm(LocalRuntime localRuntime)
        {
            runtime = localRuntime;
            Text = "Antigravity Installation Test";
            StartPosition = FormStartPosition.CenterScreen;
            Size = new Size(650, 500);
            MinimumSize = new Size(650, 500);
            BackColor = Color.White;
            Font = new Font("Segoe UI", 10);

            Label title = new Label();
            title.Text = "Installation test";
            title.Font = new Font("Segoe UI Semibold", 20);
            title.AutoSize = true;
            title.Location = new Point(34, 28);
            Controls.Add(title);

            Label intro = new Label();
            intro.Text = "This window only checks that your local Antigravity setup was installed correctly.\r\nIt is not the product itself.";
            intro.ForeColor = Color.FromArgb(70, 70, 70);
            intro.Size = new Size(560, 48);
            intro.Location = new Point(38, 76);
            Controls.Add(intro);

            Panel line = new Panel();
            line.BackColor = Color.Black;
            line.Location = new Point(38, 132);
            line.Size = new Size(555, 1);
            Controls.Add(line);

            Label checks = new Label();
            checks.Text = "The test will start the local model, check the Antigravity connection, and confirm that a response comes back.";
            checks.Size = new Size(555, 52);
            checks.Location = new Point(38, 155);
            Controls.Add(checks);

            run = new Button();
            run.Text = "Run installation test";
            run.Location = new Point(40, 218);
            run.Size = new Size(190, 42);
            run.BackColor = Color.Black;
            run.ForeColor = Color.White;
            run.FlatStyle = FlatStyle.Flat;
            run.Click += Run_Click;
            Controls.Add(run);

            statusTitle = new Label();
            statusTitle.Text = "Not tested yet";
            statusTitle.Font = new Font("Segoe UI Semibold", 14);
            statusTitle.AutoSize = true;
            statusTitle.Location = new Point(38, 292);
            Controls.Add(statusTitle);

            statusText = new Label();
            statusText.Text = "Run the test once after installation.";
            statusText.Size = new Size(555, 48);
            statusText.Location = new Point(40, 330);
            Controls.Add(statusText);

            nextStep = new Label();
            nextStep.Text = "After a successful test, you can close this window. Your local setup stays installed on this PC. Keep the desktop shortcut only if you want to test the installation again.";
            nextStep.ForeColor = Color.FromArgb(90, 90, 90);
            nextStep.Size = new Size(555, 62);
            nextStep.Location = new Point(40, 385);
            Controls.Add(nextStep);
        }

        private async void Run_Click(object sender, EventArgs e)
        {
            run.Enabled = false;
            statusTitle.Text = "Testing installation";
            statusText.Text = "Starting the local model...";

            try
            {
                string result = await Task.Run(delegate
                {
                    return runtime.Run("Reply with only: OK", delegate(string status)
                    {
                        try
                        {
                            BeginInvoke((MethodInvoker)delegate { statusText.Text = status; });
                        }
                        catch { }
                    }, 240000);
                });

                statusTitle.Text = "Installation test passed";
                statusText.Text = "Everything is working correctly. Your installation is complete.";
                nextStep.Text = "Next step: Close this window. Your local Antigravity setup is ready on this PC. This test window is only here to verify the installation.";
            }
            catch (Exception ex)
            {
                statusTitle.Text = "Installation test failed";
                statusText.Text = "The setup needs attention. Take a screenshot of this message and send it to support.\r\n\r\n" + ex.Message;
                nextStep.Text = "Do not reinstall manually or run commands. Send this screen to support so the installation can be fixed.";
            }
            finally
            {
                run.Enabled = true;
            }
        }

        protected override void OnFormClosed(FormClosedEventArgs e)
        {
            try { runtime.Dispose(); } catch { }
            base.OnFormClosed(e);
        }
    }

    internal static class Program
    {
        [STAThread]
        private static int Main(string[] args)
        {
            string root = AppDomain.CurrentDomain.BaseDirectory;
            try
            {
                using (LocalRuntime runtime = new LocalRuntime(root))
                {
                    if (args != null && args.Length > 0 && String.Equals(args[0], "--self-test", StringComparison.OrdinalIgnoreCase))
                    {
                        string output = runtime.Run("Reply with only: OK", delegate(string s) { Console.WriteLine(s); }, 240000);
                        Console.WriteLine(output);
                        return String.IsNullOrWhiteSpace(output) ? 2 : 0;
                    }

                    Application.EnableVisualStyles();
                    Application.SetCompatibleTextRenderingDefault(false);
                    Application.Run(new MainForm(runtime));
                    return 0;
                }
            }
            catch (Exception ex)
            {
                if (args != null && args.Length > 0 && String.Equals(args[0], "--self-test", StringComparison.OrdinalIgnoreCase))
                {
                    Console.Error.WriteLine(ex.ToString());
                    return 1;
                }
                MessageBox.Show("The app could not start.\r\n\r\n" + ex.Message, "Antigravity Local", MessageBoxButtons.OK, MessageBoxIcon.Error);
                return 1;
            }
        }
    }
}
