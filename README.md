# Luna Backup Automation Manager

## Overview
Production-grade Bash automation for scheduled backup of Thales Luna Network HSM partitions to Luna Backup USB HSM 7, with audit logging, prechecks, reporting, and secure operational controls.

## Supported architecture options
1. **Client-connected Backup HSM (default)**: USB Backup HSM attached to Linux host running Luna Client/LunaCM.
2. **Appliance-connected Backup HSM**: USB Backup HSM attached to Luna Network HSM appliance; this project provides guided handling and explicit mode separation.

## Recommended banking deployment architecture
- Dedicated hardened Linux backup host
- Luna Client installed with backup capability
- Backup HSM connected only during approved backup window (if policy requires)
- Restricted sudo and dedicated service account
- Centralized log forwarding (SIEM)
- Dual control for PED and domain material

## Prerequisites
- Linux OS with Bash >= 4
- Luna HSM Client installed and LunaCM executable
- Client registered to source Network HSM
- Source partition/HA visible
- Backup HSM connected and visible
- Backup HSM removed from STM
- Backup HSM SO initialized
- Compatible domain material available
- PED connected/functional when PED-authenticated
- Client minimum version configurable (default 10.3.0)
- Firmware compatibility verified (warn if Network 7.7.0+ with Backup < 7.7.1)

## Installation
```bash
sudo ./install.sh
sudo -u luna-backup /usr/local/sbin/luna_backup_manager.sh setup
```

## Setup wizard
Run:
```bash
sudo -u luna-backup /usr/local/sbin/luna_backup_manager.sh setup
```

## Manual backup
```bash
/usr/local/sbin/luna_backup_manager.sh precheck
/usr/local/sbin/luna_backup_manager.sh backup --dry-run
/usr/local/sbin/luna_backup_manager.sh backup
```

## Scheduling with cron
Use `schedule` command after config.

## Scheduling with systemd timer
Install provided unit/timer and enable timer:
```bash
sudo systemctl daemon-reload
sudo systemctl enable --now luna-backup.timer
```

## Monitoring and logs
- Main log: `/var/log/luna-backup/luna-backup.log`
- Reports: `/var/lib/luna-backup/reports/`
- Status command: `luna_backup_manager.sh status`

## Troubleshooting table
| Symptom | Cause | Action |
|---|---|---|
| Backup HSM not visible | USB/path issue | Re-seat HSM, run `list` |
| LunaCM available HSM shows 0 | Client/appliance connectivity | Validate client registration/network |
| Backup HSM in Secure Transport Mode | Device in STM | Run `stm-guide`, perform manual `stm recover` |
| SO not initialized | Uninitialized backup token | Run approved init ceremony (`init-guide`) |
| PED not detected | PED cable/power | Reconnect PED, retry |
| PED timeout | No operator action | Increase timeout, enforce operator attendance |
| Wrong slot selected | Config error | Correct `BACKUP_HSM_SLOT` |
| Source partition not visible | Access/registration issue | Verify partition rights |
| HA group not visible | HA not configured | Validate HA label/client config |
| Domain mismatch suspected | Clone domain mismatch | Validate domain material under dual control |
| CKR errors | PKCS#11 command failure | Review LunaCM output and vendor KB |
| CKR_CMD_NOT_ALLOWED_HSM_IN_TRANSPORT | STM | Recover STM first |
| Permission denied on log/config | Linux ACL issue | Set config 600 and writable log/state dirs |
| Cron running but backup not happening | Wrong user/path | Use full path and review scheduler.log |
| Script hangs due to PED prompt | Operator absent | Use non-interactive + timeout safeguards |
| LunaCM version unsupported | Old client | Upgrade client to minimum |
| Firmware compatibility warning | Version mismatch | Align Network/Backup HSM firmware |
| Policy 55 restricted restore warning | Restrictive policy | Record and follow restore governance |

## Restore drill guidance
Use `restore-guide` command and `restore_drill.md`; no automated restore is performed.

## Security considerations
- No PIN/password/domain secrets in config/logs/CLI args
- Config permission enforced to 600
- Lock file prevents concurrent runs
- Timeouts prevent indefinite PED blocking
- Structured audit entries and summary reports

## Limitations
- Exact LunaCM backup syntax can vary by client release and may require local adjustment in `perform_partition_archive_backup()`.
- Domain compatibility cannot be fully proven unless exposed by your LunaCM build.
- Unattended PED workflows depend on policy and hardware setup.
