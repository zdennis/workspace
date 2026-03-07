#!/usr/bin/env ruby
# frozen_string_literal: true

require "json"
require "set"

state_file = File.expand_path("~/.workspace-state.json")
unless File.exist?(state_file)
  puts JSON.generate(items: [{title: "No active projects", subtitle: "Launch a project first", valid: false}])
  exit
end

begin
  state = JSON.parse(File.read(state_file))
rescue JSON::ParserError
  puts JSON.generate(items: [{title: "State file corrupt", subtitle: "Re-launch your projects to rebuild state", valid: false}])
  exit
end

wt_output = `window-tool --app com.googlecode.iterm2 list --json 2>&1`.force_encoding("UTF-8")
wt_success = $?.success?

unless wt_success
  if wt_output.include?("Accessibility")
    puts JSON.generate(items: [{title: "Accessibility access required", subtitle: "Grant Alfred access in System Settings > Privacy & Security > Accessibility", valid: false}])
  else
    puts JSON.generate(items: [{title: "window-tool error", subtitle: wt_output.lines.first&.strip || "Unknown error", valid: false}])
  end
  exit
end

live = Set.new
JSON.parse(wt_output).each { |w| live.add(w["window_id"].to_s) }

items = state.keys.sort.filter_map { |project|
  wid = state[project]["iterm_window_id"].to_s
  {title: project, arg: project, subtitle: "Focus #{project}", autocomplete: project} if live.include?(wid)
}

if items.empty?
  items = [{title: "No active projects", subtitle: "Launch a project first", valid: false}]
end

puts JSON.generate(items: items)
