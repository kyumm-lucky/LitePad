APP_NAME := LitePad

.PHONY: run app icon dmg clean

run:
	swift run

app:
	./scripts/make-app.sh

icon:
	swift scripts/make-icon.swift

dmg: app
	./scripts/make-dmg.sh

clean:
	rm -rf .build build
