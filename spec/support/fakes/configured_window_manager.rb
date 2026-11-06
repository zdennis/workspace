# frozen_string_literal: true

# A window manager fake that answers with the windows it is given and records the ids it focuses.
class ConfiguredWindowManager < CLITestHelpers::FakeWindowManager
  attr_reader :iterm_windows, :focused_ids

  def initialize(live_window_ids: Set.new, iterm_windows: {}, forbid_focus_steps: false)
    super(live_window_ids: live_window_ids)
    @iterm_windows = iterm_windows
    @forbid_focus_steps = forbid_focus_steps
    @focused_ids = []
  end

  def focus_by_id(wid)
    @focused_ids << wid
    true
  end

  def run_focus_steps(wid, steps)
    raise "tile must not run focus steps" if @forbid_focus_steps

    super
  end
end
