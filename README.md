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

```sh
shards build --release
# copies to ./bin/scroll
```

## Usage

```text
Usage: scroll [options]

Options:
    -n, --lines INT      Lines to show (default: 10)
        --interval MS    Minimum ms between redraws (default: 40)
        --force          Draw the display even when STDERR is not a TTY
        --no-sanitize    Do not strip control/escape bytes from the display
        --final          On EOF, also show a trailing line that has no newline
        --version        Show version and exit
    -h, --help           Show this help and exit
```

A bare `-N` is shorthand for `--lines N` (e.g. `-20` means `--lines 20`).

```sh
tail -f access.log | scroll | grep -v healthcheck > filtered.log
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
