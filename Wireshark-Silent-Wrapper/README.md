# Wireshark Wrapper

This folder contains a batch wrapper that downloads a PowerShell deployment script from GitHub Gist and executes it.

## Silent arguments and switches used

### In `install_wrapper.bat`

- `-NoProfile`
  - Starts PowerShell without loading user profile scripts so behavior is consistent across machines.
- `-ExecutionPolicy Bypass`
  - Allows the deployment command to run even when local execution policy is restrictive.
- `-Command "..."`
  - Runs inline PowerShell that downloads the remote script and executes it in memory.
- `%*`
  - Forwards all wrapper arguments to the PowerShell script unchanged.

### In `wireshark_deployment.ps1` (remote script)

- `msiexec /i "<installer>.msi" /qn /norestart`
  - `/qn`: fully silent MSI install (no UI).
  - `/norestart`: prevents forced reboot during deployment.
- `Wireshark-*.exe /S`
  - `/S`: silent EXE install (no UI).
- Uninstall flow for older installed versions may use:
  - `msiexec ... /X ... /qn /norestart` for silent MSI uninstall.
  - `UninstallString /S` for silent EXE uninstall.

## How to execute the wrapper

Open an elevated terminal in this folder and run:

```bat
install_wrapper.bat
```

Common examples:

```bat
install_wrapper.bat -ForceDownload
install_wrapper.bat -InstallerPath "C:\Temp\Wireshark-latest-x64.exe"
install_wrapper.bat -DownloadFolder "C:\Temp\WiresharkDeploy"
install_wrapper.bat -LogFilePath "C:\Temp\wireshark_deploy.log"
```

Notes:
- The wrapper prefers `pwsh` if available, otherwise it uses `powershell.exe`.
- Run as Administrator, otherwise installation will fail.
- The wrapper exits with the same non-zero code as the deployment script on failure.
