APP_NAME := LitePad

.PHONY: run app dmg clean

run:
	swift run

app:
	./scripts/make-app.sh

dmg: app
	./scripts/make-dmg.sh

clean:
	rm -rf .build build
