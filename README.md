# MTPv1.0.11
MTProxy 一键安装管理脚本这是一个为低内存 VPS 设计的、轻量级的 Telegram MTProxy 代理一键安装与管理脚本。脚本旨在提供最简单、最稳定的部署体验，帮助您快速搭建专属的 MTProxy 服务。本项目包含两个独立的脚本，分别适配不同的 Linux 发行版：Debian / Ubuntu 等使用 apt 包管理器的系统Alpine Linux 等使用 apk 包管理器的系统✨ 功能特性交互式安装：安装过程中会引导您设置自定义端口和伪装域名。一键式操作：无论是安装还是卸载，都只需一条命令即可完成。系统适配：提供专门为 Debian/Ubuntu 和 Alpine Linux 优化的版本。稳定可靠：使用经过长期验证、兼容性极佳的 mtg v1.0.11 作为代理核心。轻量高效：资源占用极低，非常适合 256MB 等小内存规格的 VPS。纯净卸载：卸载功能会彻底清理所有相关文件，不留任何残留。🚀 使用方法前提条件您需要一台位于海外的 VPS，并以 root 用户身份登录。1. 一键安装根据您的服务器操作系统，选择对应的一键安装命令并执行：对于 Debian / Ubuntu 系统：wget -O mtp.sh https://raw.githubusercontent.com/0xdabiaoge/MTPv1.0.11/main/mtp_debian.sh && chmod +x mtp.sh && bash mtp.sh install
对于 Alpine Linux 系统：wget -O mtp.sh https://raw.githubusercontent.com/0xdabiaoge/MTPv1.0.11/main/mtp_alpine.sh && chmod +x mtp.sh && bash mtp.sh install
命令执行后，脚本将引导您完成配置。安装成功后，会自动显示您的服务器 IP、端口、密钥以及一键连接链接。2. 卸载代理当您不再需要此代理服务时，可以先下载脚本，然后运行卸载命令：# 下载脚本 (如果服务器上没有 mtp.sh 文件)
# Debian/Ubuntu:
# wget -O mtp.sh https://raw.githubusercontent.com/0xdabiaoge/MTPv1.0.11/main/mtp_debian.sh
# Alpine:
# wget -O mtp.sh https://raw.githubusercontent.com/0xdabiaoge/MTPv1.0.11/main/mtp_alpine.sh

# 运行卸载
bash mtp.sh uninstall
该命令会停止服务并删除所有相关文件。📝 注意事项请确保在 root 用户下执行此脚本。安装过程中，脚本会自动安装 curl, wget, bind-tools (或 dnsutils) 等必要的依赖工具。脚本会在 /home/mtproxy 目录下创建并存放所有相关文件。🙏 致谢本项目中使用的代理核心程序 mtg 由 9seconds 开发，特此感谢。
