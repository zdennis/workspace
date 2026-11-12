require "json"

# Records which `Workspace::Commands::*` public methods a run calls, for
# `script/record-cli-coverage` (S8 T39 and T48). Off unless WORKSPACE_TRACE_COMMANDS names the
# file to write; then a TracePoint over every thread notes each method defined in
# lib/workspace/commands/ that runs, and the public ones are written at exit as a sorted
# JSON list of `Workspace::Commands::Name#method` and `Workspace::Commands::Name.method`.
module CommandsMethodTrace
  DIR = File.join(PROJECT_ROOT, "lib", "workspace", "commands", "")

  def self.start(path)
    seen = {}
    trace = TracePoint.new(:call) do |tp|
      seen[[tp.self.is_a?(Module) ? tp.self : nil, tp.defined_class, tp.method_id]] = true if tp.path.start_with?(DIR)
    end
    trace.enable
    at_exit do
      trace.disable
      File.write(path, JSON.pretty_generate(names(seen.keys)) + "\n")
    end
  end

  # @param keys [Array<Array(Module, Module, Symbol)>] for each method called, the receiver when
  #   it is a class or module (a class method), the class that defines it, and its name
  # @return [Array<String>] the public ones of a `Workspace::Commands` class or module, sorted
  def self.names(keys)
    keys.filter_map do |receiver, owner, id|
      target, separator = receiver ? [receiver, "."] : [owner, "#"]
      next unless target.name.to_s.start_with?("Workspace::Commands::")
      next unless receiver ? receiver.respond_to?(id) : owner.public_method_defined?(id, false)

      "#{target.name}#{separator}#{id}"
    end.uniq.sort
  end
end

CommandsMethodTrace.start(ENV["WORKSPACE_TRACE_COMMANDS"]) if ENV["WORKSPACE_TRACE_COMMANDS"]
