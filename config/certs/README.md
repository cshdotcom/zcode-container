# 内网 HTTPS 自签证书（不入库）

仓库不含私钥。在本目录自行生成：

```bash
openssl req -x509 -nodes -newkey rsa:2048 -days 3650 \
  -keyout desktop-lan.key -out desktop-lan.crt \
  -subj "/CN=zcode-desktop-lan" \
  -addext "subjectAltName=DNS:desktop.你的域名,IP:127.0.0.1,IP:10.0.0.1,IP:192.168.0.1,IP:100.64.0.1"
chmod 600 desktop-lan.key
```

替换 SAN 为你的实际域名/内网网段；已有正式证书则直接覆盖两个文件。
