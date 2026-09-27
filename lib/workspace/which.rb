module Workspace
  # Default PATH lookup used by commands that accept an injectable `which:`.
  module Which
    # @param exe [String] executable name to look up on PATH
    # @return [Boolean] true when the executable is found
    def self.call(exe)
      system("command", "-v", exe, out: File::NULL, err: File::NULL)
    end
  end
end
