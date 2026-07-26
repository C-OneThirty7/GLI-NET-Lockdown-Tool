# GL.iNet Lockdown Tool

Download the release asset for your router, install it in LuCI, and run the lockdown tool.

## Download

Open the latest GitHub release and download one of these assets:

- `glinet-lockdown-be3600_1.5.5_all.ipk` for Slate 7 / GL-BE3600
- `glinet-lockdown-axt1800_1.5.5_all.ipk` for GL-AXT1800
- `glinet-lockdown-mudi7_1.6.5_all.ipk` for Mudi 7 / GL-E5800
- `glinet-lockdown-all-ipks-1.5.5-1.6.5.zip` if you want all current router packages

## Install

1. Log in to the GL.iNet web UI.
2. Open `System -> Advanced Settings -> LuCI`.
3. In LuCI, open `System -> Software`.
4. Upload the `.ipk` for your router model.
5. Open `System -> GL.iNet Lockdown`.
6. Choose a profile and click `Apply Profile`.
7. Click `Verify Lockdown`.
8. Reboot once and confirm the startup guard reports `PASS`.

If LuCI reports `Unable to execute opkg install command: Error: XHR request aborted by browser`, refresh LuCI, log in again, and retry the upload.

## What It Does

- Removes or disables GL.iNet cloud, DDNS, MQTT, rtty, and related remote-management components.
- Blocks known GL.iNet cloud/update hostnames.
- Blocks known GL.iNet/GoodCloud IP denylist entries by default.
- Adds WAN firewall drops for common admin and VPN server ports.
- Hardens Dropbear and disables SSH by default.
- Keeps VPN client and VPN server capability unless the user explicitly removes optional VPN server components.
- Provides optional removals, DNS enforcement, fan control, backups, temporary SSH access, WAN scan, and update checks in LuCI.

## Build From Source

```sh
MODEL_TARGET=be3600 ./build-glinet-lockdown-ipk.sh
MODEL_TARGET=axt1800 ./build-glinet-lockdown-ipk.sh
MODEL_TARGET=mudi7 ./build-glinet-lockdown-ipk.sh
```

Generated packages are written to `dist/`.
