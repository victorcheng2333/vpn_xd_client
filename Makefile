APP = build/XD VPN.app

.PHONY: app run install clean icon

app:
	./build.sh

run: app
	open "$(APP)"

install: app
	rm -rf "/Applications/XD VPN.app"
	cp -R "$(APP)" /Applications/
	@echo "installed to /Applications/XD VPN.app"
	@pgrep -x XDVPN >/dev/null && echo "(XD VPN is running: quit and reopen it to pick up the new build)" || true

icon:
	swift Support/make-icon.swift Support/AppIcon.icns

clean:
	rm -rf build .build Support/AppIcon.icns
