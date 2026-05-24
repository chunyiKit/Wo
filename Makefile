# Wo Flutter app — 常用命令。后端的命令在 backend/Makefile。
DEVICE ?= a8af747a

.PHONY: apk install-app analyze run

# 编译 release APK（改完代码先跑这个）。产物：build/app/outputs/flutter-apk/app-release.apk
apk:
	flutter build apk --release

# 装到真机（小米需先在 开发者选项 打开「USB 安装」）。可覆盖设备：make install-app DEVICE=xxx
install-app:
	flutter install --release -d $(DEVICE)

# 编译 + 装机一条龙
ship: apk install-app

analyze:
	flutter analyze

run:
	flutter run -d $(DEVICE)
