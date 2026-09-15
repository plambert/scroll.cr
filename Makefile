# Demo recordings. `make demo` re-records every scene; `make demo-progress`
# re-records one. Rendering needs vhs (which needs ttyd and ffmpeg); optimizing
# needs gifsicle. Both come from `brew install vhs gifsicle`.

REPO    := $(CURDIR)
DEMO    := $(REPO)/demo
WORK    := $(DEMO)/work
OUT     := $(DEMO)/out
STATIC  := $(DEMO)/static
TAPES   := $(wildcard $(DEMO)/*.tape)
SCENES  := $(filter-out prelude calibrate,$(basename $(notdir $(TAPES))))
GIFS    := $(addprefix $(STATIC)/,$(addsuffix .gif,$(SCENES)))

# The tapes type bare `scroll`, `fake-build`, `writer` and run from the fixture
# directory, so the built binary and the generators go on PATH.
DEMO_PATH := $(REPO)/bin:$(DEMO)/lib:$(PATH)

.PHONY: demo demo-fixtures demo-calibrate demo-clean $(addprefix demo-,$(SCENES))

demo: $(GIFS)

demo-fixtures:
	bash $(DEMO)/lib/setup.sh

demo-calibrate: | $(OUT)
	@test -d $(WORK) || $(MAKE) demo-fixtures
	cd $(WORK) && PATH="$(DEMO_PATH)" vhs $(DEMO)/calibrate.tape > /dev/null
	@printf 'grid (rows cols): %s  — wanted: 30 100\n' "$$(cat $(OUT)/grid.txt)"

$(OUT) $(STATIC):
	mkdir -p $@

# Each scene: capture frames with vhs, encode them here, then optimize into
# static/, which is committed. VHS 0.12 cannot drive ffmpeg 9 (its own encode
# step fails silently), so it only captures and the encode is done below.
BG  := 0x1e1e2e
# Encode at the rate the frames were captured at, or the GIF plays at the wrong
# speed. Read from the prelude so the two cannot drift apart.
FPS := $(shell awk '/^Set Framerate/ { print $$3 }' $(DEMO)/prelude.tape)

$(STATIC)/%.gif: $(DEMO)/%.tape $(DEMO)/prelude.tape | $(OUT) $(STATIC)
	@test -d $(WORK) || $(MAKE) demo-fixtures
	@rm -rf $(WORK)/.frames
	@sleep 2 # let the previous ttyd release its port; vhs fails silently on a clash
	cd $(WORK) && PATH="$(DEMO_PATH)" vhs $< > /dev/null
	@test -e $(WORK)/.frames/frame-text-00001.png || \
	  { echo "$*: vhs captured no frames (re-run make)" >&2; exit 1; }
	ffmpeg -y -loglevel error \
	  -framerate $(FPS) -i $(WORK)/.frames/frame-text-%05d.png \
	  -framerate $(FPS) -i $(WORK)/.frames/frame-cursor-%05d.png \
	  -filter_complex "[0][1]overlay=format=auto,pad=iw+40:ih+40:20:20:color=$(BG),split[a][b];[a]palettegen=max_colors=64[p];[b][p]paletteuse=dither=bayer:bayer_scale=3" \
	  -loop 0 $(OUT)/$*.gif
	@if command -v gifsicle > /dev/null; then \
	  gifsicle -O3 --lossy=80 $(OUT)/$*.gif -o $@; \
	else cp $(OUT)/$*.gif $@; fi
	@printf '%-12s %s -> %s\n' "$*" "$$(du -h $(OUT)/$*.gif | cut -f1)" "$$(du -h $@ | cut -f1)"

# Convenience: `make demo-progress` for one scene.
$(addprefix demo-,$(SCENES)): demo-%: $(STATIC)/%.gif

demo-clean:
	rm -rf $(OUT) $(WORK)
