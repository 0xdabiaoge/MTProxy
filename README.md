## **MTProxy 一键安装管理脚本**

## **本项目包含两个独立的脚本，分别适配Debian/Ubuntu和Alpine，仅在此两种系统中测试使用。

## **✨ 功能特性**
- **交互式安装：安装过程中会引导您设置自定义端口和伪装域名。**
- **一键式操作：无论是安装还是卸载，都只需一条命令即可完成。**
- **稳定可靠：使用兼容性极佳的 mtg v1.0.11 作为代理核心。**
- **轻量高效：资源占用极低，适合小内存机器使用。**

### **使用以下命令运行脚本**

**Debian/Ubuntu**
```
wget -O MTPv1.0.11.sh https://raw.githubusercontent.com/0xdabiaoge/MTPv1.0.11/main/MTPv1.0.11.sh && chmod +x MTPv1.0.11.sh && bash MTPv1.0.11.sh install
```

**Alpine**
```
wget -O MTPv1.0.11-Alpine.sh https://raw.githubusercontent.com/0xdabiaoge/MTPv1.0.11/main/MTPv1.0.11-Alpine.sh && chmod +x MTPv1.0.11-Alpine.sh && bash MTPv1.0.11-Alpine.sh install
```

**卸载**

**Debian/Ubuntu**
```
bash MTPv1.0.11.sh uninstall
```

**Alpine**
```
bash MTPv1.0.11-Alpine.sh uninstall
```

## **免责声明**
- **本项目仅供学习与技术交流，请在下载后 24 小时内删除，禁止用于商业或非法目的。**
- **使用本脚本所搭建的服务，请严格遵守部署服务器所在地、服务提供商和用户所在国家/地区的相关法律法规。**
- **对于任何因不当使用本脚本而导致的法律纠纷或后果，脚本作者及维护者概不负责。**
