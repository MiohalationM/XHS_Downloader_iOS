#!/bin/bash
set -euo pipefail

cd "$(dirname "$0")/.."

usage() {
    cat <<'EOF'
用法：
  ./scripts/ios-dev.sh run                         编译、安装并启动 Debug 应用
  ./scripts/ios-dev.sh test [测试类[/方法] ...]      定向单元测试，默认媒体识别 3 项
  ./scripts/ios-dev.sh test all                    显式运行全部单元测试
  ./scripts/ios-dev.sh ui 测试类[/方法] [...]        显式运行指定 UI 测试

默认复用名为 “XHS Dev iPhone 17” 的设备；可用 XHS_SIMULATOR_UDID 指定其他设备。
构建和测试结果保存在 .build/ios-dev，不自动重试、清数据或关闭模拟器。
EOF
}

action="${1:-help}"
case "$action" in
    run|test|ui) shift ;;
    help|-h|--help) usage; exit 0 ;;
    *) usage; exit 2 ;;
esac
if [[ "$action" == ui && $# -eq 0 ]]; then
    usage
    exit 2
fi

device="${XHS_SIMULATOR_UDID:-}"
if [[ -z "$device" ]]; then
    device="$(xcrun simctl list devices available -j | python3 -c '
import json, sys
devices = [d for group in json.load(sys.stdin)["devices"].values() for d in group]
print(next((d["udid"] for d in devices if d["name"] == "XHS Dev iPhone 17"), ""))
')"
fi
if [[ -z "$device" ]]; then
    echo '未找到专用设备。请在 Device Hub 创建 XHS Dev iPhone 17，或设置 XHS_SIMULATOR_UDID。' >&2
    exit 1
fi

output="$PWD/.build/ios-dev"
mkdir -p "$output"
python3 - "$device" <<'PY' | tee "$output/boot.log"
import subprocess, sys
try:
    subprocess.run(["xcrun", "simctl", "bootstatus", sys.argv[1], "-b"],
                   timeout=180, check=True)
except subprocess.TimeoutExpired:
    print("模拟器在 180 秒内未完成启动，已停止等待；不自动重试。", flush=True)
    sys.exit(1)
except subprocess.CalledProcessError as error:
    sys.exit(error.returncode)
PY
if rg -q 'Data Migration Failed' "$output/boot.log"; then
    echo '模拟器数据迁移失败，已停止；不自动重启或清除数据。' >&2
    exit 1
fi

scheme=XHS_Downloader_iOS
target=XHS_Downloader_iOSTests
if [[ "$action" == ui ]]; then
    scheme=XHS_Downloader_iOS-UI
    target=XHS_Downloader_iOSUITests
    if [[ -n "${XHS_UI_TEST_MEDIA_IDS:-}" ]]; then
        export TEST_RUNNER_XHS_UI_TEST_MEDIA_IDS="$XHS_UI_TEST_MEDIA_IDS"
    fi
fi
common=(-project XHS_Downloader_iOS.xcodeproj -scheme "$scheme"
    -configuration Debug -destination "platform=iOS Simulator,id=$device"
    -destination-timeout 90 -jobs 2 -derivedDataPath "$output/DerivedData")

if [[ "$action" == run ]]; then
    xcodebuild "${common[@]}" build > "$output/build.log" 2>&1 || {
        tail -60 "$output/build.log"; exit 1;
    }
    xcrun simctl install "$device" "$output/DerivedData/Build/Products/Debug-iphonesimulator/小红书下载器.app"
    xcrun simctl launch --terminate-running-process "$device" com.neoruaa.xhsdn
    exit 0
fi

filters=("-only-testing:$target")
if [[ $# -eq 0 ]]; then set -- MediaKindDetectionTests; fi
if [[ "$action" != test || "$1" != all ]]; then
    filters=()
    for test_id in "$@"; do filters+=("-only-testing:$target/$test_id"); done
fi
result="$output/Test-$(date '+%Y%m%d-%H%M%S').xcresult"
echo "设备：${device}；结果：${result}"
xcodebuild "${common[@]}" test \
    -parallel-testing-enabled NO \
    -maximum-concurrent-test-simulator-destinations 1 \
    -maximum-parallel-testing-workers 1 \
    -collect-test-diagnostics never \
    -test-timeouts-enabled YES \
    -default-test-execution-time-allowance 60 \
    -maximum-test-execution-time-allowance 120 \
    -resultBundlePath "$result" "${filters[@]}" \
    > "$result.log" 2>&1 || {
        tail -80 "$result.log"; exit 1;
    }
tail -25 "$result.log"
