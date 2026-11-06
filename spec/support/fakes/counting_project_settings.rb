# frozen_string_literal: true

# A project settings reader over real files that counts how often it loaded a file.
class CountingProjectSettings < Workspace::ProjectSettings
  attr_reader :load_calls

  def load(project_name)
    @load_calls = load_calls.to_i + 1
    super
  end
end
