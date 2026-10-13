module Workspace
  # Answers "does iTerm still have this workspace's window?" for tracked
  # projects, so `list --liveness` and `status` can tell a workspace whose
  # window was closed from one that is still on screen. {Workspace::Liveness}
  # answers the same for tmux; the two are separate because a workspace can
  # lose either one alone.
  #
  # Windows are listed once per call, and not at all when every entry is
  # headless.
  class WindowLiveness
    # @param window_manager [Workspace::WindowManager] source of live window ids
    def initialize(window_manager:)
      @window_manager = window_manager
    end

    # @param entries [Hash{String => Hash}] project name to its state entry
    # @return [Hash{String => Boolean, nil}] true when the recorded window is
    #   among iTerm's windows; false when it is not, or none is recorded; nil
    #   for a headless entry, and for every windowed entry when the window
    #   list could not be read (window-tool missing, failing, or printing something that is not a window list)
    def call(entries)
      windowed = entries.reject { |_, info| headless?(info) }
      live_ids = windowed.empty? ? nil : list_window_ids

      entries.to_h do |project, info|
        [project, (headless?(info) || live_ids.nil?) ? nil : window_alive?(info, live_ids)]
      end
    end

    private

    def headless?(info)
      info["headless"] ? true : false
    end

    def window_alive?(info, live_ids)
      window_id = info["iterm_window_id"]
      !window_id.nil? && live_ids.include?(window_id.to_i)
    end

    def list_window_ids
      @window_manager.live_window_ids
    rescue Workspace::Error, SystemCallError, JSON::ParserError, NoMethodError
      nil
    end
  end
end
