# frozen_string_literal: true

# A session monitor that starts and stops nothing. +record+ keeps the event names it is told of, and
# +scan_now+ runs the callable given to +on_scan=+, so a spec drives a scan by hand.
class QuietSessionMonitor
  attr_reader :events

  def initialize(events: [])
    @events = events
    @on_scan = nil
  end

  def start
  end

  def stop
  end

  def record(message)
    @events << message["event"]
  end

  attr_writer :on_scan

  def scan_now
    @on_scan.call
  end
end
