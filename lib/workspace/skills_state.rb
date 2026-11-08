require "json"

module Workspace
  # `skills.json` in the state directory: the harnesses the person declined, so
  # `skills install` does not ask again. Whether a harness is linked is read from
  # its directory, never stored. Written under a flock through a temp file and a
  # rename; a file that can't be read as `{"declined": [..]}` reads as empty.
  class SkillsState
    # @param dir [String] the workspace state directory
    def initialize(dir:)
      @path = File.join(dir, "skills.json")
      @lock = FileLock.new("#{@path}.lock", dir_mode: nil)
    end

    # @return [String]
    attr_reader :path

    # @return [Array<String>] harness keys declined
    def declined
      data = JSON.parse(File.read(@path))
      list = data.is_a?(Hash) ? data["declined"] : nil
      list.is_a?(Array) ? list.grep(String).uniq : []
    rescue SystemCallError, JSON::ParserError
      []
    end

    # @param keys [Array<String>] harness keys to store as declined
    # @return [void]
    def declined=(keys)
      @lock.hold do
        AtomicFile.write(@path, JSON.pretty_generate({"declined" => keys.uniq}) + "\n",
          perm: nil, fsync: false, temp_name: ->(path) { "#{path}.tmp-#{Process.pid}" })
      end
    end
  end
end
