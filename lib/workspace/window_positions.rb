require "json"
require "fileutils"
require "time"

module Workspace
  # Where each workspace's window last sat, one `window.json` per workspace in
  # its state directory, so a later launch can put the window back.
  class WindowPositions
    VERSION = 1
    FILE = "window.json"
    RECT_KEYS = %w[x y width height].freeze

    # @param dir [String] the state directory holding one subdirectory per workspace
    # @param clock [#call] returns the current Time
    # @param logger [Workspace::Logger] debug logger
    def initialize(dir:, clock: -> { Time.now }, logger: Workspace::Logger.new)
      @dir = dir
      @clock = clock
      @logger = logger
    end

    # @param name [String] the workspace name
    # @return [String, nil] path to the workspace's `window.json`; nil for a name that is not a
    #   single path component (empty, `.`, `..`, or holding a `/`), which never gets a file
    def path_for(name)
      return nil if name.to_s.empty? || name == "." || name == ".." || name.include?("/") || name.include?("\0")
      File.join(@dir, name, FILE)
    end

    # Reads a workspace's saved position.
    #
    # @param name [String] the workspace name
    # @return [Hash, nil] `{bounds:, screen:, saved_at:}` with symbol-keyed
    #   rectangles (`screen` is nil when it was not known), or nil when no file
    #   exists
    # @raise [Workspace::Error] when the file cannot be read or is not a saved position
    def read(name)
      path = path_for(name)
      return nil unless path && File.file?(path)

      data = JSON.parse(File.read(path))
      raise Workspace::Error, "#{path} is not a window position" unless data.is_a?(Hash) && data["version"] == VERSION

      bounds = rectangle(data["bounds"])
      raise Workspace::Error, "#{path} has no usable bounds" unless bounds

      {bounds: bounds, screen: rectangle(data["screen"]), saved_at: data["saved_at"]}
    rescue JSON::ParserError, SystemCallError => e
      raise Workspace::Error, "Could not read #{path}: #{e.message}"
    end

    # Saves a workspace's position through a temp file and a rename, so a reader
    # never sees half a file. A directory that cannot be written is skipped.
    #
    # @param name [String] the workspace name
    # @param bounds [Hash] `{x:, y:, width:, height:}` of the window
    # @param screen [Hash, nil] the same keys for the screen holding the window's origin
    #   (nothing is saved when a bounds value is not a number)
    # @return [void]
    def write(name, bounds, screen = nil)
      path = path_for(name)
      return unless path && RECT_KEYS.all? { |key| bounds[key.to_sym].is_a?(Numeric) }

      FileUtils.mkdir_p(File.dirname(path))
      document = {"version" => VERSION, "bounds" => stringify(bounds), "screen" => screen && stringify(screen),
                  "saved_at" => @clock.call.utc.iso8601}
      temp = "#{path}.#{Process.pid}.tmp"
      File.write(temp, JSON.pretty_generate(document) + "\n")
      File.rename(temp, path)
    rescue SystemCallError => e
      FileUtils.rm_f(temp) if temp
      @logger.debug { "window_positions: could not write #{path}: #{e.message}" }
    end

    # @param name [String] the workspace name
    # @return [void]
    def delete(name)
      path = path_for(name)
      FileUtils.rm_f(path) if path
    rescue SystemCallError => e
      @logger.debug { "window_positions: could not delete #{path}: #{e.message}" }
    end

    private

    def stringify(rect)
      RECT_KEYS.to_h { |key| [key, rect.fetch(key.to_sym)] }
    end

    def rectangle(value)
      return nil unless value.is_a?(Hash) && RECT_KEYS.all? { |key| value[key].is_a?(Numeric) }
      RECT_KEYS.to_h { |key| [key.to_sym, value[key]] }
    end
  end
end
