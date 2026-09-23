.PHONY: test open

test:
	swift test

open:
	bash scripts/bundle.sh
	open Usage.app
