# btcloud Docker 部署（宝塔 Nginx 反代方案）

基于 [flucont/btcloud](https://github.com/flucont/btcloud) 的 Docker 部署方案。

## 架构

```
浏览器 ──> 宝塔 Nginx (80/443, SSL 由宝塔处理)
              │
              │  反向代理 (HTTP)
              ▼
       127.0.0.1:8080 ──> Docker Nginx ──> Docker PHP-FPM
                                                │
                                                ▼
                                    host.docker.internal ──> 宝塔 MySQL
```

**特点**：
- 宝塔 Nginx 只做**反向代理**（不读项目文件），负责域名/SSL/防火墙
- Docker 里跑 Nginx + PHP-FPM，独立处理静态资源和 PHP
- MySQL 用宝塔自带的，通过 `host.docker.internal` 访问
- **项目可放任意目录**（`/root/`、`/opt/`、`/www/wwwroot/` 都行）

## 目录结构

```
/root/btcloud/                    ← 项目目录（可任意位置）
├── Dockerfile                    # PHP-FPM 镜像
├── docker-compose.yml            # 编排 Nginx + PHP-FPM
├── docker-entrypoint.sh          # PHP-FPM 启动时自动修权限
├── nginx.conf                    # Docker Nginx 站点配置
├── README.md
├── BTCloud_v3.7.1.zip            # 你下载的 Release 包
├── data/                         # ★ btcloud 源码（Release 包解压到这）
│   ├── public/index.php
│   ├── app/
│   └── ...
└── logs/                         # 日志
    ├── nginx/
    └── php/
```

## PHP 镜像内置扩展

`fileinfo`、`zip`、`pdo_mysql`、`mysqli`、`mbstring`、`gd`、`opcache`、`bcmath`、`intl`、`exif`

---

## 部署步骤

### 1. 上传项目文件到服务器

把 `Dockerfile`、`docker-compose.yml`、`docker-entrypoint.sh`、`nginx.conf` 上传到服务器任意目录，如 `/root/btcloud/`。

### 2. 下载并解压 btcloud Release 包

从 [Releases 页面](https://github.com/flucont/btcloud/releases) 下载 `BTCloud_v3.7.1.zip`，放到项目目录：

```bash
cd /root/btcloud
mkdir -p data
unzip BTCloud_v3.7.1.zip -d data

# 检查是否多套了一层目录
ls data
# 如果看到 BTCloud_v3.7.1 之类的目录，执行：
# mv data/BTCloud_v3.7.1/* data/ && rm -rf data/BTCloud_v3.7.1

# 最终必须存在
ls data/public/index.php
```

### 3. 在宝塔面板创建数据库

**数据库 → 添加数据库**：

| 项目 | 值 |
|---|---|
| 数据库名 | `btcloud` |
| 用户名 | `btcloud` |
| 密码 | 设一个强密码，记住 |
| 访问权限 | **必须选 `所有人`**（默认只有 localhost，容器连不上） |

### 4. 让宝塔 MySQL 监听所有地址

宝塔默认 MySQL 只监听 `127.0.0.1`，容器无法访问。

**宝塔面板 → 软件商店 → MySQL → 配置修改**，找到 `bind-address` 改为 `0.0.0.0`：

```ini
# bind-address = 127.0.0.1
bind-address = 0.0.0.0
```

保存后 **重启 MySQL**。

> 放心，宿主机防火墙没开 3306 端口，公网访问不了；只有本机和 Docker 容器能连。

### 5. 启动 Docker 容器

```bash
cd /root/btcloud
docker compose up -d --build

# 查看状态
docker compose ps
# 应看到 btcloud-nginx 和 btcloud-php 都是 running/healthy

# 看日志
docker compose logs -f
```

测试内部 Nginx 是否正常：

```bash
curl -I http://127.0.0.1:8080
# 应返回 200 或 302（重定向到安装页面）
```

### 6. 测试容器能否连宝塔 MySQL

```bash
docker compose exec php sh -c 'php -r "new PDO(\"mysql:host=host.docker.internal;dbname=btcloud\",\"btcloud\",\"你的密码\"); echo \"OK\";"'
```

看到 `OK` 就通了。报错请回到第 3、4 步。

### 7. 在宝塔面板新建反代站点

**网站 → 添加站点**：

- 域名：你的域名
- 根目录：随便填一个（比如 `/www/wwwroot/btcloud-proxy`），反正不会用到
- PHP 版本：选 **纯静态**
- 数据库：不创建
- FTP：不创建

创建后：

**网站 → 你的站点 → 设置 → 反向代理 → 添加反向代理**：

| 项目 | 值 |
|---|---|
| 代理名称 | `btcloud` |
| 目标 URL | `http://127.0.0.1:8080` |
| 发送域名 | `$host` |

**⚠️ 关键**：勾选 **"添加反代信息" / "启用反代"**。

或者直接改配置文件 → **设置 → 配置文件**，替换 `server { ... }` 为：

```nginx
server {
    listen 80;
    server_name 你的域名;

    # SSL 相关（宝塔申请证书后自动加，先不管）

    # 大文件上传/超时
    client_max_body_size 1024M;
    client_body_timeout 600s;
    send_timeout 600s;
    proxy_read_timeout 600s;
    proxy_send_timeout 600s;
    proxy_connect_timeout 60s;

    location / {
        proxy_pass http://127.0.0.1:8080;
        proxy_http_version 1.1;
        proxy_set_header Host $host;
        proxy_set_header X-Real-IP $remote_addr;
        proxy_set_header X-Forwarded-For $proxy_add_x_forwarded_for;
        proxy_set_header X-Forwarded-Proto $scheme;
        proxy_set_header X-Forwarded-Host $host;
        proxy_buffering off;
        proxy_request_buffering off;
    }

    access_log  /www/wwwlogs/btcloud.log;
    error_log   /www/wwwlogs/btcloud.error.log;
}
```

保存后宝塔自动 reload。

### 8. 访问安装向导

浏览器打开 `http://你的域名`，会跳到安装页面：

| 项目 | 值 |
|---|---|
| **数据库主机** | `host.docker.internal` |
| 数据库端口 | `3306` |
| 数据库名 | `btcloud`（第 3 步创建的） |
| 数据库用户 | `btcloud` |
| 数据库密码 | 你在宝塔设置的密码 |

> **数据库主机不能填 `localhost`！** 容器里的 `localhost` 是容器自身。
> 填 `host.docker.internal`（推荐），或 `172.17.0.1`。

### 9. 后续配置

按 btcloud 官方 README：
- 后台 → **批量替换工具** → 执行显示的命令
- 后台 → **系统基本设置** → 配置宝塔面板接口
- 后台 → **定时任务设置** → 获取最新插件列表

### 10. 开启 HTTPS（推荐）

宝塔面板 → 站点 → SSL → Let's Encrypt / 上传证书。宝塔会自动改 Nginx 配置加 SSL。

---

## 常用命令

```bash
cd /root/btcloud

# 启动 / 停止
docker compose up -d
docker compose down

# 重启单个服务
docker compose restart nginx
docker compose restart php

# 日志
docker compose logs -f nginx
docker compose logs -f php

# 进入容器
docker compose exec php sh
docker compose exec nginx sh

# 修改了 Dockerfile 后重建
docker compose build php --no-cache && docker compose up -d php

# 修改 nginx.conf 后重启（无需 rebuild）
docker compose restart nginx

# 手动修权限
docker compose exec php sh -c 'chown -R www-data:www-data /var/www/html'
docker compose exec php sh -c 'chmod -R 775 /var/www/html/data /var/www/html/runtime'
```

## btcloud 升级

按官方要求：**覆盖除 btcloud 内部的 `data` 文件夹外的全部文件**。

> ⚠️ 注意区分：**外层 `./data`** 是挂载给容器的源码目录（不能删）；**内层 `./data/data/`** 才是 btcloud 里存插件包的目录（要保留）。

```bash
cd /root/btcloud

# 1. 备份 btcloud 内部 data
mkdir -p backup
tar czf backup/btcloud-data-$(date +%Y%m%d).tar.gz -C data data

# 2. 备份数据库（宝塔面板里点"备份"）

# 3. 下载新版 zip 到项目目录（如 BTCloud_v3.7.2.zip），覆盖解压（排除内部 data）
unzip -o BTCloud_v3.7.2.zip -d data -x "data/*"

# 4. 重启 PHP-FPM（触发 entrypoint 修权限）
docker compose restart php

# 5. 到浏览器后台执行：批量替换工具 → 获取最新插件列表 → 修改版本号
```

---

## 常见问题

### 1. 502 Bad Gateway（宝塔那边）
- 内部 Nginx 没起来：`docker compose ps`
- 端口没通：`curl -I http://127.0.0.1:8080` 应该有响应
- 宝塔配置错了：确认反代目标是 `http://127.0.0.1:8080`

### 2. 502 Bad Gateway（内部 Nginx 日志里）
- PHP-FPM 没起来：`docker compose logs php`
- 内部 Nginx 里 `fastcgi_pass php:9000` 里的 `php` 是 docker-compose 服务名，正常应该自动解析

### 3. File not found. / No input file specified.
- `./data/public/index.php` 不存在，检查是否解压正确
- 容器里看不到：`docker compose exec nginx ls /var/www/html/public/`

### 4. 权限错误（Permission denied）
```bash
docker compose exec php sh -c 'chown -R www-data:www-data /var/www/html'
docker compose exec php sh -c 'chmod -R 775 /var/www/html/data /var/www/html/runtime'
# 或者直接重启（entrypoint 会自动修）
docker compose restart php
```

### 5. SQLSTATE[HY000] [2002] Connection refused
宝塔 MySQL 未监听 `0.0.0.0`。参考步骤 4。

### 6. SQLSTATE[HY000] [1130] Host '172.17.x.x' is not allowed
宝塔数据库用户权限没设为"所有人"。参考步骤 3。

### 7. 上传大文件超时
- PHP 里已配 1024M
- 内部 Nginx `client_max_body_size 1024M`
- **宝塔 Nginx 反代也要加**：`client_max_body_size 1024M`（见步骤 7 配置）

### 8. 无法获取真实客户端 IP（后台看到的都是 127.0.0.1）
- 宝塔 Nginx 反代已经通过 `X-Real-IP` / `X-Forwarded-For` 传了
- Docker 内部 Nginx 的 `nginx.conf` 已配置 `set_real_ip_from 127.0.0.1;`
- 若 btcloud 应用层还是拿不到，可能需要配置 `TRUSTED_PROXIES` 相关

### 9. host.docker.internal 无法解析
- 需要 Docker 20.10+
- 检查：`docker compose exec php ping -c 1 host.docker.internal`
- 不行改用 `172.17.0.1`

### 10. 8080 端口被占用
- 在项目目录下创建 `.env` 文件，写入 `HTTP_PORT=8081`（或其他未占用端口）
- 同步改宝塔反代目标为 `http://127.0.0.1:8081`
- `docker compose down && docker compose up -d`

---

## 安全建议

1. 宝塔 MySQL `bind-address` 改为 `0.0.0.0` 后，**务必**在宝塔防火墙确认 3306 端口**没有开放**到公网
2. `docker-compose.yml` 中内部 Nginx 端口已限制在 `127.0.0.1`，公网只能通过宝塔 Nginx 访问
3. 数据库密码务必强密码
4. 站点开启 HTTPS
5. 定期备份 `./data/data`（btcloud 内部 data 目录）和 MySQL

## 参考

- 项目主页：https://github.com/flucont/btcloud
- Release 下载：https://github.com/flucont/btcloud/releases
