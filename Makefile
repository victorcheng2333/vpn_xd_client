APP = build/XD VPN.app

.PHONY: app run install clean icon

app:
	./build.sh

run: app
	open "$(APP)"

install: app
	@pkill -x XDVPN 2>/dev/null || true
	rm -rf "/Applications/XD VPN.app"
	cp -R "$(APP)" /Applications/
	@echo "installed to /Applications/XD VPN.app"

icon:
	swift Support/make-icon.swift Support/AppIcon.icns

clean:
	rm -rf build .build Support/AppIcon.icns
