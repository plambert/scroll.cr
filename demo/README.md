# Demo recordings

The GIFs in `static/` are recorded from the built binary by
[VHS](https://github.com/charmbracelet/vhs). Each scene is a `.tape` file; they
share `prelude.tape`, run against fixtures built by `lib/setup.sh`, and are
driven by the `demo` targets in the repository `Makefile`.

```sh
brew install vhs gifsicle   # vhs pulls ttyd; ffmpeg is used directly
make demo                   # re-record every scene
make demo-progress          # re-record one
make demo-fixtures          # rebuild the fixtures (160 MB, gitignored)
make demo-calibrate         # print the terminal grid the prelude produces
```

## Two things to know before changing a tape

VHS sizes the terminal in pixels and has no setting for rows and columns, so
`Set Width` and `Set Height` in `prelude.tape` are calibrated to a 100x30 grid
for the font, size, line height, and padding in use. Change any of those and run
`make demo-calibrate` until it reads `30 100`.

VHS 0.12 cannot drive ffmpeg 9: its own encode step fails and leaves no GIF and
no error. The tapes therefore capture frames only (`Output .frames/`), and the
`Makefile` composites them with ffmpeg and optimizes with gifsicle. The encode
framerate is read from `prelude.tape` so the two cannot drift apart — they did
once, and every GIF played at double speed.

## Fixtures

`lib/setup.sh` writes everything the tapes need into `work/`, which is
gitignored: a 6 MB log for the progress scene, a tree of varied sizes for the
sort scene, and a log with content already in it for the follow scene. The
generators (`lib/fake-build`, `lib/writer`) are seeded, so a re-record is the
same run.
