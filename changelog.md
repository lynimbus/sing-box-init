## sing-box 核心更新至 1.14.0-beta.15

## :memo: Release Notes

* Add `api` command **1**
* Add Taildrop support **2**
* Add `listen_port` option to Tailscale endpoint
* Fixes and improvements

**1**:

The new `sing-box api` command is a CLI client for the [API service](https://sing-box.sagernet.org/configuration/service/api/), providing the same operations available in graphical clients and the Dashboard.

**2**:

[Tailscale](https://sing-box.sagernet.org/configuration/endpoint/tailscale/) endpoints now support [Taildrop](https://tailscale.com/kb/1106/taildrop), the Tailscale file sharing feature. Received files are stored in the directory configured by the new [`taildrop_directory`](https://sing-box.sagernet.org/configuration/endpoint/tailscale/#taildrop_directory) option (`Taildrop` by default). Files can be sent and managed through the graphical clients, the Dashboard, or the new `sing-box api` command.

> 发布页: https://github.com/SagerNet/sing-box/releases/tag/v1.14.0-beta.15
