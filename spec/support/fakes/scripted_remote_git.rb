# frozen_string_literal: true

# A git collaborator that knows one remote url.
class ScriptedRemoteGit
  def initialize(url)
    @url = url
  end

  def remote_url(_path)
    @url
  end
end
