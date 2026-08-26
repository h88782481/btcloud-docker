#!/bin/bash
# btcloud 自动更新脚本（容器内执行，已打进镜像 /usr/local/bin/）
# 1) 查询 GitHub 最新 Release（flucont/btcloud）
# 2) 与已安装版本（data/.release-tag）不一致时下载新版
# 3) 按官方升级方法覆盖除 data 目录外的全部文件
# 4) 执行官方 convert.sh 把包内 http://www.example.com 替换为你的站点域名
#
# 域名优先级: 参数 $1 > 环境变量 BTCLOUD_DOMAIN（在 docker-compose.yml 里配置）
# 自动执行: docker-compose.yml 里 AUTO_UPDATE=true 时由 start.sh 定时调用
# 手动执行: docker compose exec app update-btcloud.sh

set -u

APP_DIR="/var/www/html"
REPO="flucont/btcloud"
# 记录当前已安装的 Release tag；放在 data 目录里，升级覆盖时会保留
MARKER="${APP_DIR}/data/.release-tag"
DOMAIN="${1:-${BTCLOUD_DOMAIN:-}}"

log() {
    echo "[update] $(date '+%Y-%m-%d %H:%M:%S') $*"
}

# root 执行时降权到 www-data，避免产生 root 属主的文件
if [ "$(id -u)" = "0" ]; then
    exec su-exec www-data "$0" "${DOMAIN}"
fi

if [[ ! "${DOMAIN}" =~ ^https?:// ]] || [[ "${DOMAIN}" == *"example.com"* ]]; then
    log "ERROR: 域名未配置或不正确（当前值: '${DOMAIN}'）"
    log "       请在 docker-compose.yml 的 environment 里设置 BTCLOUD_DOMAIN"
    exit 1
fi

if [ ! -f "${APP_DIR}/think" ]; then
    log "SKIP: ${APP_DIR} 里没有 btcloud 源码，请先完成首次部署"
    exit 0
fi

# 防止并发（自动循环和手动触发同时跑）
exec 9>/tmp/btcloud-update.lock
if ! flock -n 9; then
    log "SKIP: 已有更新任务在运行"
    exit 0
fi

# --- 查询最新 Release ---
api_json="$(curl -fsSL --connect-timeout 10 --max-time 60 \
    -H 'Accept: application/vnd.github+json' \
    "https://api.github.com/repos/${REPO}/releases/latest")" || {
    log "ERROR: 查询 GitHub Release 失败（网络不通或 API 限流），下个周期重试"
    exit 2
}

latest_tag="$(jq -r '.tag_name // empty' <<< "${api_json}")"
zip_url="$(jq -r '[.assets[] | select(.name | endswith(".zip"))][0].browser_download_url // empty' <<< "${api_json}")"

if [ -z "${latest_tag}" ] || [ -z "${zip_url}" ]; then
    log "ERROR: 未能从 GitHub API 解析出版本号或下载地址"
    exit 2
fi

current_tag="$(cat "${MARKER}" 2>/dev/null || true)"
if [ "${current_tag}" = "${latest_tag}" ]; then
    log "已是最新版本 (${latest_tag})，无需更新"
    exit 0
fi

log "发现新版本: ${current_tag:-未知} -> ${latest_tag}，开始更新"

# --- 下载并解压 ---
tmp_dir="$(mktemp -d /tmp/btcloud-update.XXXXXX)"
trap 'rm -rf "${tmp_dir}"' EXIT

log "正在下载 ${zip_url} ..."
if ! curl -fSL --connect-timeout 10 --max-time 3600 --retry 2 \
        -o "${tmp_dir}/release.zip" "${zip_url}"; then
    log "ERROR: 下载失败，下个周期重试"
    exit 3
fi

if ! unzip -q "${tmp_dir}/release.zip" -d "${tmp_dir}/src"; then
    log "ERROR: 解压失败"
    exit 3
fi

# 定位源码目录（zip 可能多套一层目录，以 think 文件为标志）
src_dir="${tmp_dir}/src"
if [ ! -f "${src_dir}/think" ]; then
    src_dir="$(dirname "$(find "${tmp_dir}/src" -maxdepth 3 -type f -name think 2>/dev/null | head -n 1)")"
fi
if [ ! -f "${src_dir}/think" ]; then
    log "ERROR: 新版包里找不到 btcloud 源码（think 文件）"
    exit 3
fi

# --- 按官方升级方法覆盖: 除 data 文件夹以外全部覆盖 ---
log "正在覆盖文件（保留 data 目录）..."
(
    cd "${src_dir}"
    for item in * .[!.]* ..?*; do
        [ -e "${item}" ] || continue
        [ "${item}" = "data" ] && continue
        cp -a "${item}" "${APP_DIR}/" || exit 1
    done
) || {
    log "ERROR: 覆盖文件失败"
    exit 4
}

# --- 官方域名替换 ---
log "正在执行 convert.sh 替换域名为 ${DOMAIN} ..."
if ! (cd "${APP_DIR}/app/script" && chmod +x convert.sh \
        && ./convert.sh "${APP_DIR}/" "${DOMAIN}" 2> >(grep -v "warning: stray" >&2)); then
    log "ERROR: convert.sh 执行失败"
    exit 5
fi

mkdir -p "${APP_DIR}/data"
printf '%s\n' "${latest_tag}" > "${MARKER}"
log "更新完成: 当前版本 ${latest_tag}"
log "提示: 如需获取最新插件列表，请按官方说明到后台「定时任务设置」操作"
