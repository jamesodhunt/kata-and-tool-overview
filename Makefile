IN_FILE = agent-ctl.md
OUT_FILE = /tmp/agent-ctl.html

OUT_FMT = slidy

default: view

build:
	pandoc \
		--standalone \
		--metadata title="Kata Containers and tool overview" \
		--metadata author="James O. D. Hunt" \
		--metadata date="Presented 10 March 2023" \
		-f markdown \
		-t "$(OUT_FMT)" \
		-i \
		-o "$(OUT_FILE)" "$(IN_FILE)"

view: build
	xdg-open "file://$(OUT_FILE)"
