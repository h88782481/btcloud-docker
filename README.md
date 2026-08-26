# btcloud Docker 部署（宝塔 Nginx 反代方案）

基于 [flucont/btcloud](https://github.com/flucont/btcloud) 的 Docker 部署方案。

## 架构

```
浏览器 ──> 宝塔 Nginx (80/443, SSL 由宝塔处理)
              │
              │  反向代理 (HTTP)
              ▼
       127.0.0.1:8080 ──> Docker 容器
                          ├── Nginx      (静态资源)
                          ├── PHP-FPM    (应用)
                          └── MariaDB    (数据库，数据落在 ./data/mysql)
```

**特点**：
- 宝塔 Nginx 只做**反向代理**（不读项目文件），负责域名/SSL/防火墙
- Nginx、PHP-FPM、MariaDB 跑在**同一个容器**里（`start.sh` 监管，任一进程退出容器自动重启）
- 数据库**内置**（MariaDB，兼容 MySQL），不依赖宝塔 MySQL，仅监听容器内 `127.0.0.1`
- **全部数据落在 `./data`**：`data/btcloud` 是源码和插件包，`data/mysql` 是数据库——
  换服务器时整个 `./data` 打包带走即可
- **项目可放任意目录**（`/root/`、`/opt/`、`/www/wwwroot/` 都行）

## 目录结构

```
/root/btcloud/                    ← 项目目录（可任意位置）
├── Dockerfile                    # Nginx + PHP-FPM + MariaDB 单容器镜像
├── docker-compose.yml            # 编排（只有一个 app 服务）
├── docker-entrypoint.sh          # 启动时修权限 + 初始化 MariaDB
├── start.sh                      # 容器内监管三个进程
├── update-btcloud.sh             # 自动更新脚本（打进镜像，容器内执行）
├── nginx.conf                    # 容器内 Nginx 站点配置
├── README.md
├── btcloud_3.8.zip               # 你下载的 Release 包
├── data/                         # ★ 全部数据，备份/迁移打包这个目录即可
│   ├── btcloud/                  #   btcloud 源码（Release 包解压到这）
│   │   ├── public/index.php
│   │   └── data/                 #   btcloud 内部数据（插件包、密钥）
│   └── mysql/                    #   MariaDB 数据目录（首次启动自动初始化）
└── logs/                         # 日志
    └── nginx/
```

## PHP 扩展

镜像额外编译安装：`pdo_mysql`（数据库）、`zip`（ZipArchive）、`gd`（登录验证码）。
`mbstring`、`fileinfo`、`curl`、`opcache` 等基础镜像已自带，无需重复安装。

---

## 部署步骤

### 1. 上传项目文件到服务器

把 `Dockerfile`、`docker-compose.yml`、`docker-entrypoint.sh`、`start.sh`、`update-btcloud.sh`、`nginx.conf` 上传到服务器任意目录，如 `/root/btcloud/`。

### 2. 下载并解压 btcloud Release 包

从 [Releases 页面](https://github.com/flucont/btcloud/releases) 下载最新的 zip（如 `btcloud_3.8.zip`），解压到 `data/btcloud`：

```bash
cd /root/btcloud
mkdir -p data/btcloud
unzip btcloud_3.8.zip -d data/btcloud

# 检查是否多套了一层目录
ls data/btcloud
# 如果看到 btcloud_3.8 之类的目录，执行：
# mv data/btcloud/btcloud_3.8/* data/btcloud/ && rm -rf data/btcloud/btcloud_3.8

# 最终必须存在
ls data/btcloud/public/index.php
```

### 3. 配置 docker-compose.yml

打开 `docker-compose.yml`，改 `environment` 里的两处：

```yaml
environment:
  BTCLOUD_DOMAIN: "https://bt.example.com"   # 改成你的站点域名
  MYSQL_PASSWORD: "ChangeMe_btcloud"         # 改成强密码（数据库密码）
```

数据库的库名/用户名默认都是 `btcloud`，一般不用动。首次启动会自动建库建用户；
以后改了 `MYSQL_PASSWORD` 重启容器即自动同步。

### 4. 启动 Docker 容器

```bash
cd /root/btcloud
docker compose up -d --build

# 查看状态
docker compose ps
# 应看到 btcloud 容器是 Up (running)

# 看日志（含 MariaDB 初始化过程）
docker compose logs -f
```

测试内部 Nginx 是否正常：

```bash
curl -I http://127.0.0.1:8080
# 应返回 200 或 302（重定向到安装页面）
```

### 5. 在宝塔面板新建反代站点

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

### 6. 访问安装向导

浏览器打开 `http://你的域名`，会跳到安装页面：

| 项目 | 值 |
|---|---|
| **数据库主机** | `127.0.0.1` |
| 数据库端口 | `3306` |
| 数据库名 | `btcloud`（compose 里 `MYSQL_DATABASE` 的值） |
| 数据库用户 | `btcloud`（compose 里 `MYSQL_USER` 的值） |
| 数据库密码 | compose 里 `MYSQL_PASSWORD` 设置的密码 |

> 数据库主机填 `127.0.0.1`，**不要填 `localhost`**（localhost 会走 socket 文件，路径对不上）。

### 7. 后续配置

按 btcloud 官方 README：
- 后台 → **批量替换工具** → 执行显示的命令
- 后台 → **系统基本设置** → 配置宝塔面板接口
- 后台 → **定时任务设置** → 获取最新插件列表

### 8. 开启 HTTPS（推荐）

宝塔面板 → 站点 → SSL → Let's Encrypt / 上传证书。宝塔会自动改 Nginx 配置加 SSL。

---

## 常用命令

```bash
cd /root/btcloud

# 启动 / 停止 / 重启
docker compose up -d
docker compose down
docker compose restart app

# 日志（php-fpm 和 MariaDB 输出到容器日志；nginx 访问/错误日志在 ./logs/nginx/）
docker compose logs -f app
tail -f logs/nginx/btcloud_access.log

# 进入容器
docker compose exec app sh

# 进入 MariaDB（root 在容器内免密）
docker compose exec app mariadb -u root btcloud

# 修改了 Dockerfile 后重建
docker compose build --no-cache && docker compose up -d

# 修改 nginx.conf 后重启即可生效（无需 rebuild）
docker compose restart app

# 修权限：重启即可，entrypoint 会自动检测并修复
docker compose restart app
```

> 权限修复行为可通过 app 服务的环境变量 `FIX_PERMS` 控制：
> `auto`（默认，检测到属主不对才修复）/ `always`（每次启动强制修复）/ `never`（跳过）。

## 资源占用（1C1G 服务器够用）

镜像默认参数已按低配服务器调优：

| 组件 | 配置 | 说明 |
|---|---|---|
| MariaDB | `innodb_buffer_pool_size=64M`、`performance_schema=OFF` | btcloud 的库只有几 MB，足够 |
| php-fpm | `pm=ondemand`，最多 4 个 worker，空闲 30s 回收 | 没请求时几乎不占内存 |
| PHP | `memory_limit=256M`（单请求上限） | 上传/下载走磁盘流式处理，够用 |
| OPcache | 64M | 应用代码量小 |

空闲时整个容器常驻内存大约 **150~250MB**，1C1G 跑没有压力。两个建议：

```bash
# 1G 内存的机器建议开 1~2G swap 兜底（已有 swap 可跳过）
fallocate -l 2G /swapfile && chmod 600 /swapfile && mkswap /swapfile && swapon /swapfile
echo '/swapfile none swap sw 0 0' >> /etc/fstab
```

大内存服务器想提性能：改 `Dockerfile` 里的 `innodb_buffer_pool_size`、`pm.max_children`、
`memory_limit`，然后 `docker compose build --no-cache && docker compose up -d`。

## 备份与迁移

全部数据都在 `./data`（源码 + 插件包 + 密钥 + 数据库），打包这一个目录就是完整备份：

```bash
cd /root/btcloud
docker compose stop          # 停库落盘，保证数据一致
tar czf btcloud-backup-$(date +%Y%m%d).tar.gz data
docker compose start
```

换服务器：新机器装好 Docker → 上传项目文件（第 1 步那几个）+ 解压 `data` 目录 →
`docker compose up -d --build`，起来就是原样，宝塔那边照第 5 步配一下反代即可。

也可以只做数据库的逻辑备份（在线执行，不用停容器）：

```bash
docker compose exec app mariadb-dump -u root btcloud > btcloud-$(date +%Y%m%d).sql
```

## 自动更新 btcloud（可选）

`update-btcloud.sh`（已打进镜像）会定时检查 [GitHub Releases](https://github.com/flucont/btcloud/releases)
有没有发新版，发现新版时自动完成官方升级流程：

1. 下载新版 Release 包
2. 按官方要求**覆盖除 `data` 文件夹外的全部文件**（插件包、密钥、数据库都不受影响）
3. 执行官方替换命令 `convert.sh`，把包内的 `http://www.example.com` 替换成你的站点域名

全部配置都在 `docker-compose.yml` 的 `environment` 里：

```yaml
environment:
  BTCLOUD_DOMAIN: "https://bt.example.com"   # 改成你的站点域名（替换域名时用）
  AUTO_UPDATE: "true"                        # 开启自动更新
  UPDATE_INTERVAL: "86400"                   # 检查新版本间隔（秒），默认 24 小时
```

开启后 `docker compose up -d` 重建容器即可：容器每次启动约 10 秒后检查一次，之后每隔
`UPDATE_INTERVAL` 重复。已安装的版本号记录在 `./data/btcloud/data/.release-tag`；首次运行时
该标记不存在，会直接按最新版覆盖一次（等于把当前部署对齐到最新 Release）。脚本内置并发锁，
更新失败不影响站点运行，下个周期自动重试。

```bash
# 手动触发一次检查/更新（无论 AUTO_UPDATE 是否开启都可以）
docker compose exec app update-btcloud.sh

# 看更新日志（输出在容器日志里，带 [update] 前缀）
docker compose logs -f app
```

> 需要服务器能访问 github.com；新版包 200MB+，下载耗时视网络而定。
> 升级完成后如需拉取最新插件列表，仍按官方说明到后台「定时任务设置」操作。

## btcloud 手动升级

开启上面的 `AUTO_UPDATE` 后这些步骤会自动完成；不想自动更新的可以手动做。
按官方要求：**覆盖除 btcloud 内部的 `data` 文件夹外的全部文件**。

> ⚠️ 注意区分：`./data/btcloud` 是挂载给容器的源码目录；`./data/btcloud/data/`
> 才是 btcloud 内部存插件包/密钥的目录（升级时要保留的就是它）。

```bash
cd /root/btcloud

# 1. 备份 btcloud 内部 data
mkdir -p backup
tar czf backup/btcloud-data-$(date +%Y%m%d).tar.gz -C data/btcloud data

# 2. 备份数据库
docker compose exec app mariadb-dump -u root btcloud > backup/btcloud-db-$(date +%Y%m%d).sql

# 3. 下载新版 zip 到项目目录（如 btcloud_3.9.zip），覆盖解压（排除内部 data）
unzip -o btcloud_3.9.zip -d data/btcloud -x "data/*"

# 4. 重启容器（触发 entrypoint 修权限）
docker compose restart app

# 5. 到浏览器后台执行：批量替换工具 → 获取最新插件列表 → 修改版本号

# 6. （可选）同步版本标记，避免 AUTO_UPDATE 下个周期重复覆盖同一版本
echo "3.9" > data/btcloud/data/.release-tag
```

## 从旧版部署迁移（外部宝塔 MySQL → 内置 MariaDB）

之前用"宝塔 MySQL + `./data` 直接放源码"的老布局，一次性迁移：

```bash
cd /root/btcloud

# 1. 导出旧数据库（宝塔面板备份，或命令行）
mysqldump -ubtcloud -p btcloud > btcloud-old.sql

# 2. 停容器，调整目录结构: ./data → ./data/btcloud
docker compose down
mkdir btcloud-tmp && mv data btcloud-tmp/btcloud && mv btcloud-tmp data
mkdir -p data/mysql

# 3. 更新本项目文件（compose/Dockerfile 等）后重建启动
docker compose up -d --build

# 4. 导入数据到内置 MariaDB
docker compose exec -T app mariadb -u root btcloud < btcloud-old.sql

# 5. 改 btcloud 的数据库连接配置
vi data/btcloud/.env
#   HOSTNAME = 127.0.0.1
#   DATABASE / USERNAME / PASSWORD 改成 compose 里 MYSQL_* 的值
docker compose restart app
```

确认一切正常后，宝塔的 MySQL 里那份旧库可以删掉，`bind-address` 也可以改回 `127.0.0.1`。

---

## 常见问题

### 1. 502 Bad Gateway（宝塔那边）
- 容器没起来：`docker compose ps` 看 btcloud 是否 Up
- 端口没通：`curl -I http://127.0.0.1:8080` 应该有响应
- 宝塔配置错了：确认反代目标是 `http://127.0.0.1:8080`

### 2. 502 Bad Gateway（容器内 Nginx 日志里）
- php-fpm 挂了。正常情况下 `start.sh` 会让整个容器退出并自动重启，
  若反复 502 先看日志找原因：`docker compose logs -f app`

### 3. File not found. / No input file specified.
- `./data/btcloud/public/index.php` 不存在，检查是否解压正确
- 容器里看不到：`docker compose exec app ls /var/www/html/public/`

### 4. 权限错误（Permission denied）
```bash
# 重启容器，entrypoint 检测到属主不对会自动修复
docker compose restart app
# 或手动修复
docker compose exec app chown -R www-data:www-data /var/www/html
```

### 5. SQLSTATE[HY000] [2002] Connection refused
- MariaDB 没起来或还在初始化：`docker compose logs -f app` 查 `[ERROR]` 或初始化报错
- 数据目录权限不对：重启容器让 entrypoint 自动修（`docker compose restart app`）
- 安装向导里数据库主机必须填 `127.0.0.1`（不要填 `localhost`）

### 6. SQLSTATE[HY000] [1045] Access denied
- 密码和 compose 里 `MYSQL_PASSWORD` 不一致；改好后 `docker compose restart app`
  会自动把数据库密码同步成环境变量的值
- 已安装过的还要检查 `data/btcloud/.env` 里的 `PASSWORD` 是否同步修改

### 7. 上传大文件超时
- PHP 里已配 1024M
- 内部 Nginx `client_max_body_size 1024M`
- **宝塔 Nginx 反代也要加**：`client_max_body_size 1024M`（见步骤 5 配置）

### 8. 无法获取真实客户端 IP（后台看到的都是 127.0.0.1）
- 宝塔 Nginx 反代已经通过 `X-Real-IP` / `X-Forwarded-For` 传了
- Docker 内部 Nginx 的 `nginx.conf` 已配置 `set_real_ip_from 127.0.0.1;`
- 若 btcloud 应用层还是拿不到，可能需要配置 `TRUSTED_PROXIES` 相关

### 9. 8080 端口被占用
- 改 `docker-compose.yml` 里 `ports` 的宿主机端口，如 `"127.0.0.1:8081:80"`
- 同步改宝塔反代目标为 `http://127.0.0.1:8081`
- `docker compose up -d`

---

## 安全建议

1. 内置 MariaDB 只监听容器内 `127.0.0.1`，且未映射端口——宿主机和公网都无法直连，无需额外加固
2. `docker-compose.yml` 中内部 Nginx 端口已限制在 `127.0.0.1`，公网只能通过宝塔 Nginx 访问
3. `MYSQL_PASSWORD` 务必改成强密码（虽然数据库不对外，纵深防御总没错）
4. 站点开启 HTTPS
5. 定期备份整个 `./data` 目录（见「备份与迁移」）

## 参考

- 项目主页：https://github.com/flucont/btcloud
- Release 下载：https://github.com/flucont/btcloud/releases
