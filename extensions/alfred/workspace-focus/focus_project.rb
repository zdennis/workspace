#!/usr/bin/env ruby
# frozen_string_literal: true

require "json"

state_file = File.expand_path("~/.workspace-state.json")
exit 1 unless File.exist?(state_file)

state = JSON.parse(File.read(state_file))
wid = state.dig(ARGV[0], "iterm_window_id")
if wid
  exec("window-tool", "--app", "com.googlecode.iterm2", "focus", "id=#{wid}")
else
  exit 1
end
