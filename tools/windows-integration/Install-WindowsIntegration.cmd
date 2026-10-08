@echo off
powershell.exe -NoProfile -Command "Start-Process powershell.exe -Verb RunAs -ArgumentList @('-NoProfile','-ExecutionPolicy','Bypass','-File','\"%~dp0WindowsIntegration.ps1\"','-Action','Install')"
