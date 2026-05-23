#!/usr/bin/env bash
set -euo pipefail

#──────────────────────────────────────────────
# Pentia IPA Build Script
#──────────────────────────────────────────────

SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
PROJECT_ROOT="$(cd "$SCRIPT_DIR/.." && pwd)"

# ── 默认配置 ──
PROJECT_NAME="Pentia"
SCHEME="Pentia"
BUNDLE_ID="com.iclaw.app"
CONFIGURATION="Release"
SDK="iphoneos"
EXPORT_METHOD="development"       # development | ad-hoc | enterprise | app-store | unsigned
TEAM_ID=""
PROVISIONING_PROFILE=""
CODE_SIGN_IDENTITY=""
CLEAN_BUILD=false
SKIP_XCODEGEN=false
NO_SIGN=false
ARCHIVE_PATH=""
OUTPUT_DIR=""

# ── 颜色输出 ──
RED='\033[0;31m'
GREEN='\033[0;32m'
YELLOW='\033[1;33m'
CYAN='\033[0;36m'
NC='\033[0m'

log_info()  { echo -e "${CYAN}[INFO]${NC}  $*"; }
log_ok()    { echo -e "${GREEN}[OK]${NC}    $*"; }
log_warn()  { echo -e "${YELLOW}[WARN]${NC}  $*"; }
log_error() { echo -e "${RED}[ERROR]${NC} $*"; }

print_usage() {
    cat <<EOF
用法: $(basename "$0") [选项]

选项:
  -c, --configuration <Debug|Release>   构建配置 (默认: Release)
  -m, --method <method>                 导出方式: development, ad-hoc, enterprise, app-store
                                        (默认: development)
  -t, --team-id <TEAM_ID>              开发者团队 ID
  -p, --profile <name>                 Provisioning Profile 名称
  -i, --identity <identity>            代码签名身份 (如: "Apple Distribution: ...")
  -o, --output <dir>                   IPA 输出目录 (默认: build/ipa)
  -s, --skip-xcodegen                  跳过 xcodegen 项目生成
      --no-sign                        无签名模式 (不需要开发者账号)
      --clean                          清理后重新构建
  -h, --help                           显示帮助信息

示例:
  # 无签名 IPA (无需开发者账号)
  $(basename "$0") --no-sign

  # 开发版本 (自动签名)
  $(basename "$0")

  # Ad-Hoc 分发
  $(basename "$0") -m ad-hoc -t YOUR_TEAM_ID

  # App Store 上传
  $(basename "$0") -m app-store -t YOUR_TEAM_ID --clean

EOF
}

# ── 解析参数 ──
while [[ $# -gt 0 ]]; do
    case "$1" in
        -c|--configuration)  CONFIGURATION="$2"; shift 2 ;;
        -m|--method)         EXPORT_METHOD="$2"; shift 2 ;;
        -t|--team-id)        TEAM_ID="$2"; shift 2 ;;
        -p|--profile)        PROVISIONING_PROFILE="$2"; shift 2 ;;
        -i|--identity)       CODE_SIGN_IDENTITY="$2"; shift 2 ;;
        -o|--output)         OUTPUT_DIR="$2"; shift 2 ;;
        -s|--skip-xcodegen)  SKIP_XCODEGEN=true; shift ;;
        --no-sign)           NO_SIGN=true; shift ;;
        --clean)             CLEAN_BUILD=true; shift ;;
        -h|--help)           print_usage; exit 0 ;;
        *)                   log_error "未知选项: $1"; print_usage; exit 1 ;;
    esac
done

# ── 路径设置 ──
BUILD_DIR="$PROJECT_ROOT/build"
ARCHIVE_PATH="${ARCHIVE_PATH:-$BUILD_DIR/archive/${PROJECT_NAME}.xcarchive}"
OUTPUT_DIR="${OUTPUT_DIR:-$BUILD_DIR/ipa}"
EXPORT_OPTIONS_PLIST="$BUILD_DIR/ExportOptions.plist"

# ── 环境检查 ──
check_environment() {
    log_info "检查构建环境..."

    if ! command -v xcodebuild &>/dev/null; then
        log_error "未找到 xcodebuild，请安装 Xcode 和 Command Line Tools"
        exit 1
    fi

    local xcode_version
    xcode_version=$(xcodebuild -version 2>&1) || true
    xcode_version=$(echo "$xcode_version" | head -1)
    log_info "Xcode 版本: $xcode_version"

    if [[ "$SKIP_XCODEGEN" == false ]] && ! command -v xcodegen &>/dev/null; then
        log_warn "未找到 xcodegen，尝试使用 Homebrew 安装..."
        if command -v brew &>/dev/null; then
            brew install xcodegen
        else
            log_error "未找到 xcodegen 且无法自动安装，请运行: brew install xcodegen"
            exit 1
        fi
    fi

    log_ok "环境检查通过"
}

# ── 生成 Xcode 项目 ──
generate_project() {
    if [[ "$SKIP_XCODEGEN" == true ]]; then
        log_info "跳过 xcodegen 项目生成"
        if [[ ! -d "$PROJECT_ROOT/$PROJECT_NAME.xcodeproj" ]]; then
            log_error "未找到 $PROJECT_NAME.xcodeproj，请先运行 xcodegen 或去掉 --skip-xcodegen"
            exit 1
        fi
        return
    fi

    log_info "使用 xcodegen 生成 Xcode 项目..."
    cd "$PROJECT_ROOT"
    xcodegen generate
    log_ok "项目生成完成"
}

# ── 解析 SPM 依赖 ──
resolve_dependencies() {
    log_info "解析 Swift Package Manager 依赖..."
    local resolve_output
    resolve_output=$(xcodebuild -resolvePackageDependencies \
        -project "$PROJECT_ROOT/$PROJECT_NAME.xcodeproj" \
        -scheme "$SCHEME" \
        -clonedSourcePackagesDirPath "$BUILD_DIR/SourcePackages" \
        2>&1) || {
        log_error "依赖解析失败:"
        echo "$resolve_output" | tail -10
        exit 1
    }
    echo "$resolve_output" | tail -5
    log_ok "依赖解析完成"
}

# ── 清理构建 ──
clean_build() {
    if [[ "$CLEAN_BUILD" == true ]]; then
        log_info "清理构建目录..."
        local clean_output
        clean_output=$(xcodebuild clean \
            -project "$PROJECT_ROOT/$PROJECT_NAME.xcodeproj" \
            -scheme "$SCHEME" \
            -configuration "$CONFIGURATION" \
            2>&1) || true
        echo "$clean_output" | tail -3
        rm -rf "$BUILD_DIR"
        log_ok "清理完成"
    fi
}

# ── 生成 ExportOptions.plist (签名模式) ──
generate_export_options() {
    if [[ "$NO_SIGN" == true ]]; then
        log_info "无签名模式，跳过 ExportOptions 生成"
        return
    fi

    log_info "生成导出配置 (method=$EXPORT_METHOD)..."

    mkdir -p "$(dirname "$EXPORT_OPTIONS_PLIST")"

    local signing_style="automatic"
    local plist_content=""

    if [[ -n "$PROVISIONING_PROFILE" ]]; then
        signing_style="manual"
    fi

    plist_content="<?xml version=\"1.0\" encoding=\"UTF-8\"?>
<!DOCTYPE plist PUBLIC \"-//Apple//DTD PLIST 1.0//EN\" \"http://www.apple.com/DTDs/PropertyList-1.0.dtd\">
<plist version=\"1.0\">
<dict>
    <key>method</key>
    <string>${EXPORT_METHOD}</string>
    <key>signingStyle</key>
    <string>${signing_style}</string>
    <key>stripSwiftSymbols</key>
    <true/>
    <key>compileBitcode</key>
    <false/>"

    if [[ -n "$TEAM_ID" ]]; then
        plist_content+="
    <key>teamID</key>
    <string>${TEAM_ID}</string>"
    fi

    if [[ "$EXPORT_METHOD" == "app-store" ]]; then
        plist_content+="
    <key>uploadSymbols</key>
    <true/>
    <key>destination</key>
    <string>export</string>"
    fi

    if [[ "$signing_style" == "manual" ]]; then
        plist_content+="
    <key>signingCertificate</key>
    <string>${CODE_SIGN_IDENTITY}</string>
    <key>provisioningProfiles</key>
    <dict>
        <key>${BUNDLE_ID}</key>
        <string>${PROVISIONING_PROFILE}</string>
    </dict>"
    fi

    plist_content+="
</dict>
</plist>"

    echo "$plist_content" > "$EXPORT_OPTIONS_PLIST"
    log_ok "导出配置已生成: $EXPORT_OPTIONS_PLIST"
}

# ── Archive ──
archive_project() {
    log_info "归档项目 ($CONFIGURATION)..."
    mkdir -p "$(dirname "$ARCHIVE_PATH")"

    local archive_args=(
        -project "$PROJECT_ROOT/$PROJECT_NAME.xcodeproj"
        -scheme "$SCHEME"
        -configuration "$CONFIGURATION"
        -sdk "$SDK"
        -archivePath "$ARCHIVE_PATH"
        -clonedSourcePackagesDirPath "$BUILD_DIR/SourcePackages"
        -destination "generic/platform=iOS"
        archive
    )

    if [[ "$NO_SIGN" == true ]]; then
        log_info "无签名模式: 跳过代码签名"
        archive_args+=(
            CODE_SIGN_IDENTITY="-"
            CODE_SIGNING_REQUIRED=NO
            CODE_SIGNING_ALLOWED=NO
            CODE_SIGN_ENTITLEMENTS=""
            DEVELOPMENT_TEAM=""
        )
    else
        if [[ -n "$TEAM_ID" ]]; then
            archive_args+=(DEVELOPMENT_TEAM="$TEAM_ID")
        fi

        if [[ -n "$CODE_SIGN_IDENTITY" ]]; then
            archive_args+=(CODE_SIGN_IDENTITY="$CODE_SIGN_IDENTITY")
        fi

        if [[ -n "$PROVISIONING_PROFILE" ]]; then
            archive_args+=(
                CODE_SIGN_STYLE="Manual"
                PROVISIONING_PROFILE_SPECIFIER="$PROVISIONING_PROFILE"
            )
        fi
    fi

    local archive_output archive_rc=0
    archive_output=$(xcodebuild "${archive_args[@]}" 2>&1) || archive_rc=$?

    # Display filtered output
    echo "$archive_output" | while IFS= read -r line; do
        if [[ "$line" == *"ARCHIVE SUCCEEDED"* ]]; then
            echo -e "${GREEN}$line${NC}"
        elif [[ "$line" == *"error:"* ]]; then
            echo -e "${RED}$line${NC}"
        elif [[ "$line" == *"warning:"* ]]; then
            echo -e "${YELLOW}$line${NC}"
        fi
    done || true

    if [[ $archive_rc -ne 0 ]] || [[ ! -d "$ARCHIVE_PATH" ]]; then
        log_error "归档失败 (exit code: $archive_rc)"
        echo "$archive_output" | grep -i "error:" | tail -5 || true
        exit 1
    fi

    log_ok "归档完成: $ARCHIVE_PATH"
}

# ── 导出 IPA (无签名: 手动打包; 签名: xcodebuild exportArchive) ──
export_ipa() {
    log_info "导出 IPA..."
    mkdir -p "$OUTPUT_DIR"

    if [[ "$NO_SIGN" == true ]]; then
        export_ipa_unsigned
    else
        export_ipa_signed
    fi
}

export_ipa_unsigned() {
    log_info "无签名模式: 从 xcarchive 手动打包 IPA..."

    local app_path
    app_path=$(find "$ARCHIVE_PATH/Products/Applications" -name "*.app" -maxdepth 1 2>/dev/null | head -1) || true

    if [[ -z "$app_path" ]]; then
        log_error "未在 xcarchive 中找到 .app"
        exit 1
    fi

    local payload_dir="$BUILD_DIR/Payload"
    rm -rf "$payload_dir"
    mkdir -p "$payload_dir"
    cp -R "$app_path" "$payload_dir/"

    local ipa_file="$OUTPUT_DIR/${PROJECT_NAME}_unsigned.ipa"
    cd "$BUILD_DIR"
    /usr/bin/ditto -c -k --sequesterRsrc --keepParent "Payload" "$ipa_file"
    rm -rf "$payload_dir"

    print_result "$ipa_file" "unsigned"
}

export_ipa_signed() {
    local export_output export_rc=0
    export_output=$(xcodebuild -exportArchive \
        -archivePath "$ARCHIVE_PATH" \
        -exportPath "$OUTPUT_DIR" \
        -exportOptionsPlist "$EXPORT_OPTIONS_PLIST" \
        -allowProvisioningUpdates \
        2>&1) || export_rc=$?

    echo "$export_output" | while IFS= read -r line; do
        if [[ "$line" == *"EXPORT SUCCEEDED"* ]]; then
            echo -e "${GREEN}$line${NC}"
        elif [[ "$line" == *"error:"* ]]; then
            echo -e "${RED}$line${NC}"
        fi
    done || true

    local ipa_file
    ipa_file=$(find "$OUTPUT_DIR" -name "*.ipa" -maxdepth 1 2>/dev/null | head -1) || true

    if [[ -z "$ipa_file" ]]; then
        log_error "导出失败 (exit code: $export_rc)"
        echo "$export_output" | grep -i "error:" | tail -5 || true
        exit 1
    fi

    print_result "$ipa_file" "$EXPORT_METHOD"
}

print_result() {
    local ipa_file="$1"
    local method="$2"
    local ipa_size
    ipa_size=$(du -h "$ipa_file" | cut -f1) || true

    echo ""
    log_ok "════════════════════════════════════════"
    log_ok "IPA 构建成功!"
    log_ok "────────────────────────────────────────"
    log_ok "文件: $ipa_file"
    log_ok "大小: $ipa_size"
    log_ok "配置: $CONFIGURATION"
    log_ok "方式: $method"
    if [[ "$method" == "unsigned" ]]; then
        log_warn "注意: 此 IPA 未签名，无法直接安装到设备"
        log_warn "可使用 AltStore / Sideloadly / TrollStore 等工具重签后安装"
    fi
    log_ok "════════════════════════════════════════"
}

# ── 主流程 ──
main() {
    echo ""
    echo -e "${CYAN}╔══════════════════════════════════════╗${NC}"
    echo -e "${CYAN}║       Pentia IPA Build Script         ║${NC}"
    echo -e "${CYAN}╚══════════════════════════════════════╝${NC}"
    echo ""

    local start_time
    start_time=$(date +%s)

    check_environment
    generate_project
    resolve_dependencies
    clean_build
    generate_export_options
    archive_project
    export_ipa

    local end_time elapsed
    end_time=$(date +%s)
    elapsed=$((end_time - start_time))
    log_info "总耗时: $((elapsed / 60))分$((elapsed % 60))秒"
}

main "$@"
