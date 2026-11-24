using System;
using System.IO;
using System.Text;
using System.Windows.Forms;
using System.Management.Automation;
using System.Management.Automation.Runspaces;
using Microsoft.PowerShell;

[assembly: System.Reflection.AssemblyTitle("ChatGPT 定时发送助手")]
[assembly: System.Reflection.AssemblyDescription("ChatGPT 桌面端定时自动发送助手（非商业开源）")]
[assembly: System.Reflection.AssemblyCompany("Yu010912")]
[assembly: System.Reflection.AssemblyProduct("ChatGPT 定时发送助手")]
[assembly: System.Reflection.AssemblyCopyright("Copyright (c) 2026 Yu010912. Non-commercial use only.")]
[assembly: System.Reflection.AssemblyVersion("1.0.1.0")]
[assembly: System.Reflection.AssemblyFileVersion("1.0.1.0")]

static class Program
{
    [STAThread]
    static void Main()
    {
        string baseDir = AppDomain.CurrentDomain.BaseDirectory.TrimEnd('\\');
        Environment.SetEnvironmentVariable("CHATGPT_SENDER_HOME", baseDir);
        try { Environment.CurrentDirectory = baseDir; } catch { }

        Application.SetUnhandledExceptionMode(UnhandledExceptionMode.CatchException);
        Application.ThreadException += delegate(object sender, System.Threading.ThreadExceptionEventArgs e)
        {
            MessageBox.Show("界面异常：\n" + e.Exception.Message, "错误", MessageBoxButtons.OK, MessageBoxIcon.Error);
        };

        string scriptPath = Path.Combine(Path.Combine(baseDir, "app"), "MainWindow.ps1");
        if (!File.Exists(scriptPath))
        {
            MessageBox.Show("未找到界面文件：\n" + scriptPath, "ChatGPT 定时发送助手", MessageBoxButtons.OK, MessageBoxIcon.Error);
            return;
        }

        try
        {
            InitialSessionState iss = InitialSessionState.CreateDefault();
            iss.ExecutionPolicy = ExecutionPolicy.Bypass;
            using (Runspace rs = RunspaceFactory.CreateRunspace(iss))
            {
                rs.Open();
                using (PowerShell ps = PowerShell.Create())
                {
                    ps.Runspace = rs;
                    ps.AddScript(File.ReadAllText(scriptPath, Encoding.UTF8));
                    ps.Invoke();
                    if (ps.HadErrors)
                    {
                        StringBuilder sb = new StringBuilder();
                        foreach (ErrorRecord er in ps.Streams.Error) { sb.AppendLine(er.ToString()); }
                        MessageBox.Show("运行中出现错误：\n" + sb.ToString(), "错误", MessageBoxButtons.OK, MessageBoxIcon.Error);
                    }
                }
            }
        }
        catch (Exception ex)
        {
            MessageBox.Show("启动失败：\n" + ex.Message, "错误", MessageBoxButtons.OK, MessageBoxIcon.Error);
        }
    }
}
