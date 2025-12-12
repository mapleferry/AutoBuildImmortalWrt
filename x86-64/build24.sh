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
# 检查第三方插件是否有对应的 .ipk 文件，如果没有则跳过
echo "🔍 检查插件兼容性..."

if [ -d "/home/build/immortalwrt/packages" ] && [ -n "$CUSTOM_PACKAGES" ]; then
    VALID_PACKAGES=""
    for pkg in $PACKAGES; do
        [ -z "$pkg" ] || [[ "$pkg" == -* ]] && continue
        
        # 检查第三方插件是否有对应的 .ipk 文件
        if echo "$CUSTOM_PACKAGES" | grep -qw "$pkg"; then
            if find /home/build/immortalwrt/packages -name "${pkg}_*.ipk" -o -name "${pkg}.ipk" 2>/dev/null | grep -q .; then
                VALID_PACKAGES="$VALID_PACKAGES $pkg"
            else
                echo "⚠️ $pkg - 未找到 .ipk 文件，跳过"
            fi
        else
            # 基础包直接添加
            VALID_PACKAGES="$VALID_PACKAGES $pkg"
        fi
    done
    PACKAGES=$(echo "$VALID_PACKAGES" | tr -s ' ')
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

# 如果编译失败，检查是否是插件兼容性问题
if [ $BUILD_EXIT_CODE -ne 0 ]; then
    echo "❌ 编译失败，检查错误原因..."
    
    # 检测常见的插件错误
    if grep -q "chmod: cannot access '/etc/init.d/" /tmp/build.log; then
        echo "⚠️ 检测到 init 脚本错误，相关插件可能需要修复"
    fi
    if grep -q "uci: command not found\|syntax error" /tmp/build.log; then
        echo "⚠️ 检测到脚本错误，可能是插件兼容性问题"
    fi
    
    echo "$(date '+%Y-%m-%d %H:%M:%S') - Error: Build failed!"
    exit 1
fi

echo "$(date '+%Y-%m-%d %H:%M:%S') - Build completed successfully."
