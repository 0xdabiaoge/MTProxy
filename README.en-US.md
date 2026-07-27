# MTProxy One-Click Management Script (Go / Rust Dual-Kernel Edition)

Supports both **Debian/Ubuntu** and **Alpine Linux**. **Compatible with full KVM, LXC, and the more streamlined Docker virtualization LXC**. It consists of two different versions: **Go** and **Rust**. This script uses pre-compiled binaries for installation. The GO version is compiled from optimized source code of [mtg](https://github.com/9seconds/mtg). The telemt (Rust) version is compiled from optimized source code of [telemt](https://github.com/telemt/telemt).

## ✨ Core Features

*   **🚀 Kernel Architecture**:
    *   **Go Version (mtg)**: Source-optimized version. Extremely low memory footprint, powerful performance, anti-replay attack, and strong FakeTLS camouflage mechanism. Ideal for individuals or small groups. High concurrency, low latency, and high speed.
    *   **telemt (Rust) Version**: Adds multi-user management on top of the original version, allowing you to determine traffic quotas, expiration dates, and bandwidth limits for user proxy links. It integrates the advantages of the GO version.
*   **🎯 Listening Modes**: 
    *   **IPV4 Mode**: Supports only IPV4 address inbound/outbound connections and uses an IPV4 address as the MTPROTO link.
    *   **IPV6 Mode**: Supports only IPV6 address inbound/outbound connections and uses an IPV6 address as the MTPROTO link.
    *   **Dual-Stack Mode**: Outputs both IPV4 and IPV6 links simultaneously with separate ports to accommodate different network environments.
---

## 📥 Installation and Usage

**Quick Command: mtp**

```
(curl -LfsS https://raw.githubusercontent.com/0xdabiaoge/MTProxy/main/mtp.sh -o /usr/local/bin/mtp || wget -q https://raw.githubusercontent.com/0xdabiaoge/MTProxy/main/mtp.sh -O /usr/local/bin/mtp) && chmod +x /usr/local/bin/mtp && mtp
```

## 💧 Traffic Quota Reset Testing

```mtp force_reset```
Test traffic reset immediately.

```mtp```
Open the management panel.

```mtp check_reset```
Cron silent check (automatically called by Cron daily).


## Conclusion
**Due to the nature of MTPROTO proxies, it is recommended for personal use only! For testing purposes only.**

## Changelog
## 2026.03.01
- **GO Version Refactor & Optimization**: The GO version underwent a new round of refactoring and optimization. It fixed the issue of legacy zombie connections and resolved memory overflow issues occurring during multi-user connections.

## 2026.03.03
- **Added telemt (Rust Version)**: Based on the source code provided by the [telemt](https://github.com/telemt/telemt) project. Several fixes were implemented; the original version did not support a single-user single-port mode, which has now been added. This provides convenience for temporary sharing with friends without affecting other users—simply delete the corresponding username to deactivate it.

## 2026.03.10
- **telemt Version Deep Optimization**: Added control for user traffic quotas and expiration dates on top of multi-user management. The connection for the corresponding username will be automatically blocked once either limit is reached.
- **Traffic Reset**: Added a username traffic quota reset date for the telemt version. When enabled, the default reset time is midnight on the 1st of every month. This can be set during the initial creation of a username, or for subsequent users via option 4 in the multi-user management submenu.

## 2026.03.19
- **telemt Version Bandwidth Limiting**: Added bandwidth limits for specified usernames to prevent uneven bandwidth distribution when multiple usernames exist. This prevents a single username from saturating the bandwidth and affecting other users.

## 2026.04.07
- **telemt Version ARM Architecture Binary**: Finally obtained a powerful ARM architecture machine to compile ARM binaries.
