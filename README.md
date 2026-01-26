# MTProxy 一键管理脚本 (Go / Rust 双内核版)

**全能、极速、完美的 MTPROTO 搭建脚本。**

支持 **Debian/Ubuntu** 和 **Alpine Linux** 双系统。共分为 **Go**、**Rust** 两个不同的版本。本脚本采用预编译文件安装，GO版由：  [mtg](https://github.com/9seconds/mtg)   源码进行重构优化编译所得。Rust版属于全新尝试的版本，目前也处于稳定使用状态。

## ✨ 核心特性

*   **🐧 双系统支持**: 
    *   **Debian / Ubuntu / CentOS**: 完美支持 Systemd 管理。
    *   **Alpine Linux**: 完美支持 OpenRC 管理 (极其省内存，推荐小内存机器使用)。
*   **🚀 三内核架构**:
    *   **Go 版 (mtg)**: 源码优化版。内存占用极低，性能强悍，抗重放攻击。
    *   **Rust 版**: 拥有Go版的性能以及各项安全性，在多用户连接的情况下表现比Go版要良好，针对多用户使用
*   **🎯 自选监听模式**: 
    *   **IPV4模式**: 仅支持IPV4地址的出入站连接，并以IPV4地址作为MTPROTO的链接。
    *   **IPV6模式**: 仅支持IPV6地址的出入站连接，并以IPV6地址作为MTPROTO的链接。
    *   **双栈模式**: 同时输出IPV4、IPV6两种链接，分别设置端口，应对不同的网络环境。
*   **🔧 灵活管理**:
    *   **修改配置**: 可随时修改端口和伪装域名，自动重载服务。
    *   **定点删除**: 支持单独删除 Go 或 Rust 版服务，不影响另一个的运行。
    *   **彻底卸载**: 支持一键全自动卸载，并自我销毁脚本，不留任何痕迹。
*   **⚠ 问题整理**:
    *   **1、**: Rust版有小概率会出现不可用的现象，一般会出现在切换节点后，再次点击更改代理时，会看到不可用的现象，重试刷新一次即可正常测出延迟，属于正常现象。如果一直处于有连接的状态，不可用现象不会出现
    *   **2、**: 综上问题得出，个人使用或者几个人共用选择MTG(GO版)是比较稳定长久的选择。如果是多用户（一般为20个用户连接以上）可以选择Rust版。
---

## 📥 安装与使用

**快捷命令：mtp**

```
(curl -LfsS https://raw.githubusercontent.com/0xdabiaoge/MTProxy/main/mtp.sh -o /usr/local/bin/mtp || wget -q https://raw.githubusercontent.com/0xdabiaoge/MTProxy/main/mtp.sh -O /usr/local/bin/mtp) && chmod +x /usr/local/bin/mtp && mtp
```

## 结语
**基于MTPROTO代理的特性，建议仅自用！仅供测试。**
