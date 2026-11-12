# frozen_string_literal: true

# Fakes of the collaborators Workspace::CLI::Workflow takes besides its commands, each held to
# its real class in fake_contract_spec.

# Fake of Workspace::WorkflowProject: +workspace+ answers the working directory's workspace,
# +projects+ maps a workspace name or a directory to its project (nil when neither is listed).
class RecordingWorkflowProject
  CONTROL_METHODS = %i[calls].freeze

  Resolved = Struct.new(:project)

  attr_reader :calls

  def initialize(workspace: nil, projects: {})
    @workspace = workspace
    @projects = projects
    @calls = []
  end

  def for_directory(dir)
    @calls << [:for_directory, dir]
    @projects.key?(dir) ? Resolved.new(@projects[dir]) : nil
  end

  def workspace(dir)
    @calls << [:workspace, dir]
    @workspace
  end

  def for_workspace(name)
    @calls << [:for_workspace, name]
    Resolved.new(@projects.fetch(name, name))
  end
end

# Fake of Workspace::StatusScope: answers a Hash naming the call and its keywords, so a spec sees
# the scope it was handed to the command.
class RecordingStatusScope
  CONTROL_METHODS = %i[calls].freeze

  attr_reader :calls

  def initialize
    @calls = []
  end

  def resolve(name:, project:, all:, working_dir:)
    answer(:resolve, name: name, project: project, all: all, working_dir: working_dir)
  end

  def resolve_needs_me(name:, project:, all:, working_dir:)
    answer(:resolve_needs_me, name: name, project: project, all: all, working_dir: working_dir)
  end

  private

  def answer(method, **keywords)
    @calls << [method, keywords]
    {method => keywords}
  end
end

# Fake of Workspace::ProjectDetector: +detect+ answers +workspaces+ for a directory.
class RecordingProjectDetector
  CONTROL_METHODS = %i[calls].freeze

  attr_reader :calls

  def initialize(workspaces = {})
    @workspaces = workspaces
    @calls = []
  end

  def detect(working_dir)
    @calls << [:detect, working_dir]
    @workspaces[working_dir]
  end
end
