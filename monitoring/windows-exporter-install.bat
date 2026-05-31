@echo off
setlocal
REM Download windows_exporter MSI and install silently
powershell -NoProfile -ExecutionPolicy Bypass -Command "iwr -UseBasicParsing https://github.com/prometheus-community/windows_exporter/releases/latest/download/windows_exporter-*.msi -OutFile C:\Windows\Temp\windows_exporter.msi"
msiexec /i C:\Windows\Temp\windows_exporter.msi /qn ENABLED_COLLECTORS="cpu,cs,logical_disk,net,os,service,system,textfile,thermalzone,memory"
sc start windows_exporter
endlocal
