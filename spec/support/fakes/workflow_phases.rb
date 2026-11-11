# frozen_string_literal: true

# Recording fakes of the collaborators the workflow engine's phase classes take. Each records its calls in
# +calls+ as `[method, *arguments]` and answers what it was given; nothing touches a file, a pane or git.
# `fake_contract_spec` checks that each accepts every call its real class accepts.

# Fake of Workspace::InstructionComposer#compose: answers +text+ and +packs+ as given.
class RecordingComposer
  CONTROL_METHODS = %i[calls].freeze

  attr_reader :calls

  # @param text [String]
  # @param packs [Array<String>] the refs of the packs the answer names
  def initialize(text: "composed", packs: [])
    @text = text
    @packs = packs
    @calls = []
  end

  def compose(packs:, cwd:, binding: nil, workflow: nil, step: nil, attempt: nil, skip: [])
    @calls << [:compose, {packs: packs, cwd: cwd, binding: binding, workflow: workflow, step: step, attempt: attempt, skip: skip}]
    {"text" => @text, "packs" => @packs.map { |ref| {"ref" => ref} }}
  end
end

# Fake of Workspace::GitExclude: records each pattern added, and says it is listed once added.
class RecordingGitExclude
  CONTROL_METHODS = %i[calls].freeze

  attr_reader :calls

  def initialize
    @calls = []
  end

  def add(worktree, pattern)
    @calls << [:add, worktree, pattern]
    true
  end

  def listed?(worktree, pattern)
    @calls.include?([:add, worktree, pattern])
  end
end
