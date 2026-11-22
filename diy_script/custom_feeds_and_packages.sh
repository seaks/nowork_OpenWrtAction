#!/bin/bash
#
# feeds 与自定义软件包
#
# 分工原则（避免同一仓库被拉两遍）：
#   repos(              )  -> 只放「不在这里 clone」的仓库，由 ./scripts/feeds 拉取
#   clone_custom_packages() -> 需要打补丁 / 改默认主题 / 规范化版本号的包，手动 clone
#
# 注意：clone_with_retry 用 flag 解析（先吃 -b，再取 url / dest），
#       调用处可以直接写 "-b <branch>"，参数不会错位
#

# feeds扩展内容
export repos=(
  "src-git passwall_packages https://github.com/Openwrt-Passwall/openwrt-passwall-packages.git;main"
  "src-git passwall https://github.com/Openwrt-Passwall/openwrt-passwall.git;main"
  "src-git passwall2 https://github.com/Openwrt-Passwall/openwrt-passwall2.git;main"
  "src-git OpenClash https://github.com/vernesong/OpenClash;master"
  "src-git ghfu https://github.com/seaks/openwrt-ghfu.git;main"
  "src-git nikki https://github.com/nikkinikki-org/OpenWrt-nikki.git;main"
  "src-git helloworld https://github.com/fw876/helloworld.git;dev"
  "src-git small https://github.com/kenzok8/small"

  # 以下仓库已由 clone_custom_packages 拉取，不要再进 feeds，
  # 否则 package/ 与 feeds/ 各存一份，编译只会用 package/ 那份，属于白拉一次：
  #   vantage -> anothaDev/luci-theme-vantage
  #   mosdns  -> sbwml/luci-app-mosdns (v5)
  #   bandix  -> timsaya/luci-app-bandix
  #   bandi   -> timsaya/openwrt-bandix
)

# 自定义软件包列表
clone_custom_packages () {
    local path="package/custom_packages/"

    if [ "$GITHUB_ACTIONS" = "true" ] && [ -n "$GITHUB_RUN_ID" ] && [ -n "$GITHUB_WORKFLOW" ]; then
        PATCHES_SRC_DIR="$GITHUB_WORKSPACE"
    else
        PATCHES_SRC_DIR="../OpenWrtAction"
    fi

    # ------------------------------------------------------------------
    # 带重试的克隆
    #   用法: clone_with_retry [-b <branch>] <url> [dest]
    #   dest 省略时取 url 末段；显示名一律取 dest 末段，避免日志出现 "clone v5"
    # ------------------------------------------------------------------
    clone_with_retry() {
        local branch="" url="" dest="" rc=0 i
        while [ $# -gt 0 ]; do
            case "$1" in
                -b) branch="$2"; shift 2 ;;
                -*) echo "!!! clone_with_retry: 未知参数 $1" >&2; return 2 ;;
                *)  if [ -z "$url" ]; then url="$1"; else dest="$1"; fi; shift ;;
            esac
        done
        [ -n "$url" ] || { echo "!!! clone_with_retry: 缺少 url" >&2; return 2; }
        [ -n "$dest" ] || dest="${url##*/}"
        local name; name="${dest##*/}"

        for i in 1 2 3 4 5; do
            echo "clone $name (第 $i 次)..."
            if [ -n "$branch" ]; then
                git clone --depth 1 -b "$branch" "$url" "$dest" && return 0
            else
                git clone --depth 1 "$url" "$dest" && return 0
            fi
            # 必须紧挨着取：$? 是 git 的退出码，不能放到 if 后面
            rc=$?
            echo "  ↳ 失败(rc=$rc)，清理后重试..."
            rm -rf -- "$dest"          # -- 防止 dest 以 '-' 开头被当成参数
            sleep $((RANDOM % 5 + 3))  # 随机 3-7 秒，错开并发限流
        done
        echo "!!! $name 克隆失败(rc=$rc): $url" >&2
        return 1
    }

    # ------------------------------------------------------------------
    # PKG_VERSION 规范化：把 git describe 带出来的脏串压成纯数字
    #   文件不存在就跳过，不让 sed -i 直接报错
    # ------------------------------------------------------------------
    sed_version() {
        local f="$1"
        if [ -f "$f" ]; then
            sed -i '/^[[:blank:]]*PKG_VERSION:=/ s/\(PKG_VERSION:=[[:blank:]]*\)[^0-9.]*\([0-9.]*\)[^0-9.]*/\1\2/' "$f"
        else
            echo "⚠️ 跳过 PKG_VERSION 处理，文件不存在: $f"
        fi
    }

    rm -rf -- "${path}"
    mkdir -p "${path}"

    # ---------- 主题 ----------
    clone_with_retry https://github.com/seaks/luci-theme-argon.git "${path}luci-theme-argon" || return 1
    clone_with_retry https://github.com/anothaDev/luci-theme-vantage.git "${path}luci-theme-vantage" || return 1

    # 该主题 Makefile 使用相对路径 ../../luci.mk, 在 package/custom_packages 下无法找到, 改为 feeds 中的路径
    # sed -i 's#^include[[:blank:]]\+\.\./\.\./luci\.mk#include $(TOPDIR)/feeds/luci/luci.mk#' "${path}luci-theme-ctmodem/luci-theme-ctmodem/Makefile"

    # ---------- 应用 ----------
    clone_with_retry https://github.com/sbwml/luci-app-mosdns -b v5 "${path}mosdns" || return 1
    clone_with_retry https://github.com/sirpdboy/netspeedtest.git "${path}netspeedtest" || return 1
    clone_with_retry https://github.com/timsaya/openwrt-bandix.git "${path}openwrt-bandix" || return 1
    clone_with_retry https://github.com/timsaya/luci-app-bandix.git "${path}luci-app-bandix" || return 1

    # argon 是 seaks 的 fork，版本号可能带 commit 串，规范化成纯数字
    sed_version "${path}luci-theme-argon/Makefile"

    #-------------------------------------------取消默认主题自动设置------------------------------------------
    # 注意：target 里的 '.' 必须转义，否则 sed 会把它当正则的任意字符
    local target='luci\.main\.mediaurlbase='

    echo "开始全量扫描并注释目标字符串, 取消主题自动设置为默认主题..."
    # -print0 + read -d '' : 兼容路径中含空格/换行的情况
    find "$path" -type f \( -name "Makefile" -o -path "*/etc/uci-defaults/*" \) -print0 |
    while IFS= read -r -d '' file; do
        # Makefile 里该行行首可能是 Tab 或空格，用 [[:blank:]]* 兼容
        if grep -q "$target" "$file"; then
            echo "命中目标: $file"
            sed -i "/$target/s/^\([[:blank:]]*\)\([^#[:blank:]]\)/\1# \2/" "$file"
        fi
    done

    echo "注释处理完成。"
    #-------------------------------------------end取消默认主题自动设置------------------------------------------

    #-------------------------------------------设置默认主题------------------------------------------
    # 1. 确保构建根目录下的自定义文件路径存在
    mkdir -p files/etc/uci-defaults
    # 2. 将主题设置脚本写入到 zz-set-default-theme 文件中
    #    文本全部顶格写，防止 #!/bin/sh 前面产生空格
cat << "EOF" > files/etc/uci-defaults/zz-set-default-theme
#!/bin/sh

# 强制覆写节点，不判断任何条件，设置默认主题

# 设置默认主题为 Argon
 uci set luci.themes.Argon=/luci-static/argon
 uci set luci.main.mediaurlbase=/luci-static/argon
 uci commit luci

# 设置默认主题为 vantage
# uci set luci.themes.Vantage=/luci-static/vantage
# uci set luci.main.mediaurlbase=/luci-static/vantage
# uci commit luci

exit 0
EOF

    # 3. 赋予可执行权限（否则不会在开机执行）
    chmod +x files/etc/uci-defaults/zz-set-default-theme

    echo "默认主题设置已生成！"
    #-------------------------------------------end设置默认主题------------------------------------------
}
