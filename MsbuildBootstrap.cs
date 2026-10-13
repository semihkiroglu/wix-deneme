// Container-only launcher: Win32 and x86 project instances share native output
// paths. Run the genuine MSBuild with one scheduler node; never alter WiX files.
using System;
using System.Diagnostics;
using System.IO;

internal static class MsbuildBootstrap
{
    private static int Main(string[] args)
    {
        string real = Environment.GetEnvironmentVariable("CTECH_MSBUILD");
        if (string.IsNullOrEmpty(real) || !File.Exists(real))
        {
            Console.Error.WriteLine("Genuine MSBuild not found: " + real);
            return 127;
        }
        string commandLine = Environment.CommandLine;
        int end = commandLine[0] == '"' ? commandLine.IndexOf('"', 1) + 1 : commandLine.IndexOf(' ');
        string arguments = end < 0 ? "" : commandLine.Substring(end).TrimStart();
        // MSBuild uses the last -m value, overriding upstream's unqualified -m.
        var start = new ProcessStartInfo(real, arguments + " -m:1");
        start.UseShellExecute = false;
        using (Process process = Process.Start(start))
        {
            process.WaitForExit();
            return process.ExitCode;
        }
    }
}
