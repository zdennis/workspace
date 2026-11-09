# The WorkspaceLineage a spec builds when it wants git's real answer, wired to
# the same Git#path_of that build_cli passes. Specs that never resolve a
# lineage can pass it all the same: nothing runs until #resolve is called.
module LineageSupport
  REV_PARSE = ->(dir, what) { Workspace::Git.new.path_of(dir, what) }

  def self.lineage
    Workspace::WorkspaceLineage.new(rev_parse: REV_PARSE)
  end
end
