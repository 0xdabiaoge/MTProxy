# MTProxy 一键管理脚本 (Go / Python 双内核版)

**全能、极速、完美的 MTPROTO 搭建脚本。**

支持 **Debian/Ubuntu** 和 **Alpine Linux** 双系统。共分为 **Go** 和 **Python** 两个不同的版本。本脚本采用预编译文件安装，皆由：: [mtg](https://github.com/9seconds/mtg) | [mtprotoproxy](https://github.com/alexbers/mtprotoproxy) 源码优化编译所得。

## ✨ 核心特性

*   **🐧 双系统支持**: 
    *   **Debian / Ubuntu / CentOS**: 完美支持 Systemd 管理。
    *   **Alpine Linux**: 完美支持 OpenRC 管理 (极其省内存，推荐小内存机器使用)。
*   **🚀 双内核架构**:
    *   **Go 版 (mtg)**: 源码优化版。内存占用极低，性能强悍，抗重放攻击。
    *   **Python 版**: 源码优化版。支持 **AD TAG** (推广频道) 功能，适合有营销需求的用户。
*   **🎯 自选监听模式**: 
    *   **IPV4模式**: 仅支持IPV4地址的出入站连接，并以IPV4地址作为MTPROTO的链接。
    *   **IPV6模式**: 仅支持IPV6地址的出入站连接，并以IPV4地址作为MTPROTO的链接。
    *   **双栈模式**: 同时输出IPV4、IPV6两种链接，分别设置端口，应对不同的网络环境。
*   **🔧 灵活管理**:
    *   **修改配置**: 可随时修改端口和伪装域名，自动重载服务。
    *   **定点删除**: 支持单独删除 Go 或 Python 版服务，不影响另一个的运行。
    *   **彻底卸载**: 支持一键全自动卸载，并自我销毁脚本，不留任何痕迹。
*   **⚠ 问题整理**:
    *   **1、**: Python版目前有一个已知的现象（不算BUG）：若长时间无连接或者切换了其他连接方式，Py版的链接会出现不可用的现象，这个现象属于正常，多刷新几次或者直接点击连接使用，即可秒连接。
    *   **2、**: 综上问题选择MTG(GO版)是比较稳定长久的选择。
---

## 📥 安装与使用

**快捷命令：mtp**

```
(curl -LfsS https://raw.githubusercontent.com/0xdabiaoge/MTProxy/main/mtp.sh -o /usr/local/bin/mtp || wget -q https://raw.githubusercontent.com/0xdabiaoge/MTProxy/main/mtp.sh -O /usr/local/bin/mtp) && chmod +x /usr/local/bin/mtp && mtp
```

