module Workspace
  # Writes warning messages, colorizing them yellow when the destination is a
  # terminal. Keeps ANSI formatting out of command classes, which just call
  # Warn.puts(@error_output, "...") the same way they'd call error_output.puts.
  module Warn
    YELLOW = "\e[33m"
    RESET = "\e[0m"

    def self.puts(io, message)
      io.puts io.tty? ? "#{YELLOW}#{message}#{RESET}" : message
    end
  end
end
