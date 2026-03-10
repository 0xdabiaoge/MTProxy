# MTProxy 一键管理脚本 (Go / Rust 双内核版)

支持 **Debian/Ubuntu** 和 **Alpine Linux** 双系统。**兼容完整KVM和LXC以及更为精简的Docker虚拟化LXC**。共分为 **Go**、**Rust** 两个不同的版本。本脚本采用预编译二进制文件安装，GO版由：  [mtg](https://github.com/9seconds/mtg) 源代码重构优化编译所得。telemt（Rust）版由：  [telemt](https://github.com/telemt/telemt) 源代码重写优化编译所得。

## ✨ 核心特性

*   **🚀 内核架构**:
    *   **Go 版 (mtg)**: 源码优化版。内存占用极低，性能强悍，抗重放攻击，强FakeTLS伪装机制。适合个人或者小团体使用。高并发、延迟低、速度快。
    *   **telemt（Rust）版**: 在原版的基础上新增多用户管理，可以决定用户代理链接的流量配额、到期时间等。整合了GO版的优势点。
*   **🎯 监听模式**: 
    *   **IPV4模式**: 仅支持IPV4地址的出入站连接，并以IPV4地址作为MTPROTO的链接。
    *   **IPV6模式**: 仅支持IPV6地址的出入站连接，并以IPV6地址作为MTPROTO的链接。
    *   **双栈模式**: 同时输出IPV4、IPV6两种链接，分别设置端口，应对不同的网络环境。
---

## 📥 安装与使用

**快捷命令：mtp**

```
(curl -LfsS https://raw.githubusercontent.com/0xdabiaoge/MTProxy/main/mtp.sh -o /usr/local/bin/mtp || wget -q https://raw.githubusercontent.com/0xdabiaoge/MTProxy/main/mtp.sh -O /usr/local/bin/mtp) && chmod +x /usr/local/bin/mtp && mtp
```

## 💧 流量配额重置测试

```mtp force_reset``` 立即测试流量重置
```mtp``` 打开管理面板
```mtp check_reset``` Cron 静默检查（日常由 Cron 自动调用）


## 结语
**基于MTPROTO代理的特性，建议仅自用！仅供测试。**

## 更新日志
## 2026.03.01
**GO版重构优化**：GO版进行了新一轮的重构优化，GO版优化了之前遗留下来的僵尸链接的问题，多用户连接时会出现内存溢出的问题也得到了修复。

## 2026.03.03
**加入telemt（Rust版）**：基于项目：[telemt](https://github.com/telemt/telemt) 提供的源代码，进行了一些修复，原版并不支持单用户单端口的模式，改版后支持了单用户单端口，对于临时分享给朋友使用提供了便利，不会对其他用户造成影响，只需要删掉对应用户名即可失效。

## 2026.03.10
**telemt版深度优化**：在原有多用户管理的基础上，新增了用户的流量配额、到期时间的控制，满足其一会自动阻断对应用户名的链接。
