# escape=`
# CTech WiX builder image, Windows Server Core.
#
# Base image: the official .NET Framework 4.8.1 runtime image. The prebuilt
# mcr.microsoft.com/dotnet/framework/sdk image is deliberately NOT used: the
# Visual Studio it carries is not the pinned historical 17.14.29 toolchain the
# WiX 7 build was validated with, so it would silently select a different
# MSBuild/SDK combination. Jenkins passes the base image of the host build
# (2019/2022/2025) through BASE_IMAGE.
ARG BASE_IMAGE=mcr.microsoft.com/dotnet/framework/runtime:4.8.1-windowsservercore-ltsc2022
FROM ${BASE_IMAGE}

SHELL ["powershell", "-NoProfile", "-ExecutionPolicy", "Bypass", "-Command", "$ErrorActionPreference='Stop'; $ProgressPreference='SilentlyContinue';"]

# Only the environment installer, the vswhere launcher source and the build
# script enter the image; no repository source is copied.
COPY Install-BuildEnv.ps1 VswhereBootstrap.cs C:\pipeline\
RUN & C:\pipeline\Install-BuildEnv.ps1

ENV DOTNET_ROOT=C:\tools\dotnet `
    DOTNET_ROOT_X86=C:\tools\dotnet-x86 `
    CTECH_VSROOT=C:\BuildTools `
    CTECH_MSBUILD=C:\BuildTools\MSBuild\Current\Bin\amd64\MSBuild.exe `
    CTECH_VSDEVCMD=C:\BuildTools\Common7\Tools\VsDevCmd.bat `
    PATH=C:\tools\dotnet;C:\tools\dotnet-x86;C:\tools\pwsh;C:\tools\git\cmd;C:\tools\nuget;C:\Windows\system32;C:\Windows;C:\Windows\System32\Wbem;C:\Windows\System32\WindowsPowerShell\v1.0;C:\Windows\System32\OpenSSH

RUN New-Item -ItemType Directory -Force C:\output | Out-Null
WORKDIR C:\work

COPY Build-Wix.ps1 C:\pipeline\
ENTRYPOINT ["C:\\tools\\pwsh\\pwsh.exe", "-NoProfile", "-File", "C:\\pipeline\\Build-Wix.ps1"]
