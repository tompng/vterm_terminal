require 'io/console'
require 'pty'
require 'vterm'
require 'monitor'
# module Reline; require 'reline/unicode'; end TODO: calculate unicode charwidth

class VTermTerminal
  def initialize(rows, cols)
    @rows = rows
    @cols = cols
    @vterm = VTerm.new rows, cols
    @vterm.set_utf8 true
    @vterm.screen.reset true
    @mutex = Mutex.new
    @monitor = Monitor.new
    @cond = @monitor.new_cond
    @needs_refresh = true
    @needs_update = true
    @char_width_cache = {}
    clear_screen_cache
  end

  COLORS = { 0 => 0, 0xf0f0f0 => 7 }
  def font_color(color)
    return color.index if color.is_a? VTerm::ColorIndexed
    COLORS[(color.red << 16) | (color.green << 8) | color.blue]
  rescue
    puts "Unimplemented color: #{color}"
    exit
  end

  def font_style(cell)
    font = [30 + font_color(cell.fg), 40 + font_color(cell.bg)]
    attrs = cell.attrs
    font << 1 if attrs.bold
    font << 3 if attrs.italic == 1
    font << 4 if attrs.underline == 1
    font << 7 if attrs.reverse == 1
    font
  end

  def char_width(char)
    @char_width_cache[char] ||= Reline::Unicode.calculate_width char
  end

  def clear_screen_cache
    @screen_cache = @rows.times.map { [nil] * @cols }
  end

  def stdin_to_pty(pty_output)
    STDIN.raw do
      loop do
        data = STDIN.readpartial 1024
        break unless data
        pty_output.write data
      end
    end
  end

  def trigger_update
    @monitor.synchronize do
      @needs_update = true
      @cond.signal
    end
  end

  def trigger_refresh
    @monitor.synchronize do
      @needs_refresh = true
      @cond.signal
    end
  end

  def pty_to_vterm(pty_input, pty_output)
    loop do
      data = pty_input.readpartial 1024
      break unless data
      @monitor.synchronize do
        @vterm.write data
        pty_output.write @vterm.read
        trigger_update
      end
    rescue
      break
    end
  end

  def main
    loop do
      update_only = false
      @monitor.synchronize do
        @cond.wait_while { !@needs_update && !@needs_refresh }
        update_only = true unless @needs_refresh
      end
      sleep 0.01
      @needs_update = @needs_refresh = false
      render !update_only
    end
  end

  def render(refresh)
    window_rows, window_cols = STDOUT.winsize
    if refresh
      clear_screen_cache
      header = "VTERM #{@cols}x#{@rows}"
      header_width = [window_cols, @cols].min
      if header.size < header_width
        header << ' ' * (header_width - header.size)
      else
        header = header[0, header_width]
      end
      $> << "\e[H\e[41m\e[37m#{header}\e[m"
    end
    screen, cursor_row, cursor_col = @monitor.synchronize do
      @vterm.write "\e[6n"
      matched = @vterm.read.match(/\e\[(?<cursor_row>\d+);(?<cursor_col>\d+)R/)
      [@vterm.screen, matched[1].to_i, matched[2].to_i]
    end
    next_screen = @rows.times.map do |row|
      @cols.times.map do |col|
        cell = screen.cell_at(row, col)
        [cell.char, font_style(cell)]
      end
    end
    output = [@rows, window_rows - HEADER_HEIGHT].min.times.map do |row|
      prev_row = @screen_cache[row]
      next_row = next_screen[row]
      next if prev_row == next_row
      changes = [@cols, window_cols].min.times.map do |col|
        cell = next_row[col]
        cell if cell != prev_row[col]
      end
      chunks = changes.chunk { |_char, font| font || :skip }
      data = chunks.map do |font, values|
        if font == :skip
          "\e[#{values.size}C"
        else
          chars = values.map { _1[0] }
          "\e[#{font.compact.join(';')}m#{chars.map { _1 == '' ? ' ' : _1 }.join}\e[0m"
        end
      end
      ["\e[#{row + HEADER_HEIGHT + 1}H", data]
    end
    $><< output.join + "\e[#{[window_rows, cursor_row + HEADER_HEIGHT].min};#{[window_cols, cursor_col].min}H"
    @screen_cache = next_screen
  end

  HEADER_HEIGHT = 1
  REFRESH_INTERVAL = 10
  CLEAR_SCREEN = "\e[H\e[2J"

  def watch_winch
    window_changed = false
    Signal.trap :WINCH do
      window_changed = true
      $> << CLEAR_SCREEN
    end
    cnt = 0
    step = 0.25
    loop do
      cnt += step
      sleep step
      next unless window_changed || cnt > REFRESH_INTERVAL
      cnt = 0
      window_changed = false
      $> << CLEAR_SCREEN if window_changed
      trigger_refresh
    end
  end

  def start(command)
    $> << CLEAR_SCREEN
    PTY.spawn command do |pty_input, pty_output|
      terminate = -> {
        $> << "\e[#{@rows + HEADER_HEIGHT};#{@cols}H\r\n"
        exit
      }
      Thread.new do
        watch_winch
      end
      Thread.new do
        stdin_to_pty(pty_output)
        terminate.call
      end
      Thread.new do
        pty_to_vterm(pty_input, pty_output)
        terminate.call
      end
      main
    end
  end
end

if ARGV[0]&.match?(/help/)
  puts "ARGV = [command] | [command, 'auto'] | [command, cols, rows]"
  exit
end
command = ARGV[0] || 'bash'
window_rows, window_cols = STDOUT.winsize
rows = window_rows - VTermTerminal::HEADER_HEIGHT
cols = window_cols
if ARGV[1] =~ /\A(\d+)x(\d+)\z/
  cols = $1.to_i
  rows = $2.to_i
end

VTermTerminal.new(rows, cols).start(command)
