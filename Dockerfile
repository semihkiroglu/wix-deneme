# escape=`
# Install the pinned toolchain at container startup, avoiding heavy VS layer export failures.
ARG BASE_IMAGE=mcr.microsoft.com/windows/server:ltsc2022
FROM ${BASE_IMAGE}

# MSI database creation over MAX_PATH needs OS-wide long paths (upstream LongPathFixture relies on this); the base image does not enable them.
RUN reg add "HKLM\SYSTEM\CurrentControlSet\Control\FileSystem" /v LongPathsEnabled /t REG_DWORD /d 1 /f

COPY Install-BuildEnv.ps1 VswhereBootstrap.cs Build-Wix.ps1 C:\pipeline\

ENV DOTNET_ROOT=C:\tools\dotnet `
    DOTNET_ROOT_X86=C:\tools\dotnet-x86 `
    CTECH_VSROOT=C:\BuildTools `
    CTECH_MSBUILD=C:\BuildTools\MSBuild\Current\Bin\amd64\MSBuild.exe `
    CTECH_VSDEVCMD=C:\BuildTools\Common7\Tools\VsDevCmd.bat `
    PATH=C:\tools\dotnet;C:\tools\dotnet-x86;C:\tools\pwsh;C:\tools\git\cmd;C:\tools\nuget;C:\Windows\system32;C:\Windows;C:\Windows\System32\Wbem;C:\Windows\System32\WindowsPowerShell\v1.0;C:\Windows\System32\OpenSSH

WORKDIR C:\work

ENTRYPOINT ["powershell", "-NoProfile", "-ExecutionPolicy", "Bypass", "-File", "C:\\pipeline\\Build-Wix.ps1"]
