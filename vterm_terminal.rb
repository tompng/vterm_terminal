require 'io/console'
require 'pty'
require 'vterm'
require 'monitor'
# module Reline; require 'reline/unicode'; end TODO: calculate unicode charwidth

class VTermTerminal
  attr_accessor :activated
  def initialize(command, rows, cols, offset_left)
    @command = command
    @rows = rows
    @cols = cols
    @activated = true
    @offset_left = offset_left
    @vterm = VTerm.new rows, cols
    @vterm.set_utf8 true
    @vterm.screen.reset true
    @monitor = Monitor.new
    @cond = @monitor.new_cond
    @needs_refresh = true
    @needs_update = true
    @char_width_cache = {}
    clear_screen_cache
  end

  COLOR_ELEMENT_TABLE = [0, 95, 135, 175, 215, 255]
  COLOR_VALUE_INDEX = 256.times.map do |value|
    (0..5).min_by { (COLOR_ELEMENT_TABLE[_1] - value).abs }
  end
  def font_color(color, base)
    return base + color.index if color.is_a? VTerm::ColorIndexed
    r = COLOR_VALUE_INDEX[color.red]
    g = COLOR_VALUE_INDEX[color.green]
    b = COLOR_VALUE_INDEX[color.blue]
    [base + 8, 5, r * 36 + g * 6 + b + 16]
  end

  def font_style(cell)
    font = [font_color(cell.fg, 30), font_color(cell.bg, 40)]
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

  def write_to_pty(data)
    @pty_output.write data
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
        # avoid writing null byte to vterm
        @vterm.write data.tr("\0", "\1")
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

  def render_header
    window_cols = STDOUT.winsize.last - @offset_left
    return if window_cols <= 0
    header = "#{@cols}x#{@rows} #{@command}"
    header_width = [window_cols, @cols].min
    if header.size < header_width
      header << ' ' * (header_width - header.size)
    else
      header = header[0, header_width]
    end
    color_seq = @activated ? "\e[41;1;37m" : "\e[47;30m"
    $> << "\e[1;#{@offset_left + 1}H#{color_seq}#{header}\e[m"
  end

  def render(refresh)
    window_rows, window_cols = STDOUT.winsize
    window_cols -= @offset_left
    return if window_cols <= 0
    if refresh
      clear_screen_cache
      render_header
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
      ["\e[#{row + HEADER_HEIGHT + 1};#{@offset_left + 1}H", data]
    end
    $> << output.join + "\e[#{[window_rows, cursor_row + HEADER_HEIGHT].min};#{@offset_left + [window_cols, cursor_col].min}H"
    @screen_cache = next_screen
  end

  HEADER_HEIGHT = 1
  REFRESH_INTERVAL = 10
  CLEAR_SCREEN = "\e[H\e[2J"

  def self.watch_winch
    window_changed = false
    Signal.trap :WINCH do
      window_changed = true
    end
    cnt = 0
    step = 0.25
    loop do
      cnt += step
      sleep step
      next unless window_changed || cnt > REFRESH_INTERVAL
      $> << CLEAR_SCREEN if window_changed
      cnt = 0
      window_changed = false
      yield
    end
  end

  def start
    PTY.spawn @command do |pty_input, pty_output|
      @pty_output = pty_output
      pty_output.winsize = [@rows, @cols]
      terminate = -> {
        $> << "\e[#{@rows + HEADER_HEIGHT};#{@cols}H\r\n"
        exit
      }
      Thread.new do
        pty_to_vterm(pty_input, pty_output)
        terminate.call
      end
      main
    end
  end
end

if ARGV[0]&.match?(/help/)
  puts "ARGV = [*commands] | ['-s', '80x24', *commands]"
  puts "To switch tab, press `option + number` (0 means all tab)"
  exit
end
if ARGV[0] == '-s'
  raise 'invalid size' unless ARGV[1] =~ /\A(\d+)x(\d+)\z/
  cols = $1.to_i
  rows = $2.to_i
  commands = ARGV[2..]
else
  window_rows, window_cols = STDOUT.winsize
  commands = ARGV.dup
  num = [commands.size, 1].max
  rows = window_rows - VTermTerminal::HEADER_HEIGHT
  cols = (window_cols - num + 1) / num
end
commands << 'bash' if commands.empty?


vterms = commands.map.with_index do |command, index|
  VTermTerminal.new(command, rows, cols, index * (cols + 1))
end
$> << VTermTerminal::CLEAR_SCREEN
vterms.each do |vterm|
  Thread.new { vterm.start }
end
Thread.new do
  STDIN.raw do
    current_tab = 0
    loop do
      data = STDIN.readpartial 1024
      break unless data
      if data =~ /\A\e(\d)\z/
        current_tab = $1.to_i
        vterms.each.with_index(1) do |vterm, tab|
          vterm.activated = current_tab.zero? || current_tab == tab
          vterm.render_header
        end
      else
        vterms.each.with_index(1) do |vterm, tab|
          vterm.write_to_pty data if current_tab.zero? || current_tab == tab
        end
      end
    end
  end
  exit
end

VTermTerminal.watch_winch do
  vterms.each(&:trigger_refresh)
end
