module Workspace
  # The checks `config set agent.commands.<kind>` makes against the machine, which the
  # key's parser can't: {AgentCommands} parses a stored value on every read and falls back
  # to the default when parsing raises, so a parser that looked at the filesystem would turn
  # a stale absolute path into a silent launch of the default. These run once, at set time.
  class AgentCommandCheck
    # @param which [#call] PATH lookup taking a program name ({Workspace::Which})
    # @param file_system [#stat] answers `stat(path)` following symlinks, raising `SystemCallError` (`File`)
    # @param executable [#call] `executable?(path)` (`File.method(:executable?)`)
    def initialize(which: Which, file_system: File, executable: File.method(:executable?))
      @which = which
      @file_system = file_system
      @executable = executable
    end

    # @param key [String] a settable `agent.commands.<kind>` key
    # @param value [String] the command being set
    # @return [Array<String>] warnings; empty for any other key
    # @raise [Workspace::Error] code `agent_command_not_executable` when the program is an absolute
    #   path that is missing, not a regular file or not executable
    def call(key, value)
      kind = key[/\Aagent\.commands\.(.+)\z/, 1]
      provider = kind && AgentProvider.find(kind)
      return [] unless provider

      program = AgentCommands.program_words(value).first
      return [] unless program

      warnings = []
      if program.start_with?("/")
        check_path!(program)
      elsif !@which.call(program)
        warnings << "#{program} is not on PATH"
      end
      name = File.basename(program)
      unless name.match?(/\A#{Regexp.escape(provider.executable)}(-[A-Za-z0-9._+-]+)?\z/)
        warnings << "#{name} does not look like a #{provider.key} command"
      end
      warnings
    end

    private

    def check_path!(path)
      reason = begin
        stat = @file_system.stat(path)
        if !stat.file?
          "not_a_file"
        elsif !@executable.call(path)
          "not_executable"
        end
      rescue SystemCallError
        "missing"
      end
      return unless reason

      what = {"missing" => "does not exist", "not_a_file" => "is not a file", "not_executable" => "is not executable (chmod +x it)"}.fetch(reason)
      raise Workspace::Error.new("#{path} #{what}. Give the path of an executable file, or a bare name that is on PATH.", code: "agent_command_not_executable",
        details: {"path" => path, "reason" => reason})
    end
  end
end
