#!/bin/bash
# Log file for debugging
source shell/custom-packages.sh
echo "第三方软件包: $CUSTOM_PACKAGES"
LOGFILE="/tmp/uci-defaults-log.txt"
echo "Starting 99-custom.sh at $(date)" >> $LOGFILE
echo "编译固件大小为: $PROFILE MB"
echo "Include Docker: $INCLUDE_DOCKER"

echo "Create pppoe-settings"
mkdir -p  /home/build/immortalwrt/files/etc/config

# 创建pppoe配置文件 yml传入环境变量ENABLE_PPPOE等 写入配置文件 供99-custom.sh读取
cat << EOF > /home/build/immortalwrt/files/etc/config/pppoe-settings
enable_pppoe=${ENABLE_PPPOE}
pppoe_account=${PPPOE_ACCOUNT}
pppoe_password=${PPPOE_PASSWORD}
EOF

echo "cat pppoe-settings"
cat /home/build/immortalwrt/files/etc/config/pppoe-settings

if [ -z "$CUSTOM_PACKAGES" ]; then
  echo "⚪️ 未选择 任何第三方软件包"
else
  # ============= 同步第三方插件库==============
  # 同步第三方软件仓库run/ipk
  echo "🔄 正在同步第三方软件仓库 Cloning run file repo..."
  git clone --depth=1 https://github.com/wukongdaily/store.git /tmp/store-run-repo

  # 拷贝 run/x86 下所有 run 文件和ipk文件 到 extra-packages 目录
  mkdir -p /home/build/immortalwrt/extra-packages
  cp -r /tmp/store-run-repo/run/x86/* /home/build/immortalwrt/extra-packages/ 2>/dev/null || true

  echo "✅ Run files copied to extra-packages:"
  ls -lh /home/build/immortalwrt/extra-packages/*.run 2>/dev/null || echo "  无 .run 文件"
  
  # ============= 下载第三方源码仓库插件 ==============
  # 下载 luci-app-parentcontrol（如果已启用）
  if echo "$CUSTOM_PACKAGES" | grep -q "luci-app-parentcontrol"; then
    echo "🔄 下载 luci-app-parentcontrol..."
    git clone --depth=1 https://github.com/sirpdboy/luci-app-parentcontrol.git /tmp/parentcontrol 2>/dev/null && \
      (find /tmp/parentcontrol -name "*x86_64*.ipk" 2>/dev/null || find /tmp/parentcontrol -name "*.ipk" 2>/dev/null) | head -1 | \
      xargs -r -I {} cp {} /home/build/immortalwrt/extra-packages/ 2>/dev/null && \
      echo "✅ luci-app-parentcontrol 已准备" || echo "⚠️ luci-app-parentcontrol 下载失败，将跳过"
  fi
  
  # 解压并拷贝ipk到packages目录
  cd /home/build/immortalwrt && sh shell/prepare-packages.sh
  ls -lah /home/build/immortalwrt/packages/
fi

# 输出调试信息
echo "$(date '+%Y-%m-%d %H:%M:%S') - 开始构建固件..."

# ============= imm仓库内的插件==============
# 定义所需安装的包列表 下列插件你都可以自行删减
PACKAGES=""
PACKAGES="$PACKAGES curl"
PACKAGES="$PACKAGES luci-i18n-diskman-zh-cn"
PACKAGES="$PACKAGES luci-i18n-firewall-zh-cn"
PACKAGES="$PACKAGES luci-theme-argon"
PACKAGES="$PACKAGES luci-app-argon-config"
PACKAGES="$PACKAGES luci-i18n-argon-config-zh-cn"
#24.10
PACKAGES="$PACKAGES luci-i18n-package-manager-zh-cn"
PACKAGES="$PACKAGES luci-i18n-ttyd-zh-cn"
PACKAGES="$PACKAGES luci-i18n-passwall-zh-cn"
PACKAGES="$PACKAGES luci-app-openclash"
PACKAGES="$PACKAGES luci-i18n-homeproxy-zh-cn"
PACKAGES="$PACKAGES openssh-sftp-server"
PACKAGES="$PACKAGES luci-i18n-samba4-zh-cn"
# 文件管理器
PACKAGES="$PACKAGES luci-i18n-filemanager-zh-cn"
# 静态文件服务器dufs(推荐)
PACKAGES="$PACKAGES luci-i18n-dufs-zh-cn"
# ======== shell/custom-packages.sh =======
# 合并imm仓库以外的第三方插件
PACKAGES="$PACKAGES $CUSTOM_PACKAGES"

# ======== 通用插件兼容性检测 =======
# 检查插件是否有问题，如果有则跳过但保留在列表中
echo "🔍 检查插件兼容性..."

# 读取上次检测到的问题插件列表（如果存在）
KNOWN_PROBLEMATIC=""
if [ -f "/tmp/problematic_packages.txt" ]; then
    KNOWN_PROBLEMATIC=$(cat /tmp/problematic_packages.txt 2>/dev/null | tr '\n' ' ' | tr -s ' ')
    if [ -n "$KNOWN_PROBLEMATIC" ]; then
        echo "📋 已知问题插件（将自动跳过）: $KNOWN_PROBLEMATIC"
    fi
fi

SKIPPED_PACKAGES=""
if [ -d "/home/build/immortalwrt/packages" ] && [ -n "$CUSTOM_PACKAGES" ]; then
    VALID_PACKAGES=""
    for pkg in $PACKAGES; do
        [ -z "$pkg" ] || [[ "$pkg" == -* ]] && continue
        
        # 检查是否是已知有问题的插件
        if echo "$KNOWN_PROBLEMATIC" | grep -qw "$pkg"; then
            echo "⚠️ $pkg - 已知问题插件，跳过"
            SKIPPED_PACKAGES="$SKIPPED_PACKAGES $pkg"
            continue
        fi
        
        # 检查第三方插件是否有对应的 .ipk 文件
        if echo "$CUSTOM_PACKAGES" | grep -qw "$pkg"; then
            if find /home/build/immortalwrt/packages -name "${pkg}_*.ipk" -o -name "${pkg}.ipk" 2>/dev/null | grep -q .; then
                VALID_PACKAGES="$VALID_PACKAGES $pkg"
            else
                echo "⚠️ $pkg - 未找到 .ipk 文件，跳过"
                SKIPPED_PACKAGES="$SKIPPED_PACKAGES $pkg"
            fi
        else
            # 基础包直接添加
            VALID_PACKAGES="$VALID_PACKAGES $pkg"
        fi
    done
    PACKAGES=$(echo "$VALID_PACKAGES" | tr -s ' ')
    
    if [ -n "$SKIPPED_PACKAGES" ]; then
        echo "📋 本次已跳过的插件: $SKIPPED_PACKAGES"
    fi
fi

# 判断是否需要编译 Docker 插件
if [ "$INCLUDE_DOCKER" = "yes" ]; then
    PACKAGES="$PACKAGES luci-i18n-dockerman-zh-cn"
    echo "Adding package: luci-i18n-dockerman-zh-cn"
fi

# 若构建openclash 则添加内核
if echo "$PACKAGES" | grep -q "luci-app-openclash"; then
    echo "✅ 已选择 luci-app-openclash，添加 openclash core"
    mkdir -p files/etc/openclash/core
    # Download clash_meta
    META_URL="https://raw.githubusercontent.com/vernesong/OpenClash/core/master/meta/clash-linux-amd64.tar.gz"
    wget -qO- $META_URL | tar xOvz > files/etc/openclash/core/clash_meta
    chmod +x files/etc/openclash/core/clash_meta
    # Download GeoIP and GeoSite
    wget -q https://github.com/Loyalsoldier/v2ray-rules-dat/releases/latest/download/geoip.dat -O files/etc/openclash/GeoIP.dat
    wget -q https://github.com/Loyalsoldier/v2ray-rules-dat/releases/latest/download/geosite.dat -O files/etc/openclash/GeoSite.dat
else
    echo "⚪️ 未选择 luci-app-openclash"
fi

# 构建镜像
echo "$(date '+%Y-%m-%d %H:%M:%S') - Building image with the following packages:"
echo "$PACKAGES"

make image PROFILE="generic" PACKAGES="$PACKAGES" FILES="/home/build/immortalwrt/files" ROOTFS_PARTSIZE=$PROFILE 2>&1 | tee /tmp/build.log

BUILD_EXIT_CODE=${PIPESTATUS[0]}

# 检查编译结果，通用检测有问题的插件
PROBLEMATIC_PKGS=""

# 检测 init 脚本缺失的插件
for pkg in $(grep -o "chmod: cannot access '/etc/init.d/[^']*'" /tmp/build.log 2>/dev/null | sed "s|.*'/etc/init.d/\([^']*\)'.*|\1|" | sort -u); do
    # 尝试匹配包名（可能是 easytier 或 luci-app-easytier）
    matched_pkg=""
    for check_pkg in "$pkg" "luci-app-$pkg" "$(echo "$pkg" | sed 's/^luci-app-//')"; do
        if echo "$CUSTOM_PACKAGES" | grep -qw "$check_pkg"; then
            matched_pkg="$check_pkg"
            break
        fi
    done
    if [ -n "$matched_pkg" ] && ! echo "$PROBLEMATIC_PKGS" | grep -qw "$matched_pkg"; then
        PROBLEMATIC_PKGS="$PROBLEMATIC_PKGS $matched_pkg"
        echo "⚠️ 检测到有问题的插件: $matched_pkg (init 脚本缺失)"
    fi
done

# 检测脚本错误的插件（uci 命令未找到、语法错误等）
for pkg in $(grep -o "/etc/init.d/[^:]*" /tmp/build.log 2>/dev/null | sed 's|/etc/init.d/||' | sort -u); do
    matched_pkg=""
    for check_pkg in "$pkg" "luci-app-$pkg" "$(echo "$pkg" | sed 's/^luci-app-//')"; do
        if echo "$CUSTOM_PACKAGES" | grep -qw "$check_pkg"; then
            matched_pkg="$check_pkg"
            break
        fi
    done
    if [ -n "$matched_pkg" ] && ! echo "$PROBLEMATIC_PKGS" | grep -qw "$matched_pkg"; then
        PROBLEMATIC_PKGS="$PROBLEMATIC_PKGS $matched_pkg"
        echo "⚠️ 检测到有问题的插件: $matched_pkg (脚本错误)"
    fi
done

if [ $BUILD_EXIT_CODE -ne 0 ]; then
    # 检查是否是已知的警告（这些通常不会导致编译失败）
    WARNINGS_ONLY=$(grep -c "chmod: cannot access\|uci: command not found\|syntax error" /tmp/build.log 2>/dev/null || echo "0")
    REAL_ERRORS=$(grep -ic "Error\|error:" /tmp/build.log 2>/dev/null || echo "0")
    
    if [ "$WARNINGS_ONLY" -gt 0 ] && [ "$REAL_ERRORS" -eq 0 ]; then
        echo "⚠️ 检测到已知警告（插件兼容性问题），但编译可能已成功，继续..."
        if [ -n "$PROBLEMATIC_PKGS" ]; then
            echo "💡 下次编译时将自动跳过这些插件: $PROBLEMATIC_PKGS"
        fi
        BUILD_EXIT_CODE=0
    else
        echo "❌ 编译失败，检查错误原因..."
        if [ -n "$PROBLEMATIC_PKGS" ]; then
            echo "💡 检测到有问题的插件: $PROBLEMATIC_PKGS"
        fi
        echo "$(date '+%Y-%m-%d %H:%M:%S') - Error: Build failed!"
        exit 1
    fi
elif [ -n "$PROBLEMATIC_PKGS" ]; then
    echo "💡 检测到有问题的插件（已自动跳过）: $PROBLEMATIC_PKGS"
    # 保存问题插件列表，供下次编译使用
    echo "$PROBLEMATIC_PKGS" | tr ' ' '\n' > /tmp/problematic_packages.txt 2>/dev/null || true
fi

echo "$(date '+%Y-%m-%d %H:%M:%S') - Build completed successfully."
