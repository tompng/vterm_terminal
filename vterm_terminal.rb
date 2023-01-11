require 'io/console'
require 'pty'
require 'vterm'
module Reline; require 'reline/unicode'; end

rows, cols = STDIN.winsize
vterm = VTerm.new rows, cols
vterm.set_utf8 true
vterm.screen.reset true
command = ARGV[0] || 'bash'
COLORS = {
  0 => 0,
  0xf0f0f0 => 7
}

def font_color(color)
  return color.index if color.is_a? VTerm::ColorIndexed
  COLORS[(color.red << 16) | (color.green << 8) | color.blue]
rescue
  puts "Unimplemented color: #{color}"
  exit
end

def add_font_style(font, attrs)
  font << 1 if attrs.bold
  font << 3 if attrs.italic == 1
  font << 4 if attrs.underline == 1
  font << 7 if attrs.reverse == 1
end

@char_width = {}
def width(char)
  @char_width[char] ||= Reline::Unicode.calculate_width char
end


PTY.spawn command do |rio, wio|
  rio.winsize = [rows, cols]
  Thread.new do
    STDIN.raw do
      loop do
        data = STDIN.readpartial 1024
        exit if data =~ /exit/ || data.nil?
        wio.write data
      end
    end
  end
  mutex = Mutex.new
  needs_update = true
  Thread.new do
    loop do
      data = rio.readpartial 1024
      break unless data
      mutex.synchronize do
        vterm.write data
        needs_update = true
      end
    rescue
      break
    end
    exit
  end
  prev_screen = rows.times.map { [nil] * cols}
  $> << "\e[H\e[2J"
  time = Time.now
  loop do
    if Time.now - time > 5
      time = Time.now
      prev_screen = rows.times.map { [nil] * cols}
      needs_update = true
    end
    sleep 0.01
    next unless needs_update
    needs_update = false
    screen, cursor_row, cursor_col = mutex.synchronize do
      wio.write vterm.read
      vterm.write "\e[6n"
      matched = vterm.read.match(/\e\[(?<cursor_row>\d+);(?<cursor_col>\d+)R/)
      [vterm.screen, matched[1].to_i, matched[2].to_i]
    end
    next_screen = rows.times.map do |row|
      cols.times.map do |col|
        cell = screen.cell_at(row, col)
        attrs = cell.attrs
        font = [40 + font_color(cell.bg), 30 + font_color(cell.fg)]
        add_font_style(font, attrs)
        [cell.char, font]
      end
    end
    output = prev_screen.zip(next_screen).each_with_index.map do |(prev_row, next_row), row|
      next if prev_row == next_row
      updates = prev_row.zip(next_row).map { _2 if _1 != _2 }
      chunks = updates.chunk { |_char, font| font || :skip }
      data = chunks.map do |font, values|
        if font == :skip
          "\e[#{values.size}C"
        else
          chars = values.map { _1[0] }
          "\e[#{font.compact.join(';')}m#{chars.map { _1 == '' ? ' ' : _1 }.join}\e[0m"
        end
      end
      ["\e[#{row + 1}H", data]
    end.compact
    $><< output.join + "\e[#{cursor_row};#{cursor_col}H"
    prev_screen = next_screen
  end
end
