## sing-box 核心更新至 1.15.0-alpha.14

## :memo: Release Notes

* Drop support for go1.25 **1**
* Fix Linux desktop client package conflicting with the CLI package **2**
* Update quic-go to v0.66.0
* Update tailscale to v1.106.1
* Fixes and improvements

**1**:

Due to maintenance difficulties, sing-box 1.15.0 requires at least Go 1.26.11 to compile.

**2**:

The Linux [desktop client](https://sing-box.sagernet.org/clients/desktop/) (`SFL`) package has been renamed from `sing-box` to `sfl` and no longer installs `/usr/bin/sing-box`. Existing SFL users must remove the old `sing-box` package once before installing the new package (daemon data in `/var/lib/sing-box-daemon` is preserved).

> 发布页: https://github.com/SagerNet/sing-box/releases/tag/v1.15.0-alpha.14
