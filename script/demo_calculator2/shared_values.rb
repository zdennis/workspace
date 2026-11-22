require "shellwords"

module DemoCalculator2
  # What a shared value (the merge driver config, the attributes line, the `workflows.sources` list) is right now, against the
  # value this checkout wants. Pure: the caller reads the live value and answers the questions about the filesystem, so the same
  # rule serves `Lanes#write_attributes` and the series registry and preflight.
  module SharedValues
    DRIVER_KEY = "git-config:merge.calc-demo-tests.driver".freeze
    DRIVER_COMMAND = 'ruby "$(git rev-parse --show-toplevel)/script/demo_calculator2/merge_test_methods" %O %A %B'.freeze
    SOURCES_PREFIX = "workflows.sources:".freeze
    SOURCES_SUFFIX = "/demo/calculator2/workflows".freeze
    ABSOLUTE_DRIVER = %r{\Aruby (.+)/script/demo_calculator2/merge_test_methods %O %A %B\z}

    # @param key [String] `git-config:merge.calc-demo-tests.driver`, `attributes:<line>`, `workflows.sources:<path>` or another `git-config:` key
    # @param live [String, Array<String>, nil] the value now; for a sources key the entries ahead of and including ours (a comma list works too)
    # @param wanted [String] the value this checkout would write
    # @param path_exists [#call] `call(path)` says whether a checkout or directory still exists
    # @param owner_running [#call, nil] carried for callers that decide a take-over; the state does not depend on it
    # @param same_definitions [#call, nil] `call(entry)` says whether an existing sources entry holds the same definitions as ours; nil means it differs
    # @return [Symbol] `:absent`, `:equal`, `:dangling` or `:foreign_live`
    def self.classify(key, live:, wanted:, path_exists:, owner_running: nil, same_definitions: nil)
      return classify_sources(live, wanted, path_exists, same_definitions) if key.start_with?(SOURCES_PREFIX)
      return :absent if live.nil? || live.to_s.empty?
      return :equal if live == wanted
      return :dangling unless key == DRIVER_KEY
      return :dangling if live == DRIVER_COMMAND
      path = driver_path(live)
      return :foreign_live if path.nil?
      path_exists.call(path) ? :foreign_live : :dangling
    end

    # @param value [String] a merge driver command
    # @return [String, nil] the checkout path in `ruby <path>/script/demo_calculator2/merge_test_methods %O %A %B`; nil for the path-agnostic form and for any other command
    def self.driver_path(value)
      return nil if value == DRIVER_COMMAND
      match = ABSOLUTE_DRIVER.match(value.to_s)
      match && Shellwords.split(match[1]).first
    end

    # @return [String] the checkout a live value belongs to, for a refusal message
    def self.owner_path(key, live)
      return driver_path(live) || "unknown" if key == DRIVER_KEY
      key.start_with?(SOURCES_PREFIX) ? live.to_s.delete_suffix(SOURCES_SUFFIX) : "unknown"
    end

    # @return [String] why a run stops on a `:foreign_live` value
    def self.refusal(key, live, owner)
      "#{key} is already #{live.inspect}, which belongs to the checkout #{owner}. Pass --take-over to `series` once that checkout has no going run."
    end

    def self.classify_sources(live, wanted, path_exists, same_definitions)
      entries = live.is_a?(String) ? live.split(",").map(&:strip).reject(&:empty?) : Array(live)
      state = :absent
      entries.each do |entry|
        if entry == wanted
          return (state == :absent) ? :equal : state
        end
        next unless entry.end_with?(SOURCES_SUFFIX)
        if !path_exists.call(entry)
          state = :dangling
        elsif same_definitions&.call(entry)
          state = (state == :absent) ? :equal : state
        else
          return :foreign_live
        end
      end
      state
    end
    private_class_method :classify_sources
  end
end
