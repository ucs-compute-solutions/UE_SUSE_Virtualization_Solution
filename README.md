# SUSE Virtualization (Harvester) on Cisco Intersight

This directory contains the Harvester v1.8.2 ISO customization inputs, per-node installer configuration, and Cisco Intersight automation for preparing the server profiles and virtual media used for installation.

The Intersight workflow configures and deploys server profiles. It does not start a Harvester OS installation. An administrator uses vKVM to boot the custom ISO and selects the matching node entry from its GRUB menu.

## Repository contents

| File or directory | Purpose |
| --- | --- |
| `create_custom_iso.sh` | Downloads a Harvester ISO, replaces its GRUB menu and shared Harvester config, validates the result, and writes a custom ISO. |
| `ISO/grub.cfg.yaml` | GRUB menu sample with generic installer entries and node-specific Harvester entries. The build script sets the visible menu timeout to 15 seconds by default. |
| `ISO/harvester.cfg.yaml` | Shared Harvester config copied to `/boot/grub2/harvester.cfg` in the custom ISO. |
| `ISO/harvester1.cfg.yaml` … `ISO/harvester5.cfg.yaml` | Per-node config samples. The current ISO build script does not copy these files into the ISO. |
| `harvester1.yaml` … `harvester5.yaml` | Per-node installer configuration files referenced by the node-specific GRUB entries. Host these at the URL configured in the menu so the installer can retrieve them. |
| `intersight_deploy_validate.sh` | Creates or updates the Intersight policies and template, creates missing server profiles, deploys and activates profiles, and validates the result. For a Harvester target, it creates or updates the vMedia policy and adds its organization-scoped selector to the template before creating profiles. |
| `intersight_deploy_validate_vars.txt` | Shell-sourced configuration for Intersight organization, profile, network, storage, boot, and vMedia settings. |
| `intersight_policy_reconcile.sh` | Compares configured policy state with Intersight and offers interactive provisioning of differences. It includes the vMedia policy for Harvester targets and can create it when missing after confirmation. |
| `intersight_cleanup_strict.sh` | Removes selected profiles, the profile template, and associated policies and pools within the configured organization. It deletes the named vMedia policy when present. |

## Requirements

- Cisco Intersight access and servers available in the configured resource group.
- `isctl` configured for the Intersight API key and secret key.
- `jq` for the Intersight scripts.
- `curl` and `xorriso` for building the custom ISO. `grub2-script-check` or `grub-script-check` is used when available.
- Bash. The ISO builder and Intersight scripts are written for Bash.

## Build the custom ISO

The builder defaults to the Harvester v1.8.2 source ISO and writes `harvester-v1.8.2-amd64-custom.iso` next to the script. Override those defaults when needed:

```bash
./create_custom_iso.sh \
  --source-url 'https://<iso-host>/<harvester-release>.iso' \
  --output ./harvester-custom.iso \
  --timeout 15
```

The timeout must be 10–30 seconds. The script checks for the visible GRUB menu and the node 1–5 entries, remasters the ISO while preserving its boot metadata, and compares the extracted GRUB and shared Harvester config with the supplied files. Use `--insecure` only when the trusted internal ISO server has a certificate that cannot be verified by the host.

The node entries in `ISO/grub.cfg.yaml` pass the installer configuration URL and automatic-install option for their corresponding node. The matching `harvesterN.yaml` file must be reachable from the server during boot. The ISO builder packages the shared config and GRUB menu; it does not host the per-node YAML files.

## Intersight workflow

1. Review `intersight_deploy_validate_vars.txt`. Confirm the organization, resource group, target platform, server profile names, networking, storage and boot settings, and vMedia ISO location.
2. Confirm `VMEDIA_FILE_LOCATION` points to the custom ISO and the vMedia policy name and mapping values are correct. The scripts detect Harvester case-insensitively from `OS_IMAGE_NAME` or the ISO filename in `VMEDIA_FILE_LOCATION` / `OS_IMAGE_LINK`.
3. Run `intersight_deploy_validate.sh`. The Harvester vMedia policy is ensured and attached to the profile template before missing server profiles are created. The script then deploys and activates the server profiles; this does not install Harvester.
4. Open vKVM for the target server, boot from the virtual media ISO, and choose the matching node entry from the GRUB menu. The node-specific selection starts the configured Harvester installation.
5. Use `intersight_policy_reconcile.sh` to review policy drift and interactively provision approved changes. Use `intersight_cleanup_strict.sh` only when tearing down the selected Intersight objects for the configured organization.

The cleanup script supports `server-profiles`, `unified-edge`, or `both` scopes. Review its scope and target variables before running it; it performs destructive operations.

## Configuration and sensitive data

The vars file is sourced as shell code. Keep assignments in `NAME=value` form, quote values containing spaces, and review derived policy and profile names when changing `PREFIX`.

Per-node Harvester YAML files can contain bootstrap credentials, tokens, or SSH keys. Keep real values out of the README, public repositories, and ISO build artifacts unless that exposure is intended. Restrict file permissions, replace example credentials with protected values, and use an access-controlled host for the installer configuration URLs. Do not commit API secret key files.

The current sample files include environment-specific addressing and device names. Confirm node IPs, VIP, VLAN, bond interfaces, install device, data disk, URL, and Harvester release against the target environment before booting the ISO.

## Operational notes

- The profile template uses an organization-scoped selector for the vMedia policy. Harvester vMedia settings are enabled only when the OS name or ISO filename identifies Harvester.
- The vMedia policy makes the ISO available to the server; the administrator still controls boot and starts installation through vKVM and the GRUB menu.
- `ENABLE_OS_INSTALL` is currently `false` in the vars file. The deploy/validate workflow does not create OS install jobs.
- GRUB's default selection timeout is 15 seconds and can be changed through `--timeout` when building the ISO.
- Intersight API operations and cleanup affect live resources. Verify the organization and cleanup scope before approving changes.
