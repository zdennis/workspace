# frozen_string_literal: true

# Fakes of the collaborators Workspace::CLI::Launcher takes, each held to its real class in
# fake_contract_spec.

# Fake of Workspace::Commands::Launch: records each call and answers +result+, or what +answer+
# gives for the projects and options.
class RecordingLaunchCommand
  CONTROL_METHODS = %i[calls].freeze

  attr_reader :calls

  def initialize(result: {exit_code: 0}, &answer)
    @result = result
    @answer = answer
    @calls = []
  end

  def call(projects, **opts)
    @calls << [projects, opts]
    @answer ? @answer.call(projects, **opts) : @result
  end
end

# Fake of Workspace::Library for launches: a play is found under its ref with a path naming the
# directory it was looked up from; the prompt and bindings name what they were built from.
class RecordingLaunchLibrary
  CONTROL_METHODS = %i[calls].freeze

  attr_reader :calls

  def initialize
    @calls = []
  end

  def play(ref, cwd:)
    @calls << [:play, ref, cwd]
    {"ref" => "play/#{ref}", "scope" => "global", "path" => "#{cwd}/#{ref}.md", "sha256" => "sha-#{ref}"}
  end

  def play_prompt(plays, prompt, packs: nil)
    [*Array(plays).map { |play| "play:#{play["ref"]}" }, packs, prompt].compact.join(" | ")
  end

  def play_binding(plays, packs: [])
    {"kind" => "play", "id" => Array(plays).first["ref"], "packs" => packs}
  end

  def packs_binding(packs)
    {"kind" => "play", "id" => "play/#{packs.first}", "packs" => packs}
  end
end

# Fake of Workspace::InstructionComposer's start composition: answers the composition given for a
# cwd (default no packs) and records each call.
class RecordingStartComposer
  CONTROL_METHODS = %i[calls].freeze

  attr_reader :calls

  # @param by_cwd [Hash{String=>Hash}] cwd => the `compose_start` answer
  def initialize(by_cwd = {})
    @by_cwd = by_cwd
    @calls = []
  end

  def compose_start(cwd:, packs: [], none: false, handoff: nil, agent_kind: nil)
    @calls << {cwd: cwd, packs: packs, none: none, handoff: handoff}
    @by_cwd.fetch(cwd) { {"packs" => [], "text" => nil, "skipped" => []} }
  end
end

# Fake of Workspace::NameMigration: answers a Result for a name in +renames+ (name => [lowercase
# name or nil when nothing was renamed, warnings]) and nil for any other, as when its daemon is running.
class RecordingNameMigration
  CONTROL_METHODS = [].freeze

  def initialize(renames = {})
    @renames = renames
  end

  def call_locked(name, wait: true)
    to, warnings = @renames[name]
    return nil unless @renames.key?(name)

    Workspace::NameMigration::Result.new(name: to || name, from: to && name, renamed: !to.nil?, warnings: warnings || [])
  end
end

# Fake of Workspace::ProjectSettings for launches: the global config LaunchMode reads, and the
# projects whose settings file was made.
class RecordingLaunchSettings
  CONTROL_METHODS = %i[ensured].freeze

  attr_reader :ensured

  def initialize(global: {})
    @global = global
    @ensured = []
  end

  def load_global = @global

  def ensure_exists(project_name)
    @ensured << project_name
  end
end
