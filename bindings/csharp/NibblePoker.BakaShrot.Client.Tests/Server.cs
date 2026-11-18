using System;
using System.Diagnostics;
using System.IO;
using System.Net;
using System.Net.Sockets;
using System.Threading;
using NUnit.Framework;

namespace NibblePoker.BakaShrot.Tests
{
    /// <summary>A server for the tests, on a free port, in its own folder
    /// under target/csharp-tests/ with its certificates: made with the
    /// programs cargo built (target/debug, or BAKASHROT_BIN).</summary>
    [SetUpFixture]
    public class Server
    {
        public static string Folder = "";
        public static int Port;
        private static Process? process;

        private static readonly bool Windows = Path.DirectorySeparatorChar == '\\';

        [OneTimeSetUp]
        public void Start()
        {
            string root = FindRepository();
            string bin = Environment.GetEnvironmentVariable("BAKASHROT_BIN") ?? Path.Combine(root, "target", "debug");
            string exe = Windows ? ".exe" : "";
            string library = Windows ? "bakashrot.dll" : "libbakashrot.so";
            if (!File.Exists(Path.Combine(bin, library)))
                Assert.Fail($"No {library} in {bin}: cargo build first (or set BAKASHROT_BIN)");
            // Before any call into it: DllImport finds it next to the tests.
            File.Copy(Path.Combine(bin, library), Path.Combine(TestContext.CurrentContext.TestDirectory, library), true);

            Folder = Path.Combine(root, "target", "csharp-tests", Process.GetCurrentProcess().Id.ToString());
            if (Directory.Exists(Folder))
                Directory.Delete(Folder, true);
            Directory.CreateDirectory(Folder);

            string tool = Path.Combine(bin, "bakashrot" + exe);
            Run(tool, "cert ca --name test-ca");
            Run(tool, "cert issue --server --name server-1");
            Run(tool, "cert issue --name kitchen --role home");
            Run(tool, "cert issue --name lounge --role lounge");
            Run(tool, "cert issue --name guest --role guest");

            TcpListener listener = new TcpListener(IPAddress.Loopback, 0);
            listener.Start();
            Port = ((IPEndPoint)listener.LocalEndpoint).Port;
            listener.Stop();
            File.WriteAllText(Path.Combine(Folder, "server.toml"), $@"[server]
listen = ""127.0.0.1:{Port}""
ca = ""ca.crt""
certificate = ""server-1.crt""
key = ""server-1.key""
database = ""bakashrot.sqlite""

[roles.home]
push_topics = [""*""]
read_topics = [""*""]
query = true

[roles.lounge]
read_topics = [""logs""]
");

            process = Process.Start(new ProcessStartInfo(Path.Combine(bin, "bakashrot-server" + exe), "server.toml")
            {
                WorkingDirectory = Folder,
                UseShellExecute = false,
                CreateNoWindow = true,
            });
            DateTime until = DateTime.UtcNow.AddSeconds(15);
            while (true)
            {
                if (process!.HasExited)
                    Assert.Fail($"bakashrot-server exited ({process.ExitCode})");
                try
                {
                    using (TcpClient client = new TcpClient())
                    {
                        client.Connect(IPAddress.Loopback, Port);
                        return;
                    }
                }
                catch (SocketException)
                {
                    if (DateTime.UtcNow > until)
                        Assert.Fail("bakashrot-server isn't listening after 15 s");
                    Thread.Sleep(100);
                }
            }
        }

        [OneTimeTearDown]
        public void Stop()
        {
            if (process != null && !process.HasExited)
            {
                process.Kill();
                process.WaitForExit(10000);
            }
            try
            {
                Directory.Delete(Folder, true);
            }
            catch (IOException)
            {
            }
        }

        public static string In(string name) => Path.Combine(Folder, name);

        public static Client Connect(string name) =>
            new Client("127.0.0.1", Port, In("ca.crt"), In(name + ".crt"), In(name + ".key"), null).Connect();

        private static void Run(string exe, string arguments)
        {
            using Process run = Process.Start(new ProcessStartInfo(exe, arguments)
            {
                WorkingDirectory = Folder,
                UseShellExecute = false,
                CreateNoWindow = true,
                RedirectStandardOutput = true,
                RedirectStandardError = true,
            })!;
            string output = run.StandardOutput.ReadToEnd() + run.StandardError.ReadToEnd();
            run.WaitForExit();
            if (run.ExitCode != 0)
                Assert.Fail($"{Path.GetFileName(exe)} {arguments}: {output}");
        }

        // The folder with Cargo.toml, above the tests' build folder.
        private static string FindRepository()
        {
            DirectoryInfo? folder = new DirectoryInfo(TestContext.CurrentContext.TestDirectory);
            while (folder != null && !File.Exists(Path.Combine(folder.FullName, "Cargo.toml")))
                folder = folder.Parent;
            if (folder == null)
                Assert.Fail("No Cargo.toml above " + TestContext.CurrentContext.TestDirectory);
            return folder!.FullName;
        }
    }
}
