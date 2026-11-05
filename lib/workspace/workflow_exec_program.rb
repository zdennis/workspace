module Workspace
  # The one rule for whether the program of a `require: exec:` entry (argument 1 of its argv) can run.
  # {WorkflowEngine#preflight} refuses by it and `workflow validate` warns by it.
  module WorkflowExecProgram
    # An absolute path or one starting `~/` must be an executable regular file (`~/` with no HOME is
    # missing); a bare name must be an executable regular file in a directory of +path+; a relative path
    # with a slash resolves against +checkout+. Only argument 1 is looked at, and only against the
    # PATH of this process, which the daemon's may differ from.
    #
    # A relative program may be one the branch adds, so with no +checkout+ (a worktree not made yet, or
    # a directory that does not exist) it is not judged and gives nil.
    #
    # @param argv0 [String] the program as written, before any placeholder is filled
    # @param checkout [String, nil] the checkout a relative program resolves against
    # @param path [String, nil] a PATH value
    # @param home [String, nil] the home directory for `~/`
    # @return [String, nil] why the program can't run, nil when it can (or can't be judged)
    def self.problem(argv0, checkout:, path: ENV["PATH"], home: ENV["HOME"])
      program = argv0.to_s
      return "is empty" if program.empty?
      if program.start_with?("~/")
        return "starts with ~/ and HOME is not set" if home.to_s.empty?
        return file_problem(File.join(home, program[2..]))
      end
      return file_problem(program) if program.start_with?("/")
      if program.include?("/")
        return nil if checkout.nil? || !File.directory?(checkout)
        return file_problem(File.expand_path(program, checkout))
      end
      found = path.to_s.split(File::PATH_SEPARATOR).reject(&:empty?).any? { |dir| runnable?(File.join(dir, program)) }
      found ? nil : "is not on PATH"
    end

    def self.file_problem(full)
      return "does not exist: #{full}" unless File.exist?(full)
      return "is not a file: #{full}" unless File.file?(full)
      return "is not executable: #{full}" unless File.executable?(full)
      nil
    end

    def self.runnable?(full)
      File.file?(full) && File.executable?(full)
    end
  end
end
