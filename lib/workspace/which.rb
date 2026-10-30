module Workspace
  # Default PATH lookup used by commands that accept an injectable `which:`.
  module Which
    # @param exe [String] executable name to look up on PATH
    # @return [String, nil] the absolute path of the first executable file of that name on PATH
    def self.path(exe)
      ENV.fetch("PATH", "").split(File::PATH_SEPARATOR).each do |dir|
        next if dir.empty?
        candidate = File.join(File.expand_path(dir), exe)
        return candidate if File.file?(candidate) && File.executable?(candidate)
      end
      nil
    end

    # @param exe [String] executable name to look up on PATH
    # @return [Boolean] true when the executable is found
    def self.call(exe)
      system("command", "-v", exe, out: File::NULL, err: File::NULL)
    end
  end
end
