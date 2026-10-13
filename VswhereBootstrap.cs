// vswhere.exe launcher for the CTech build image.
//
// Upstream (WixInternal.MSTestSupport) runs vswhere with
// "-property installationPath -version [17.0,18.0)", which never matches a
// Build Tools installation because the real vswhere default product list only
// contains Enterprise/Professional/Community. This shim adds '-products *' only
// when the caller supplied no products filter of its own, then forwards every
// argument verbatim to the real tool kept next to it as vswhere-real.exe.
using System;
using System.Diagnostics;
using System.IO;
using System.Reflection;

internal static class VswhereBootstrap
{
    // Distinguishable failure when the real discovery tool is missing.
    internal const int RealExeNotFoundExitCode = 127;

    private static int Main(string[] args)
    {
        string realPath = Environment.GetEnvironmentVariable("CTECH_VSWHERE_REAL");
        if (string.IsNullOrEmpty(realPath))
        {
            string directory = Path.GetDirectoryName(Assembly.GetExecutingAssembly().Location);
            string fileName = Path.DirectorySeparatorChar == '\\' ? "vswhere-real.exe" : "vswhere-real";
            realPath = Path.Combine(directory, fileName);
        }

        if (!File.Exists(realPath))
        {
            Console.Error.WriteLine("vswhere-real not found: " + realPath);
            return RealExeNotFoundExitCode;
        }

        string arguments = RawArguments(Environment.CommandLine);
        if (!HasProductsArgument(args))
        {
            arguments += " -products *";
        }

        ProcessStartInfo startInfo = new ProcessStartInfo(realPath, arguments);
        startInfo.UseShellExecute = false;
        using (Process process = Process.Start(startInfo))
        {
            process.WaitForExit();
            return process.ExitCode;
        }
    }

    // True when the caller already passed a products filter: adding a second one
    // would silently widen the query, because vswhere treats '*' anywhere in the
    // product list as "all products".
    private static bool HasProductsArgument(string[] args)
    {
        if (args == null)
        {
            return false;
        }
        foreach (string arg in args)
        {
            if (arg == null)
            {
                continue;
            }
            string value = arg.Trim();
            if (value.Equals("-products", StringComparison.OrdinalIgnoreCase) ||
                value.Equals("--products", StringComparison.OrdinalIgnoreCase))
            {
                return true;
            }
        }
        return false;
    }

    // Everything after the program name, exactly as the caller typed it. Raw
    // forwarding keeps quoting, backslashes and empty arguments byte-identical.
    private static string RawArguments(string commandLine)
    {
        int index;
        if (commandLine.Length > 0 && commandLine[0] == '"')
        {
            index = commandLine.IndexOf('"', 1);
            index = index < 0 ? commandLine.Length : index + 1;
        }
        else
        {
            index = commandLine.IndexOf(' ');
            index = index < 0 ? commandLine.Length : index;
        }
        while (index < commandLine.Length && commandLine[index] == ' ')
        {
            index++;
        }
        return commandLine.Substring(index);
    }
}
