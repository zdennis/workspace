# The real session monitor builder with its defaults, for specs that start an
# agent daemon and don't care which monitor it runs. Scans are ungated.
module DefaultSessionMonitorBuilder
  def default_session_monitor_builder(tmux:, error_output:)
    Workspace::SessionMonitorBuilder.new(tmux: tmux, logger: Workspace::Logger.new, error_output: error_output, scan_slots: nil)
  end
end

RSpec.configure { |config| config.include DefaultSessionMonitorBuilder }
