module Scroll
  # Where the pump pulls bytes from. `read` fills a buffer and returns the byte
  # count; a return of `0` means *terminal* EOF, which the Runner treats as the
  # shutdown signal. A source that merely has nothing to hand back *yet* (a file
  # being followed) blocks inside `read` instead of returning 0 — the blocking
  # is a cooperative `sleep`, so the render and ticker fibers keep running.
  abstract class Source
    abstract def read(buffer : Bytes) : Int32

    def close : Nil
    end
  end

  # The default source: a thin delegate to STDIN. EOF on STDIN is terminal.
  class StdinSource < Source
    def read(buffer : Bytes) : Int32
      STDIN.read(buffer)
    end
  end

  # Follows a file the way `tail -F` does: reads appended bytes live, reopens
  # across rotation (the name now points at a different inode), and seeks back
  # to 0 across truncation (the file shrank in place). When there is nothing new
  # it sleep-polls, which yields to the event loop. `read` only ever returns 0
  # when a termination condition (`--pid` gone, or the Linux writer-idle timer)
  # fires *after* the current file has been drained to EOF, so no trailing bytes
  # are lost.
  class FileSource < Source
    # Result of re-checking the followed path after the open fd hit EOF.
    private enum Status
      Current   # same inode, no new data yet
      Rotated   # name points at a new inode; reopen from 0
      Truncated # same inode, shrank; seek to 0
      Missing   # name is gone; wait for it to reappear
    end

    NEWLINE    = '\n'.ord.to_u8
    SCAN_BLOCK = 8192

    @file : File? = nil
    # How many existing lines to show before following, so a follow does not open
    # on an empty display; nil under --from-start, which streams the whole file.
    # Only the first open of a file that already existed at construction consumes
    # it; every later open (appear-after-start, rotation, truncation) starts at
    # offset 0 because that content is by definition new.
    @prime_lines : Int32?

    def initialize(
      path : String,
      poll : Time::Span,
      *,
      from_start : Bool = false,
      prime_lines : Int32 = 0,
      @pid : Int32? = nil,
      @watch_proc : Bool = false,
      watch_proc_timeout : Time::Span = 10.seconds,
    )
      @path = path
      @poll = poll
      @watch_proc_timeout = watch_proc_timeout
      @prime_lines = from_start || !File.exists?(path) ? nil : prime_lines
      @last_writer_seen = Time.instant
    end

    def read(buffer : Bytes) : Int32
      loop do
        if file = @file
          count = file.read(buffer)
          return count if count > 0
          # EOF on the current fd: decide what happened to the name.
          case check_status(file)
          in Status::Rotated
            reopen
            next # re-read the new inode immediately
          in Status::Truncated
            file.pos = 0
            next # re-read from the start of the shrunk file
          in Status::Missing
            close # wait for the name to reappear
          in Status::Current
            # drained to EOF, nothing new; fall through to the wait below
          end
        elsif open_file
          next # opened (appeared); read it on the next pass
        end
        return 0 if terminate?
        sleep @poll
      end
    end

    def close : Nil
      if file = @file
        file.close
        @file = nil
      end
    end

    # Open @path if it is present. Returns true when a file was opened.
    private def open_file : Bool
      file = File.new(@path)
      if lines = @prime_lines
        file.pos = FileSource.tail_offset(file, lines)
        @prime_lines = nil
      end
      @file = file
      true
    rescue File::NotFoundError
      false
    rescue File::Error
      false
    end

    # Byte offset of the start of the last `lines` complete lines, or 0 when the
    # file holds fewer than that. Scanned backwards in blocks, so priming from a
    # huge log costs a read or two rather than a pass over the whole file.
    def self.tail_offset(file : File, lines : Int32) : Int64
      size = file.size.to_i64
      return size if lines <= 0 || size == 0

      # A newline at the end terminates the last line rather than starting one.
      file.pos = size - 1
      final = Bytes.new(1)
      file.read_fully(final)
      position = final[0] == NEWLINE ? size - 1 : size

      found = 0
      buffer = Bytes.new(SCAN_BLOCK)
      while position > 0
        length = Math.min(SCAN_BLOCK.to_i64, position).to_i32
        position -= length
        file.pos = position
        file.read_fully(buffer[0, length])
        index = length - 1
        while index >= 0
          if buffer[index] == NEWLINE
            found += 1
            return position + index + 1 if found == lines
          end
          index -= 1
        end
      end
      0_i64
    end

    private def reopen : Nil
      close
      open_file
    end

    # Re-stat the followed name after an EOF to decide what happened to it.
    private def check_status(file : File) : Status
      info = File.info?(@path)
      return Status::Missing unless info
      if !info.same_file?(file.info)
        Status::Rotated
      elsif info.size < file.pos
        Status::Truncated
      else
        Status::Current
      end
    end

    # A termination condition ends the follow after the current EOF drain.
    private def terminate? : Bool
      if pid = @pid
        return true unless Process.exists?(pid)
      end
      return writer_idle_expired? if @watch_proc
      false
    end

    {% if flag?(:linux) %}
      # True once no writer has held the file open for @watch_proc_timeout.
      private def writer_idle_expired? : Bool
        if writer_present?
          @last_writer_seen = Time.instant
          return false
        end
        @last_writer_seen.elapsed > @watch_proc_timeout
      end

      # Scan /proc for any process holding the followed path open for writing.
      # Same-uid-only without root; other users' writers are invisible (EACCES),
      # so the idle timer may fire early — documented degradation.
      private def writer_present? : Bool
        real = real_path
        return false unless real
        Dir.each_child("/proc") do |entry|
          next unless entry.to_i?
          return true if process_writes?(entry, real)
        end
        false
      end

      private def real_path : String?
        File.realpath(@path)
      rescue File::Error
        nil
      end

      private def process_writes?(pid : String, real : String) : Bool
        fd_dir = "/proc/#{pid}/fd"
        Dir.each_child(fd_dir) do |fd|
          target = readlink_or_nil(File.join(fd_dir, fd))
          next unless target == real
          return true if fd_writable?(pid, fd)
        end
        false
      rescue File::AccessDeniedError
        false
      rescue File::NotFoundError
        false
      end

      private def readlink_or_nil(link : String) : String?
        File.readlink(link)
      rescue File::Error
        nil
      end

      # A writer has O_WRONLY (1) or O_RDWR (2) in the low two bits of the octal
      # `flags:` field of /proc/<pid>/fdinfo/<fd>.
      private def fd_writable?(pid : String, fd : String) : Bool
        path = "/proc/#{pid}/fdinfo/#{fd}"
        File.each_line(path) do |line|
          next unless line.starts_with?("flags:")
          octal = line.split[1]?
          next unless octal
          flags = octal.to_i?(base: 8)
          next unless flags
          access = flags & 0o3
          return access == 1 || access == 2
        end
        false
      rescue File::AccessDeniedError
        false
      rescue File::NotFoundError
        false
      end
    {% else %}
      # Never reached: --watch-proc is rejected at parse time off Linux.
      private def writer_idle_expired? : Bool
        false
      end
    {% end %}
  end
end
