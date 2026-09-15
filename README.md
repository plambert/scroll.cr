# scroll - like `cat` plus `tail`

Copy STDIN to STDOUT unchanged (like `/bin/cat`) while showing the last N lines of the stream in a
live, in-place display on STDERR. It is a pipeline filter — like an interactive `tail`, but the
stream keeps flowing through to the next command.

```sh
long-running-build | scroll -20 > build.log
```

![scroll showing the tail of a build while the output goes to a file](demo/static/redirect.gif)

The display is only drawn when STDERR is a terminal; when STDERR is redirected,
`scroll` acts like `cat` (use `--force` to draw to STDERR anyway).

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
# builds ./bin/scroll
```

## Usage

```text
Usage: scroll [options]

Show a live tail of a stream on STDERR while copying it to STDOUT

Options:
  --lines, -n COUNT               Lines to show (default: 10)
  --interval MS                   Minimum ms between redraws (default: 40)
  --force                         Draw the display even when STDERR is not a TTY
  --sanitize                      Strip control/escape bytes from the display (--no-sanitize to keep them)
  --final                         On EOF, also show a trailing line that has no newline
  --null                          Consume input without copying it to STDOUT (--no-null forces the copy)

Following a file:
  --file, -f PATH                 Follow PATH like `tail -F`, starting with its last -N lines (implies --null)
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
  --terminal-progress             Drive the terminal's own progress indicator (--no- skips even the query)
  --color WHEN                    Colorize the progress line (-c is --color on, -C is --color off)
  --progress-charset SET          Bar glyphs: unicode draws eighth-of-a-column steps, ascii stays in ASCII

Alternate screen:
  --fullscreen                    Draw on the alternate screen: faster, uses the whole screen, ignores -N
  --leave                         On exit, echo the last -N lines of the alternate screen onto the main one
```

A bare `-N` is shorthand for `--lines N` (e.g. `-20` means `--lines 20`).

```sh
tail -f access.log | scroll | grep -v healthcheck > filtered.log
```

`--null` consumes the input and writes nothing, for when only the display is
wanted. The `wc -c` below is there to show that STDOUT stayed empty:

![scroll with --null, writing nothing to STDOUT](demo/static/null.gif)

## Following a file

`--file`/`-f` follows a path the way `tail -F` does, reading appended data live
and reopening across truncation and rotation, instead of reading STDIN. It opens
on the last `-N` lines already in the file, so a follow starts with something on
screen rather than waiting for the next write; `--from-start` streams the whole
file instead. File mode implies `--null`, so nothing is written to STDOUT unless
`--no-null` asks for it.

```sh
scroll -f /var/log/app.log --pid "$(pgrep -f app)"
```

![scroll following a file, starting with the lines already in it](demo/static/follow.gif)

`--pid` ends the run once that process is gone. On Linux, `--watch-proc` ends it
once no process holds the file open for writing, after `--watch-proc-timeout`
idle seconds.

## Sorting

`--sort`/`-s` shows the top N lines of the whole stream rather than the last N.
STDOUT stays a byte-for-byte copy in input order; only the display is reordered.

```sh
du -sh * | scroll --null --sort --human
```

![scroll keeping the largest lines of the whole stream](demo/static/sort.gif)

`--sort-by` picks the key: a 1-based whitespace column, or a `/regex/` whose key
is the named capture `sort`, else the first group, else the whole match.
`--human` compares keys as human numbers (`1k` < `2M`, 1024-based), and
`--reverse`/`-r` keeps the smallest instead of the largest.

## Progress

`--progress` adds a progress line under the tail. With no size given it shows the
bytes and lines read and the rate of each:

```text
106K · 20K ln · 15M/s · 2.7M ln/s
```

Tell it how much input to expect — `--size` in bytes (an integer or a 1024-based
suffixed number such as `500M` or `1.1k`), `--size-lines` in lines, or
`--file-size` to take the size from a file — and it adds a percentage, a bar, and
an ETA:

```text
 81% ███████████████████▉░░░░░ 106K/130K · eta 4s · 24M/s · 20K ln · 4.4M ln/s
```

Any of those options turns the progress line on by itself, as does a `--name`
label. Giving both a byte size and a line count warns and uses the byte size.

```sh
xz -dc archive.tar.xz | scroll --size 4.2G --name archive.tar.xz > /dev/null
```

![the progress line with a bar, an ETA, and a label](demo/static/progress.gif)

A name takes the space the stats leave, and scrolls horizontally when the
terminal is too narrow to show it whole. A narrow terminal gives up stats fields
before the bar and the name lose room.

Terminals that show a progress indicator of their own — in a tab, a dock icon,
or a taskbar — are driven along with the line, through `OSC 9;4`. Since a
terminal that does not know that sequence would print it into the display, one
has to name itself first: `scroll` asks with `XTVERSION` and waits 100ms for an
answer naming ghostty, kitty, or iTerm2. `--terminal-progress` and
`--no-terminal-progress` answer for it, and skip the question entirely.

The line is colorized when STDERR is a terminal that can show it. This is controlled
by `--color on|off|auto`, or the aliases `-c` (color on) and `-C` (color off).

`NO_COLOR` or a `$TERM` of `dumb` turn `auto` off. The bar is drawn with UTF-8
characters for a resolution of 1/8th of a character width. Use `--progress-charset ascii`
to use ASCII.

## Alternate screen

`--fullscreen` draws on the terminal's alternate screen, which appends lines
instead of repainting a window. This means it will show every line of output and never
skip any. It ignores `-N`. If you use `--leave`, it changes the meaning of `-N` to be
the number of lines you want echoed to the main screen after completion, in case you want
the last N lines in your history.

```sh
make 2>&1 | scroll --fullscreen > build.log
```

![scroll on the alternate screen, leaving the last lines behind](demo/static/fullscreen.gif)

## Shell completion

```sh
eval "$(scroll --shell-completion bash)"   # or zsh, fish
```

## Development

```sh
shards build --error-trace              # dev build
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
