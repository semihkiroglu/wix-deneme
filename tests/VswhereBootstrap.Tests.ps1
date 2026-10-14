<#
.SYNOPSIS
Unit checks for the image-only vswhere launcher (VswhereBootstrap.cs).

.DESCRIPTION
Compiles the real launcher source the image uses and runs it as a real process,
with a stub "real vswhere" in place of the discovery tool. Verifies that the
launcher forwards arguments (quotes, backslashes, empty arguments) unchanged,
only adds '-products *' when the caller passed no products filter, and passes
through stdout, stderr and the exit code of the real process.

Windows compiles with the in-box .NET Framework csc.exe (same compiler the image
uses); other hosts compile with the local .NET SDK. Exit code 0 = all checks
passed, 1 = at least one failure.
#>
[CmdletBinding()]
param(
    [string]$WorkDir = (Join-Path ([IO.Path]::GetTempPath()) ("vswhere-bootstrap-tests-" + [Guid]::NewGuid().ToString('N')))
)

$ErrorActionPreference = 'Stop'
$script:Passed = 0
$script:Failed = 0

function Assert-True([bool]$Condition, [string]$Label) {
    if ($Condition) {
        $script:Passed++
        Write-Host "PASS $Label"
    } else {
        $script:Failed++
        Write-Host "FAIL $Label"
    }
}

function Assert-ArgsEqual([string]$Label, [string[]]$Expected, [string[]]$Actual) {
    $ok = @($Expected).Count -eq @($Actual).Count
    if ($ok) {
        for ($i = 0; $i -lt @($Expected).Count; $i++) {
            if ([string]$Expected[$i] -cne [string]$Actual[$i]) { $ok = $false }
        }
    }
    if (-not $ok) {
        Write-Host ("  expected: " + (@($Expected) | ForEach-Object { "[$_]" }) -join ' ')
        Write-Host ("  actual:   " + (@($Actual) | ForEach-Object { "[$_]" }) -join ' ')
    }
    Assert-True $ok $Label
}

function Get-StubArguments([string]$StdOut) {
    $result = @()
    foreach ($line in ($StdOut -split "\r?\n")) {
        if ($line -match '^STUB-ARG(\d+)=\[(.*)\]$') { $result += $Matches[2] }
    }
    return , $result
}

function Invoke-Child([string]$FilePath, [string]$Arguments, [string]$RealPath, [string]$RealVariable = 'CTECH_VSWHERE_REAL') {
    $startInfo = New-Object System.Diagnostics.ProcessStartInfo
    $startInfo.FileName = $FilePath
    $startInfo.Arguments = $Arguments
    $startInfo.UseShellExecute = $false
    $startInfo.RedirectStandardOutput = $true
    $startInfo.RedirectStandardError = $true
    $startInfo.WorkingDirectory = Split-Path -Parent $FilePath
    if ($RealPath) { $startInfo.EnvironmentVariables[$RealVariable] = $RealPath }
    $process = [System.Diagnostics.Process]::Start($startInfo)
    $stdout = $process.StandardOutput.ReadToEnd()
    $stderr = $process.StandardError.ReadToEnd()
    if (-not $process.WaitForExit(60000)) { $process.Kill(); throw "Child process did not exit: $FilePath" }
    return [pscustomobject]@{ ExitCode = $process.ExitCode; StdOut = $stdout; StdErr = $stderr }
}

# Compiles a C# source into a runnable program; returns its path.
function Build-Program([string]$SourcePath, [string]$OutDir, [string]$AssemblyName, [string]$SourceLabel) {
    New-Item -ItemType Directory -Force -Path $OutDir | Out-Null
    if ([IO.Path]::DirectorySeparatorChar -eq '\') {
        $csc = Join-Path $env:WINDIR 'Microsoft.NET\Framework64\v4.0.30319\csc.exe'
        if (-not (Test-Path -LiteralPath $csc)) { $csc = Join-Path $env:WINDIR 'Microsoft.NET\Framework\v4.0.30319\csc.exe' }
        if (-not (Test-Path -LiteralPath $csc)) { throw 'In-box csc.exe not found' }
        $exe = Join-Path $OutDir "$AssemblyName.exe"
        & $csc /nologo /target:exe "/out:$exe" $SourcePath
        if ($LASTEXITCODE -ne 0 -or -not (Test-Path -LiteralPath $exe)) { throw "csc.exe failed for $SourceLabel" }
        return $exe
    }
    $sdkLine = @(& dotnet --list-sdks | Select-Object -First 1)
    if (-not $sdkLine) { throw 'No .NET SDK available to compile the test launcher' }
    # Apphosts must locate the runtime; the SDK path tells us its root.
    if (-not $env:DOTNET_ROOT -and ([string]$sdkLine) -match '\[(.*)\]') {
        $env:DOTNET_ROOT = Split-Path -Parent $Matches[1]
    }
    $tfm = 'net' + ([string]$sdkLine).Split('.')[0] + '.0'
    $projectDir = Join-Path $WorkDir ("build-" + $AssemblyName)
    New-Item -ItemType Directory -Force -Path $projectDir | Out-Null
    $projectFile = Join-Path $projectDir "$AssemblyName.csproj"
    @"
<Project Sdk="Microsoft.NET.Sdk">
  <PropertyGroup>
    <OutputType>Exe</OutputType>
    <TargetFramework>$tfm</TargetFramework>
    <AssemblyName>$AssemblyName</AssemblyName>
    <EnableDefaultCompileItems>false</EnableDefaultCompileItems>
    <ImplicitUsings>disable</ImplicitUsings>
    <Nullable>disable</Nullable>
  </PropertyGroup>
  <ItemGroup>
    <Compile Include="$SourcePath" />
  </ItemGroup>
</Project>
"@ | Set-Content -LiteralPath $projectFile -Encoding ASCII
    & dotnet build $projectFile -c Release --nologo -v:minimal -o $OutDir | Out-Host
    if ($LASTEXITCODE -ne 0) { throw "dotnet build failed for $SourceLabel" }
    $program = Join-Path $OutDir $AssemblyName
    if (-not (Test-Path -LiteralPath $program)) { throw "Build output missing: $program" }
    return $program
}

# --- fixtures ---------------------------------------------------------------
$repoRoot = Split-Path -Parent $PSScriptRoot
$launcherSource = Join-Path $repoRoot 'VswhereBootstrap.cs'
if (-not (Test-Path -LiteralPath $launcherSource)) { throw "Launcher source not found: $launcherSource" }

$stubSource = Join-Path $WorkDir 'StubVswhere.cs'
New-Item -ItemType Directory -Force -Path $WorkDir | Out-Null
@'
using System;

internal static class StubVswhere
{
    private static int Main(string[] args)
    {
        Console.Out.WriteLine("STUB-ARGC=" + args.Length.ToString());
        for (int i = 0; i < args.Length; i++)
        {
            Console.Out.WriteLine("STUB-ARG" + i.ToString() + "=[" + args[i] + "]");
        }
        Console.Out.WriteLine("STUB-STDOUT=ok");
        Console.Out.Flush();
        Console.Error.WriteLine("STUB-STDERR=ok");
        Console.Error.Flush();
        foreach (string arg in args)
        {
            if (arg == "--stub-ok") { return 0; }
        }
        return 42;
    }
}
'@ | Set-Content -LiteralPath $stubSource -Encoding ASCII

Write-Host "Work directory: $WorkDir"
$shimDir = Join-Path $WorkDir 'shim'
$stubDir = Join-Path $WorkDir 'real tools dir'
$launcher = Build-Program -SourcePath $launcherSource -OutDir $shimDir -AssemblyName 'vswhere' -SourceLabel 'VswhereBootstrap.cs'
$stub = Build-Program -SourcePath $stubSource -OutDir $stubDir -AssemblyName 'vswhere-real' -SourceLabel 'StubVswhere.cs'
Write-Host "Launcher: $launcher"
Write-Host "Stub:     $stub"

# Default discovery: the real tool is expected beside the launcher.
Get-ChildItem -LiteralPath $stubDir -File | Where-Object { $_.Name -like 'vswhere-real*' } | ForEach-Object {
    Copy-Item -LiteralPath $_.FullName -Destination (Join-Path $shimDir $_.Name) -Force
}
$siblingLauncher = Join-Path $shimDir (Split-Path -Leaf $launcher)

try {
    # 1. Sibling discovery, upstream's query, exit code and stream passthrough.
    $run = Invoke-Child $siblingLauncher '-property installationPath -version [17.0,18.0)' $null
    Assert-True ($run.ExitCode -eq 42) 'exit code of the real process is returned (42)'
    Assert-ArgsEqual 'sibling discovery forwards arguments and adds -products *' `
        @('-property', 'installationPath', '-version', '[17.0,18.0)', '-products', '*') (Get-StubArguments $run.StdOut)
    Assert-True ($run.StdOut -match 'STUB-STDOUT=ok') 'stdout of the real process is passed through'
    Assert-True ($run.StdErr -match 'STUB-STDERR=ok') 'stderr of the real process is passed through'
    Assert-True ($run.StdOut -notmatch 'STUB-STDERR') 'stderr is not merged into stdout'

    # 2. Real tool path taken from the environment override (path contains spaces).
    $run = Invoke-Child $launcher '-all -format json' $stub
    Assert-ArgsEqual 'environment override is used and -products * is added' `
        @('-all', '-format', 'json', '-products', '*') (Get-StubArguments $run.StdOut)
    Assert-True ($run.ExitCode -eq 42) 'exit code passthrough via environment override'

    # 3. An explicit products filter must not be duplicated.
    $run = Invoke-Child $launcher '-products Microsoft.VisualStudio.Product.BuildTools -version [17.0,18.0)' $stub
    Assert-ArgsEqual 'explicit -products is forwarded unchanged' `
        @('-products', 'Microsoft.VisualStudio.Product.BuildTools', '-version', '[17.0,18.0)') (Get-StubArguments $run.StdOut)

    # 4. The products switch is case-insensitive.
    $run = Invoke-Child $launcher '-PRODUCTS *' $stub
    Assert-ArgsEqual 'explicit products filter is detected ignoring case' `
        @('-PRODUCTS', '*') (Get-StubArguments $run.StdOut)

    # 5. Quoted argument with spaces survives unchanged.
    $run = Invoke-Child $launcher '-property installationPath -path "C:\Program Files\Microsoft Visual Studio\2022\BuildTools" -utf8' $stub
    Assert-ArgsEqual 'quoted argument with spaces is forwarded unchanged' `
        @('-property', 'installationPath', '-path', 'C:\Program Files\Microsoft Visual Studio\2022\BuildTools', '-utf8', '-products', '*') (Get-StubArguments $run.StdOut)

    # 6. Backslashes, including escaped ones at the end of a quoted argument.
    $run = Invoke-Child $launcher '-path \\server\share\dir\ -requires Microsoft.Component.MSBuild' $stub
    Assert-ArgsEqual 'backslash paths are forwarded unchanged' `
        @('-path', '\\server\share\dir\', '-requires', 'Microsoft.Component.MSBuild', '-products', '*') (Get-StubArguments $run.StdOut)
    $run = Invoke-Child $launcher '-path "C:\BuildTools\Bin\\" -nologo' $stub
    Assert-ArgsEqual 'quoted trailing backslash survives the round trip' `
        @('-path', 'C:\BuildTools\Bin\', '-nologo', '-products', '*') (Get-StubArguments $run.StdOut)

    # 7. Empty argument.
    $run = Invoke-Child $launcher '-property installationPath -utf8 "" -version [17.0,18.0)' $stub
    Assert-ArgsEqual 'empty argument is forwarded unchanged' `
        @('-property', 'installationPath', '-utf8', '', '-version', '[17.0,18.0)', '-products', '*') (Get-StubArguments $run.StdOut)

    # 8. Success exit code.
    $run = Invoke-Child $launcher '--stub-ok -version [17.0,18.0)' $stub
    Assert-True ($run.ExitCode -eq 0) 'exit code 0 of the real process is returned (0)'

    # 9. Missing real tool fails loudly instead of reporting an empty result.
    $emptyDir = Join-Path $WorkDir 'no-real-tool'
    New-Item -ItemType Directory -Force -Path $emptyDir | Out-Null
    Copy-Item -LiteralPath $launcher -Destination $emptyDir -Force
    Get-ChildItem -LiteralPath $shimDir -File | Where-Object { $_.Name -like 'vswhere.*' } | ForEach-Object {
        Copy-Item -LiteralPath $_.FullName -Destination $emptyDir -Force
    }
    $run = Invoke-Child (Join-Path $emptyDir (Split-Path -Leaf $launcher)) '-property installationPath' $null
    Assert-True ($run.ExitCode -eq 127) 'missing real tool exits with 127'
    Assert-True ($run.StdErr -match 'vswhere-real') 'missing real tool is reported on stderr'

    # Win32 vs x86 native output paths in upstream collide; pipeline runs the
    # genuine compiler with the upstream -m default and accepts the prior race
    # risk for the small set of vcxproj platforms that share a recipe file.
    $installScript = Join-Path $repoRoot 'Install-BuildEnv.ps1'
    $wixPs1 = Join-Path $repoRoot 'Build-Wix.ps1'
    if (-not (Test-Path $installScript)) { throw 'Install-BuildEnv.ps1 missing' }
    if (-not (Test-Path $wixPs1)) { throw 'Build-Wix.ps1 missing' }
    $bootstrapShimAbsent = $true
    foreach ($file in @($installScript, $wixPs1, (Join-Path $repoRoot 'MsbuildBootstrap.cs'))) {
        if ((Test-Path -LiteralPath $file) -and ((Get-Content -LiteralPath $file -Raw) -match 'MsbuildBootstrap|msbuild\.cmd|CTECH_MSBUILD.*-m:1')) {
            $bootstrapShimAbsent = $false
            break
        }
    }
    Assert-True $bootstrapShimAbsent 'no MSBuild shim wraps the genuine compiler (single, real toolchain)'
} finally {
    if (Test-Path -LiteralPath $WorkDir) { Remove-Item -LiteralPath $WorkDir -Recurse -Force }
    Write-Host ("Checks: " + $script:Passed + " passed, " + $script:Failed + " failed")
}
if ($script:Failed -gt 0) { throw "$($script:Failed) vswhere launcher check(s) failed" }
