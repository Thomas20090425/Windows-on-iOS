@echo off
rem SPDX-License-Identifier: GPL-2.0-or-later
rem Run from the Windows desktop; no administrator rights are needed.
"%SystemRoot%\System32\WindowsPowerShell\v1.0\powershell.exe" -NoProfile -NonInteractive -ExecutionPolicy Bypass -File "%~dp0UseVirtioDisplay.ps1" %*
exit /b %errorlevel%
