using System;
using System.Collections.Generic;
using System.Diagnostics;
using System.Drawing;
using System.IO;
using System.Management;
using System.Net.NetworkInformation;
using System.Reflection;
using System.Text;
using System.Windows.Forms;

namespace TongjiVpn
{
    static class Program
    {
        [STAThread]
        static void Main()
        {
            Application.EnableVisualStyles();
            Application.SetCompatibleTextRenderingDefault(false);
            Application.Run(new MainForm());
        }
    }

    public class MainForm : Form
    {
        const string AppName = "tongji-motionpro-vpn";
        const string VpnDesc = "Array Networks";

        readonly string dataDir;
        readonly string engineDir;
        readonly string logFile;
        string configPath;

        Label lblVpn, lblSplit, lblTargets, lblBusy;
        TextBox txtLog;
        Button btnRefresh, btnOneClick, btnConnect, btnSplit, btnGlobal, btnDisconnect;
        Button btnTest, btnConfig, btnOpenLog, btnHelp;
        Timer clock;

        Process running;
        DateTime startAt;
        string runningName = "";
        Action afterExit;

        public MainForm()
        {
            dataDir = Path.Combine(Environment.GetFolderPath(Environment.SpecialFolder.LocalApplicationData), AppName);
            Directory.CreateDirectory(dataDir);
            logFile = Path.Combine(dataDir, "launcher.log");
            engineDir = Path.Combine(dataDir, "engine");
            Directory.CreateDirectory(engineDir);
            ExtractEngine();
            configPath = FindConfig();
            BuildUi();
            Log("控制台已启动（日志: " + logFile + "）");
            Log("引擎目录: " + engineDir);
            Log("配置文件: " + (configPath == null ? "未找到 motionpro.env" : configPath));
            if (configPath == null) Log("警告：请把 motionpro.env 放在本程序旁边，或 %LOCALAPPDATA%\\" + AppName + "\\ 下");
            RefreshStatus();
            clock = new Timer();
            clock.Interval = 1000;
            clock.Tick += (s, e) => OnTick();
            clock.Start();
        }

        // ---------- 资源与配置 ----------
        void ExtractEngine()
        {
            var asm = Assembly.GetExecutingAssembly();
            foreach (var name in new[] { "common.ps1", "vpn.ps1", "split-vpn.ps1" })
            {
                using (var s = asm.GetManifestResourceStream(name))
                {
                    if (s == null) continue;
                    var buf = new byte[s.Length];
                    int read = 0;
                    while (read < buf.Length)
                    {
                        int n = s.Read(buf, read, buf.Length - read);
                        if (n <= 0) break;
                        read += n;
                    }
                    File.WriteAllBytes(Path.Combine(engineDir, name), buf);
                }
            }
        }

        string FindConfig()
        {
            var cands = new List<string>();
            var baseDir = AppDomain.CurrentDomain.BaseDirectory;
            cands.Add(Path.Combine(baseDir, "motionpro.env"));
            var parent = Directory.GetParent(baseDir.TrimEnd('\\'));
            if (parent != null) cands.Add(Path.Combine(parent.FullName, "motionpro.env"));
            var gp = parent != null ? parent.Parent : null;
            if (gp != null) cands.Add(Path.Combine(gp.FullName, "motionpro.env"));
            cands.Add(Path.Combine(dataDir, "motionpro.env"));
            cands.Add(Path.Combine(Environment.GetFolderPath(Environment.SpecialFolder.UserProfile),
                                   ".tongji-motionpro-vpn", "motionpro.env"));
            foreach (var c in cands) if (File.Exists(c)) return c;
            return null;
        }

        List<string> Targets()
        {
            var list = new List<string>();
            if (configPath == null) return list;
            foreach (var line in File.ReadAllLines(configPath, Encoding.UTF8))
            {
                var t = line.Trim();
                if (!t.StartsWith("MOTIONPRO_TARGETS", StringComparison.OrdinalIgnoreCase)) continue;
                int eq = t.IndexOf('=');
                if (eq < 0) continue;
                foreach (var p in t.Substring(eq + 1).Split(new[] { ',', ';', ' ' }, StringSplitOptions.RemoveEmptyEntries))
                    list.Add(p.Trim());
            }
            return list;
        }

        // ---------- 界面 ----------
        void BuildUi()
        {
            Text = "同济 VPN 控制台";
            ClientSize = new Size(780, 640);
            StartPosition = FormStartPosition.CenterScreen;
            FormBorderStyle = FormBorderStyle.FixedSingle;
            MaximizeBox = false;
            Font = new Font("Microsoft YaHei UI", 9f);

            var header = new Label();
            header.Text = "同济 MotionPro VPN — 一键连接 / 分流";
            header.Font = new Font("Microsoft YaHei UI", 13f, FontStyle.Bold);
            header.Location = new Point(16, 10);
            header.AutoSize = true;
            Controls.Add(header);

            var sub = new Label();
            sub.Text = "配置: " + (configPath ?? "未找到 motionpro.env");
            sub.ForeColor = Color.DimGray;
            sub.Location = new Point(18, 42);
            sub.Size = new Size(740, 18);
            Controls.Add(sub);

            var gb = new GroupBox();
            gb.Text = "当前状态";
            gb.Location = new Point(16, 66);
            gb.Size = new Size(748, 110);
            Controls.Add(gb);

            lblVpn = new Label(); lblVpn.Location = new Point(12, 24); lblVpn.Size = new Size(430, 22); lblVpn.Text = "VPN: -"; gb.Controls.Add(lblVpn);
            lblSplit = new Label(); lblSplit.Location = new Point(12, 50); lblSplit.Size = new Size(560, 22); lblSplit.Text = "分流: -"; gb.Controls.Add(lblSplit);
            lblTargets = new Label(); lblTargets.Location = new Point(12, 76); lblTargets.Size = new Size(720, 22); lblTargets.Text = "目标: -"; gb.Controls.Add(lblTargets);
            lblBusy = new Label(); lblBusy.Location = new Point(460, 24); lblBusy.Size = new Size(170, 22); lblBusy.Text = ""; lblBusy.ForeColor = Color.DarkOrange; gb.Controls.Add(lblBusy);

            btnRefresh = MakeButton("刷新状态", 636, 22, 100);
            btnRefresh.Click += (s, e) => { Log("状态已刷新"); RefreshStatus(); };
            gb.Controls.Add(btnRefresh);

            var actions = new GroupBox();
            actions.Text = "操作";
            actions.Location = new Point(16, 184);
            actions.Size = new Size(748, 100);
            Controls.Add(actions);

            btnOneClick = MakeButton("一键：连接并分流", 12, 22, 160);
            btnOneClick.Font = new Font("Microsoft YaHei UI", 9f, FontStyle.Bold);
            btnOneClick.Click += OneClick;
            btnConnect = MakeButton("连接 VPN", 182, 22, 110); btnConnect.Click += (s, e) => DoConnect();
            btnSplit = MakeButton("分流（仅校内）", 302, 22, 130); btnSplit.Click += (s, e) => DoSplit();
            btnGlobal = MakeButton("恢复全局", 442, 22, 100); btnGlobal.Click += (s, e) => DoGlobal();
            btnDisconnect = MakeButton("断开 VPN", 552, 22, 100); btnDisconnect.Click += (s, e) => DoDisconnect();
            btnTest = MakeButton("测试访问", 12, 60, 160); btnTest.Click += (s, e) => DoTest();
            btnConfig = MakeButton("打开配置", 182, 60, 110); btnConfig.Click += (s, e) => OpenConfig();
            btnOpenLog = MakeButton("打开日志", 302, 60, 110); btnOpenLog.Click += (s, e) => OpenLog();
            btnHelp = MakeButton("使用说明", 422, 60, 110); btnHelp.Click += (s, e) => OpenHelp();
            actions.Controls.AddRange(new Control[] { btnOneClick, btnConnect, btnSplit, btnGlobal, btnDisconnect, btnTest, btnConfig, btnOpenLog, btnHelp });

            txtLog = new TextBox();
            txtLog.Location = new Point(16, 292);
            txtLog.Size = new Size(748, 332);
            txtLog.Multiline = true;
            txtLog.ReadOnly = true;
            txtLog.ScrollBars = ScrollBars.Vertical;
            txtLog.BackColor = Color.White;
            txtLog.Font = new Font("Consolas", 9f);
            Controls.Add(txtLog);

            FormClosing += OnFormClosing;
        }

        Button MakeButton(string text, int x, int y, int w)
        {
            var b = new Button();
            b.Text = text; b.Location = new Point(x, y); b.Size = new Size(w, 30);
            return b;
        }

        // ---------- 日志 ----------
        void Log(string text)
        {
            if (txtLog == null) return;
            var line = "[" + DateTime.Now.ToString("HH:mm:ss") + "] " + text;
            txtLog.AppendText(line + Environment.NewLine);
            try { File.AppendAllText(logFile, DateTime.Now.ToString("yyyy-MM-dd HH:mm:ss") + " " + text + Environment.NewLine, Encoding.UTF8); }
            catch { }
        }

        void LogAsync(string text)
        {
            if (IsDisposed) return;
            try { BeginInvoke(new Action(() => Log(text.TrimEnd()))); }
            catch { }
        }

        // ---------- 状态 ----------
        static NetworkInterface VpnInterface()
        {
            foreach (var ni in NetworkInterface.GetAllNetworkInterfaces())
            {
                if (ni.OperationalStatus != OperationalStatus.Up) continue;
                if (ni.Name.IndexOf(VpnDesc, StringComparison.OrdinalIgnoreCase) < 0 &&
                    ni.Description.IndexOf(VpnDesc, StringComparison.OrdinalIgnoreCase) < 0) continue;
                return ni;
            }
            return null;
        }

        static string VpnIp(NetworkInterface ni)
        {
            if (ni == null) return null;
            foreach (var ua in ni.GetIPProperties().UnicastAddresses)
            {
                if (ua.Address.AddressFamily != System.Net.Sockets.AddressFamily.InterNetwork) continue;
                var s = ua.Address.ToString();
                if (s.StartsWith("169.254.")) continue;
                return s;
            }
            return null;
        }

        static int VpnIndex(NetworkInterface ni)
        {
            try { return ni.GetIPProperties().GetIPv4Properties().Index; }
            catch { return -1; }
        }

        static List<ManagementObject> Routes(string prefix)
        {
            var list = new List<ManagementObject>();
            try
            {
                var scope = new ManagementScope(@"\\.\ROOT\StandardCimv2");
                scope.Connect();
                var q = new ObjectQuery("SELECT * FROM MSFT_NetRoute WHERE DestinationPrefix='" + prefix + "'");
                using (var s = new ManagementObjectSearcher(scope, q))
                    foreach (ManagementObject o in s.Get()) list.Add(o);
            }
            catch { }
            return list;
        }

        static bool HasRouteOnIf(string prefix, int ifIndex)
        {
            foreach (var o in Routes(prefix))
            {
                try
                {
                    object idx = o["InterfaceIndex"];
                    if (idx != null && Convert.ToInt32(idx) == ifIndex) return true;
                }
                catch { }
            }
            return false;
        }

        void RefreshStatus()
        {
            var ni = VpnInterface();
            string ip = VpnIp(ni);
            if (ip == null)
            {
                lblVpn.Text = "VPN: 未连接";
                lblVpn.ForeColor = Color.Firebrick;
                lblSplit.Text = "分流: -";
                lblSplit.ForeColor = Color.DimGray;
            }
            else
            {
                lblVpn.Text = "VPN: 已连接    IP " + ip;
                lblVpn.ForeColor = Color.SeaGreen;
                int idx = VpnIndex(ni);
                bool vpnDefault = HasRouteOnIf("0.0.0.0/0", idx);
                bool hasTarget = HasRouteOnIf("10.0.0.0/8", idx);
                bool physDefault = false;
                foreach (var o in Routes("0.0.0.0/0"))
                {
                    try
                    {
                        object i2 = o["InterfaceIndex"];
                        if (i2 != null && Convert.ToInt32(i2) != idx) physDefault = true;
                    }
                    catch { }
                }
                bool split = !vpnDefault && hasTarget && physDefault;
                if (split)
                {
                    lblSplit.Text = "分流: 生效（只有校内目标走 VPN）";
                    lblSplit.ForeColor = Color.SeaGreen;
                }
                else
                {
                    lblSplit.Text = "分流: 未生效（全局模式，所有流量走 VPN）";
                    lblSplit.ForeColor = Color.DarkOrange;
                }
            }
            var t = Targets();
            lblTargets.Text = "目标: " + (t.Count > 0 ? string.Join(", ", t.ToArray()) : "（未配置）");
        }

        // ---------- 进程 ----------
        void RunEngine(string script, string args, bool elevated, string label, Action onDone)
        {
            if (running != null) { Log("有任务在运行，请稍候…"); return; }
            string path = Path.Combine(engineDir, script);
            if (!File.Exists(path)) { Log("找不到脚本: " + path); return; }
            string cfg = configPath != null ? " -Config \"" + configPath + "\"" : "";
            string psArgs = "-NoProfile -ExecutionPolicy Bypass -File \"" + path + "\" " + args + cfg;

            var psi = new ProcessStartInfo("powershell.exe", psArgs);
            psi.CreateNoWindow = true;
            psi.WindowStyle = ProcessWindowStyle.Hidden;
            psi.UseShellExecute = elevated;
            if (elevated) psi.Verb = "runas";
            else
            {
                psi.RedirectStandardOutput = true;
                psi.RedirectStandardError = true;
                psi.StandardOutputEncoding = Encoding.UTF8;
                psi.StandardErrorEncoding = Encoding.UTF8;
            }

            Log("—— " + label + " ——");
            if (elevated) Log("（即将弹出 UAC，请点『是』）");
            try
            {
                var p = Process.Start(psi);
                running = p; startAt = DateTime.Now; runningName = label; afterExit = onDone;
                SetButtons(false);
                if (!elevated)
                {
                    p.OutputDataReceived += (s, e) => { if (e.Data != null) LogAsync(e.Data); };
                    p.ErrorDataReceived += (s, e) => { if (e.Data != null) LogAsync(e.Data); };
                    p.BeginOutputReadLine();
                    p.BeginErrorReadLine();
                }
                p.EnableRaisingEvents = true;
                p.Exited += (s, e) => { try { BeginInvoke(new Action(() => OnExit(p))); } catch { } };
            }
            catch (Exception ex)
            {
                Log("启动失败: " + ex.Message);
                SetButtons(true);
                running = null;
            }
        }

        void OnExit(Process p)
        {
            int code = -1;
            try { code = p.ExitCode; } catch { }
            Log("—— " + runningName + " 结束（exit=" + code + "）——");
            running = null;
            SetButtons(true);
            var cb = afterExit; afterExit = null;
            RefreshStatus();
            if (cb != null) cb();
        }

        void SetButtons(bool enabled)
        {
            foreach (var b in new[] { btnOneClick, btnConnect, btnSplit, btnGlobal, btnDisconnect, btnTest })
                b.Enabled = enabled;
        }

        void OnTick()
        {
            if (running == null) { lblBusy.Text = ""; return; }
            int sec = (int)(DateTime.Now - startAt).TotalSeconds;
            lblBusy.Text = runningName + " " + sec + "s";
            if (sec > 300) { lblBusy.Text = "超时，可关闭窗口"; }
        }

        void PollSplit(int tries, Action<bool> done)
        {
            var t = new Timer();
            t.Interval = 3000;
            int left = tries;
            t.Tick += (s, e) =>
            {
                left--;
                var ni = VpnInterface();
                int idx = VpnIndex(ni);
                bool ok = VpnIp(ni) != null && !HasRouteOnIf("0.0.0.0/0", idx) && HasRouteOnIf("10.0.0.0/8", idx);
                if (ok) { t.Stop(); t.Dispose(); done(true); return; }
                if (left <= 0) { t.Stop(); t.Dispose(); done(false); }
            };
            t.Start();
        }

        // ---------- 动作 ----------
        void OneClick(object s, EventArgs e)
        {
            if (running != null) return;
            if (VpnIp(VpnInterface()) != null)
            {
                Log("VPN 已连接，直接分流");
                DoSplitInternal();
                return;
            }
            Log("第 1 步：连接 VPN（约 60~90 秒，请勿关闭窗口）");
            RunEngine("vpn.ps1", "up", false, "连接 VPN", () =>
            {
                if (VpnIp(VpnInterface()) == null)
                {
                    Log("!! 连接失败：没拿到 VPN 地址。请点『连接 VPN』重试，或查看日志。");
                    return;
                }
                Log("连接成功，继续分流");
                DoSplitInternal();
            });
        }

        void DoConnect() { RunEngine("vpn.ps1", "up", false, "连接 VPN", null); }
        void DoDisconnect()
        {
            if (MessageBox.Show("确定断开 VPN 吗？", "确认", MessageBoxButtons.YesNo, MessageBoxIcon.Question) != DialogResult.Yes) return;
            RunEngine("vpn.ps1", "down", false, "断开 VPN", null);
        }

        void DoSplit() { DoSplitInternal(); }

        void DoSplitInternal()
        {
            RunEngine("split-vpn.ps1", "on -PreferIPv4", true, "分流", () =>
            {
                Log("等待分流生效（最多 45 秒）…");
                PollSplit(15, ok =>
                {
                    if (ok) { Log("分流已生效 ✔"); RefreshStatus(); }
                    else Log("!! 分流未生效：多半是 UAC 没点『是』。请点『分流（仅校内）』重试。");
                });
            });
        }

        void DoGlobal()
        {
            RunEngine("split-vpn.ps1", "off", true, "恢复全局模式", () => { RefreshStatus(); });
        }

        void DoTest()
        {
            var hosts = new List<string>();
            foreach (var t in Targets()) if (t.IndexOf('/') < 0) hosts.Add(t);
            if (hosts.Count == 0) { hosts.Add("www.tongji.edu.cn"); hosts.Add("agi.tongji.edu.cn"); }
            Log("—— 测试访问 ——");
            foreach (var h in hosts.GetRange(0, Math.Min(4, hosts.Count)))
            {
                var psi = new ProcessStartInfo("curl.exe", "-4 -sk -o NUL -w \"%{http_code} %{remote_ip}\" --max-time 8 https://" + h + "/");
                psi.CreateNoWindow = true; psi.UseShellExecute = false;
                psi.RedirectStandardOutput = true; psi.RedirectStandardError = true;
                try
                {
                    var p = Process.Start(psi);
                    string o = p.StandardOutput.ReadToEnd();
                    p.WaitForExit(12000);
                    Log(h + " -> " + o.Trim());
                }
                catch (Exception ex) { Log(h + " -> 失败: " + ex.Message); }
            }
        }

        void OpenConfig()
        {
            if (configPath == null) { Log("找不到 motionpro.env"); return; }
            Process.Start("notepad.exe", "\"" + configPath + "\"");
        }

        void OpenLog()
        {
            string splitLog = Path.Combine(dataDir, "split.log");
            if (File.Exists(splitLog)) Process.Start("notepad.exe", "\"" + splitLog + "\"");
            else if (File.Exists(logFile)) Process.Start("notepad.exe", "\"" + logFile + "\"");
            else Log("还没有日志");
        }

        void OpenHelp()
        {
            var cands = new[] {
                Path.Combine(AppDomain.CurrentDomain.BaseDirectory, "README.md"),
                Path.Combine(dataDir, "README.md")
            };
            foreach (var c in cands) if (File.Exists(c)) { Process.Start("notepad.exe", "\"" + c + "\""); return; }
            Log("找不到 README.md（可到 GitHub 仓库查看）");
        }

        void OnFormClosing(object s, FormClosingEventArgs e)
        {
            if (running != null)
            {
                var r = MessageBox.Show("任务仍在运行（" + runningName + "）。\n关闭窗口会中断它，确定关闭吗？",
                                        "任务未完成", MessageBoxButtons.YesNo, MessageBoxIcon.Warning);
                if (r != DialogResult.Yes) { e.Cancel = true; return; }
                try { running.Kill(); } catch { }
            }
        }
    }
}
