## **MTProxy 一键安装管理脚本**

## **本项目包含两个独立的脚本，分别适配Debian/Ubuntu和Alpine，仅在此两种系统中测试使用。

## **✨ 功能特性**
- **交互式安装：安装过程中会引导您设置自定义端口和伪装域名。**
- **一键式操作：无论是安装还是卸载，都只需一条命令即可完成。**
- **稳定可靠：使用兼容性极佳的 mtg v1.0.11 作为代理核心。**
- **轻量高效：资源占用极低，适合小内存机器使用。**

### **使用以下命令运行脚本**


```
wget -O mtp.sh https://raw.githubusercontent.com/0xdabiaoge/MTPv1.0.11/main/mtp_debian.sh && chmod +x mtp.sh && bash mtp.sh install
```
## **使用方法**
- **如果开启ECH配置则不会生成Clash客户端配置文件。**
- **Clash客户端配置文件位于/usr/local/etc/sing-box/clash.yaml，下载后加载到 clash verge 客户端即可使用。**
- **节点链接在创建节点成功后会显示在下方，也可以通过菜单选择 14 查看节点信息中获取，复制粘贴到 v2rayN 即可使用**
- **节点信息查看: 所有创建的节点信息都会汇总保存在 /usr/local/etc/sing-box/output.txt 中，方便随时查看。**
- **卸载脚本: 在脚本主菜单选择 20 即可完全卸载，此操作会干净地移除所有相关文件、服务和定时任务，并自动删除脚本本身。**

## **精简版脚本支持的节点类型（仅保留较为常用的节点协议）**
- **SOCKS**
- **VMess (+TCP/WS/gRPC, 可选 TLS)**
- **VLESS (+TCP/WS, 可选 REALITY)**
- **TUIC**
- **Trojan (+TCP/WS/gRPC, 需 TLS)**
- **Hysteria2**
- **Shadowsocks**

## **yaml配置文件模板，可做参考**
- **脚本生成的yaml配置文件是默认配置，没有其他多余的写法，下面提供了一份包含链式代理的模板可供参考**
- **[Release](https://github.com/0xdabiaoge/singbox-lite/releases)**

## **免责声明**
- **本项目仅供学习与技术交流，请在下载后 24 小时内删除，禁止用于商业或非法目的。**
- **使用本脚本所搭建的服务，请严格遵守部署服务器所在地、服务提供商和用户所在国家/地区的相关法律法规。**
- **对于任何因不当使用本脚本而导致的法律纠纷或后果，脚本作者及维护者概不负责。**
