# scroll

Copy STDIN to STDOUT unchanged while showing the last N lines of the stream in a
live, in-place display on STDERR. It is a pipeline filter — like an interactive
`tail`, but the stream keeps flowing through to the next command.

```sh
long-running-build | scroll -20 | tee build.log
```

Two guarantees drive the design:

* **The STDOUT copy is never slowed by the display.** STDOUT is written on a tight
  path that hands buffers to a separate render fiber. When the terminal can't keep
  up, the display drops intermediate states; the STDOUT copy runs at full speed.
* **The display never shows non-contiguous output.** Each frame is a contiguous
  run of the most recent complete lines. When lines are skipped (because the
  display fell behind), the window resets to the newest contiguous segment rather
  than splicing a pre-gap line onto a post-gap one. Control and escape bytes are
  stripped from the display so a hostile stream cannot corrupt the terminal — the
  bytes on STDOUT are always untouched.

The display is only drawn when STDERR is a terminal; when STDERR is redirected,
`scroll` is a plain `cat` (use `--force` to draw anyway).

## Installation

Every version tag publishes binaries for Linux and macOS on the
[releases page](https://github.com/plambert/scroll.cr/releases). The Linux builds
are static; the macOS builds need nothing but the system libraries.

```sh
tar xzf scroll-1.1.1-darwin-aarch64.tar.gz
install scroll-1.1.1-darwin-aarch64/scroll /usr/local/bin/
```

`SHA256SUMS` on the release verifies the tarballs.

To build from source instead:

```sh
shards build --release
# copies to ./bin/scroll
```

## Usage

```text
Usage: scroll [options]

Options:
  --lines, -n COUNT               Lines to show (default: 10)
  --interval MS                   Minimum ms between redraws (default: 40)
  --force                         Draw the display even when STDERR is not a TTY
  --sanitize                      Strip control/escape bytes from the display (--no-sanitize to keep them)
  --final                         On EOF, also show a trailing line that has no newline
  --null                          Consume input without copying it to STDOUT (--no-null forces the copy)

Following a file:
  --file, -f PATH                 Follow PATH like `tail -F` instead of reading STDIN (implies --null)
  --from-start                    Stream the whole existing file before following
  --poll MS                       Ms between polls while waiting for data (default: 250)
  --pid PID                       Exit cleanly once process PID is gone
  --watch-proc                    Exit once no process holds the file open for writing (Linux only)
  --watch-proc-timeout SEC        Idle seconds before --watch-proc exits (default: 10)

Sorting:
  --sort, -s                      Show the top N of the whole stream, not the last N (STDOUT keeps input order)
  --reverse, -r                   Reverse the order (keep the smallest instead of the largest)
  --sort-by SPEC                  Sort key: a 1-based column number, or a /regex/ (implies --sort)
  --human                         Compare keys as human numbers, e.g. 1k < 2M (implies --sort)

Progress:
  --progress                      Show a progress line under the tail
  --size BYTES                    Expected input size, e.g. 500M (1024-based); implies --progress
  --size-lines COUNT              Expected input size in lines; implies --progress
  --file-size PATH                Take the expected input size from the size of PATH; implies --progress
  --name NAME                     Label to show in the progress line; implies --progress

Alternate screen:
  --alt-mode auto|region|full     Draw on the alternate screen: faster, and it vanishes on exit
  --alt                           Alias for --alt-mode auto
  --alt-region                    Alias for --alt-mode region
  --alt-full                      Alias for --alt-mode full
```

A bare `-N` is shorthand for `--lines N` (e.g. `-20` means `--lines 20`).

```sh
tail -f access.log | scroll | grep -v healthcheck > filtered.log
```

## Following a file

`--file`/`-f` follows a path the way `tail -F` does, reading appended data live
and reopening across truncation and rotation, instead of reading STDIN. File mode
implies `--null`, so nothing is written to STDOUT unless `--no-null` asks for it.

```sh
scroll -f /var/log/app.log --pid "$(pgrep -f app)"
```

`--pid` ends the run once that process is gone. On Linux, `--watch-proc` ends it
once no process holds the file open for writing, after `--watch-proc-timeout`
idle seconds.

## Sorting

`--sort`/`-s` shows the top N lines of the whole stream rather than the last N.
STDOUT stays a byte-for-byte copy in input order; only the display is reordered.

```sh
du -sh * | scroll --null --sort --human
```

`--sort-by` picks the key: a 1-based whitespace column, or a `/regex/` whose key
is the named capture `sort`, else the first group, else the whole match.
`--human` compares keys as human numbers (`1k` < `2M`, 1024-based), and
`--reverse`/`-r` keeps the smallest instead of the largest.

## Progress

`--progress` adds a progress line under the tail. With no size given it shows the
bytes and lines read and the rate of each:

```text
106K 20K ln 15M/s 2.7M ln/s
```

Tell it how much input to expect — `--size` in bytes (an integer or a 1024-based
suffixed number such as `500M` or `1.1k`), `--size-lines` in lines, or
`--file-size` to take the size from a file — and it adds a percentage, a bar, and
an ETA:

```text
 81% ████████████████████░░░░░ 106K/130K eta 4s 24M/s 20K ln 4.4M ln/s
```

Any of those options turns the progress line on by itself, as does a `--name`
label. Giving both a byte size and a line count warns and uses the byte size.

```sh
xz -dc archive.tar.xz | scroll --size 4.2G --name archive.tar.xz > /dev/null
```

A name takes the space the stats leave, and scrolls horizontally when the
terminal is too narrow to show it whole. A narrow terminal gives up stats fields
before the bar and the name lose room.

## Alternate screen

`--alt` draws on the terminal's alternate screen, which appends lines instead of
repainting a window and so keeps up with a much faster stream. On exit the screen
is restored and the last lines are echoed behind it.

```sh
make 2>&1 | scroll --alt -30 > build.log
```

Region mode honors `-N` by scrolling a band of that many lines; full mode ignores
it and uses the whole screen. `--alt` picks region unless `$TERM` says the
terminal is not a VT; `--alt-region` and `--alt-full` force the choice.

## Shell completion

```sh
eval "$(scroll --shell-completion bash)"   # or zsh, fish
```

## Development

```sh
shards build --no-debug --error-trace   # dev build
crystal spec --error-trace              # run tests
crystal tool format                     # format
ameba                                   # lint
```

## Contributing

1. Fork it (<https://github.com/plambert/scroll.cr/fork>)
2. Create your feature branch (`git checkout -b my-new-feature`)
3. Commit your changes (`git commit -am 'Add some feature'`)
4. Push to the branch (`git push origin my-new-feature`)
5. Create a new Pull Request

## Contributors

* [Paul M. Lambert](https://github.com/plambert) - creator and maintainer
