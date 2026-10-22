# btcloud Docker 部署

为 [flucont/btcloud](https://github.com/flucont/btcloud) 提供单容器部署：宝塔 Nginx 负责域名和 HTTPS，容器运行 Nginx、PHP-FPM、MariaDB。

在 `docker-compose.yml` 的 `build.args.BTCLOUD_RELEASE_TAG` 中指定 btcloud 版本，执行 `docker compose up -d --build` 部署或更新。

## 目录与请求链路

浏览器 → 宝塔 Nginx（80/443）→ 宿主机 `127.0.0.1:8080` → 容器 Nginx → PHP-FPM → 容器内 MariaDB。

```text
项目目录/
├── Dockerfile
├── docker-compose.yml
├── docker-entrypoint.sh
├── start.sh
├── nginx.conf
├── .dockerignore
└── data/
    ├── btcloud/              # 应用源码，首次启动从镜像部署
    │   ├── .env             # 应用数据库配置，升级时保留
    │   └── data/            # 应用内部数据，升级时保留
    │       └── .release-tag # 上次成功部署的 Release tag
    └── mysql/               # MariaDB 数据目录
```

源码包保存在镜像的 `/opt/btcloud`，实际运行目录是挂载的 `/var/www/html`。数据库只监听容器回环地址，不映射 3306 端口。

## 首次部署

### 1. 准备文件与配置

将本项目文件放到服务器目录，例如 `/root/btcloud`。无需手动下载或解压 btcloud 安装包。

修改 `docker-compose.yml` 的三个必填项：

- `build.args.BTCLOUD_RELEASE_TAG`：从 [上游 Releases](https://github.com/flucont/btcloud/releases) 选择版本，原样填写 Release tag。
- `environment.BTCLOUD_DOMAIN`：实际站点地址，例如 `https://bt.your-domain.net`。可带端口，不能带路径或末尾斜杠。
- `environment.MYSQL_PASSWORD`：数据库密码。Compose 中的 `$` 需要写成 `$$`；包含反斜杠时建议用 YAML 单引号包裹。

`MYSQL_DATABASE` 和 `MYSQL_USER` 在 Compose 中设置为 `btcloud`，可以修改。库名、用户名只允许字母、数字、下划线，首字符不能是数字。

### 2. 构建并启动

```bash
cd /root/btcloud
docker compose up -d --build
docker compose logs -f app
```

构建时通过 GitHub API 查询指定 tag，下载该 Release 中唯一的 ZIP 安装包。ZIP 根目录必须直接包含 `think`、`public/index.php`、`app/script/convert.sh` 和 `data/`。下载、解压或结构校验失败会终止构建。

启动时依次执行：

1. 校验配置。
2. 首次部署或 tag 改变时，从镜像覆盖源码，保留已有 `data/` 和 `.env`，执行官方域名替换脚本。
3. 修复不符合要求的属主和权限，保留文件执行位，限制 `.env` 权限为 `600`。
4. 首次初始化 MariaDB 数据目录，启动数据库并等待连接可用，执行建库、建用户及同步密码的 SQL。
5. 启动 PHP-FPM 和 Nginx。

SQL 初始化失败不会启动 Web 服务。任一受管进程退出时，其他进程会关闭，容器由 Compose 的 `restart: unless-stopped` 策略重启。配置错误应先停止容器并修正，避免反复启动。

### 3. 配置宝塔反代

宝塔创建网站，PHP 版本选择“纯静态”，不创建数据库或 FTP。反向代理目标设为 `http://127.0.0.1:8080`，发送域名设为 `$host`，HTTPS 证书由宝塔管理。

反代配置示例：

```nginx
server {
    listen 80;
    server_name bt.your-domain.net;

    client_max_body_size 1056M;
    client_body_timeout 600s;
    send_timeout 600s;

    location / {
        proxy_pass http://127.0.0.1:8080;
        proxy_http_version 1.1;
        proxy_set_header Host $host;
        proxy_set_header X-Real-IP $remote_addr;
        proxy_set_header X-Forwarded-For $proxy_add_x_forwarded_for;
        proxy_set_header X-Forwarded-Proto $scheme;
        proxy_set_header X-Forwarded-Host $host;
        proxy_connect_timeout 60s;
        proxy_read_timeout 600s;
        proxy_send_timeout 600s;
        proxy_buffering off;
        proxy_request_buffering off;
    }
}
```

### 4. 完成应用安装

访问站点，在安装向导中填写：

- 数据库主机：`127.0.0.1`，端口：`3306`。
- 数据库名、用户名、密码：与 Compose 的 `MYSQL_*` 配置一致。

数据库主机使用 TCP 地址 `127.0.0.1`。容器创建数据库和账户，业务表由 btcloud 安装向导创建。

首次部署已执行域名替换。之后在后台配置宝塔面板接口，并根据界面提示安装专用插件。

## 定时同步插件

默认关闭。完成应用安装和宝塔面板接口配置后，修改 Compose 中的设置：

```yaml
PLUGIN_SYNC_ENABLED: "true"
PLUGIN_SYNC_INTERVAL: "86400"
```

执行 `docker compose up -d --build` 应用配置。容器启动后立即执行一次 `php think updateall`，获取插件列表并增量下载插件包；每轮命令结束后等待 `PLUGIN_SYNC_INTERVAL` 秒再执行，`86400` 表示 24 小时。

同步以 `www-data` 身份运行，接口和下载范围使用后台保存的设置。每轮串行执行，输出可通过 `docker compose logs -f app` 查看。命令以非零状态退出时，按现有进程监管策略重启容器。

将 `PLUGIN_SYNC_ENABLED` 改回 `"false"`，执行 `docker compose up -d` 即可关闭。仅修改这些环境变量时也可以直接使用 `docker compose up -d`。

## 更新 btcloud

先备份，然后修改 Compose 中的 `BTCLOUD_RELEASE_TAG`，执行：

```bash
docker compose up -d --build
docker compose logs -f app
```

下载和构建发生在替换运行容器之前，构建失败不会修改正在运行的源码。新容器启动时才同步新版本，此时 Web 服务尚未启动；完成后由全新的 PHP-FPM 进程加载代码。

同步遵循上游的覆盖升级方式，不删除旧版中存在但新版未包含的文件。应用内部 `data/`、已有 `.env` 和数据库数据保留；其他源码可能被覆盖。没有自动执行数据库迁移或同步插件列表，具体版本的额外操作以该 Release 说明为准。

tag 与 `data/btcloud/data/.release-tag` 相同时，启动不覆盖源码。首次接入本方案的旧部署如果没有版本标记，会按配置的 tag 部署一次，因此接入前也应备份。

修改 `BTCLOUD_DOMAIN` 不会自动重写已部署的同版本源码及已有插件中的旧域名。更换域名时按应用后台的批量替换流程处理，并同步 Compose 配置，供后续版本部署使用。

### 部署中断

同步源码前会创建 `data/btcloud/.deployment-in-progress`，只有文件复制、域名替换和版本标记写入都成功后才删除。

如果复制或替换失败，启动直接退出；后续启动发现标记仍在时会报错停止，不自动再次覆盖。先执行 `docker compose stop`，根据日志处理原因，并恢复升级前完整的 `data` 备份及对应配置后再启动。不要仅删除这个标记让未完成部署的源码对外提供服务。

仅改回旧 tag 不能回滚数据库结构或应用数据。降级需要恢复与旧版本匹配的备份，并确认 MariaDB 版本兼容。

## 运行环境版本

基础镜像使用 `php:8.3-fpm-alpine`，PHP 保持在 8.3 系列，跟随上游更新补丁版本。Alpine 及其软件包版本随该镜像标签更新。

Compose 的 `build.pull: true` 会在构建时检查并拉取该标签的最新镜像；镜像未变化时复用本地已有层。

Docker 仍会复用未失效的构建层。如果需要重新安装软件源中的最新包，可以执行：

```bash
docker compose build --no-cache
docker compose up -d
```

Alpine 更新可能带来 MariaDB 版本变化。已有数据库的数据目录需要符合 MariaDB 的升级要求，跨不兼容版本时使用逻辑导出、导入迁移。

## 日常操作

```bash
# 查看状态与日志：Nginx、PHP-FPM、MariaDB 均输出到容器日志
docker compose ps
docker compose logs -f app

# 停止、启动、重启已有容器
docker compose stop
docker compose start
docker compose restart app

# 应用 Compose 配置变更；修改环境变量后不能只执行 restart
docker compose up -d

# 修改 Dockerfile 或入口脚本后重建
docker compose up -d --build

# nginx.conf 是只读挂载，修改后重启生效
docker compose restart app

# 使用容器内 root 的 Unix socket 认证进入数据库
docker compose exec app mariadb --protocol=socket -u root btcloud
```

修改数据库密码时，需要同时修改 Compose 的 `MYSQL_PASSWORD` 和 `data/btcloud/.env` 中的应用密码，然后执行 `docker compose up -d`。初始化 SQL 使用密码哈希，不将明文密码拼接进 SQL。

停止时先终止插件同步任务（如果已开启），再让 Nginx 完成现有请求、停止 PHP-FPM，最后停止 MariaDB。请求最长执行时间为 600 秒，容器停止宽限期为 11 分钟；没有正在执行的请求时通常不需要等待这么久。

PHP-FPM 按需启动，最多两个 worker，每个请求的 PHP 内存限制为 256M；MariaDB 的 InnoDB 缓冲池为 64M。实际峰值内存仍取决于业务请求和并发量，不能把空闲占用当作容量保证。

## 备份与迁移

停止容器后备份 `data` 和部署配置，保证数据库数据文件一致：

```bash
docker compose stop
tar czf btcloud-backup-$(date +%Y%m%d-%H%M%S).tar.gz \
    data Dockerfile docker-compose.yml docker-entrypoint.sh start.sh nginx.conf .dockerignore
docker compose start
```

数据库逻辑备份示例（示例库名为 `btcloud`）：

```bash
docker compose exec -T app mariadb-dump --single-transaction -u root btcloud > btcloud.sql
```

迁移时还原项目文件和 `data` 目录，确认目标运行环境与数据库版本兼容，再执行 `docker compose up -d --build` 并配置宝塔反代。
