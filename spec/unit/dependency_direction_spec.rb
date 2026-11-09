require "spec_helper"
require "tmpdir"
require "fileutils"
require_relative "../support/boundary_rules"

# One scan of lib/ shared by the examples that read the real tree.
module DependencyDirectionTree
  def self.found
    @found ||= BoundaryRules.violations(PROJECT_ROOT)
  end
end

RSpec.describe "dependency direction" do
  def violations_in(files)
    Dir.mktmpdir do |root|
      files.each do |path, source|
        full = File.join(root, path)
        FileUtils.mkdir_p(File.dirname(full))
        File.write(full, source)
      end
      BoundaryRules.violations(root)
    end
  end

  describe "the tree" do
    let(:found) { DependencyDirectionTree.found }
    let(:allowed) { BoundaryRules.allow_list(File.join(PROJECT_ROOT, BoundaryRules::ALLOW_FILE)) }

    it "has no wrong-way reference beyond the allow-list" do
      new_ones = found.reject { |v| allowed.key?(v.key) }

      expect(new_ones.map { |v| "#{v.file}:#{v.line}: #{v.message}\n  key: #{v.key}" }).to eq([])
    end

    it "has no allow-list entry that no longer matches a violation" do
      stale = allowed.keys - found.map(&:key)

      expect(stale).to eq([]), "allow-list entries no longer needed; delete them:\n#{stale.join("\n")}"
    end

    it "gives every allow-list entry a reason" do
      missing = allowed.reject { |_key, entry| entry.is_a?(Hash) && entry["reason"].to_s.strip != "" }

      expect(missing.keys).to eq([])
    end
  end

  describe "mutation checks" do
    let(:base) do
      {
        "lib/workspace/core/duration.rb" => "module Workspace\n  class Duration\n  end\nend\n",
        "lib/workspace/sub.rb" => "module Workspace\n  class Sub\n  end\nend\n",
        "lib/workspace/commands/inbox.rb" => "module Workspace\n  module Commands\n    class Inbox\n    end\n  end\nend\n"
      }
    end

    it "passes the unmutated tree" do
      expect(violations_in(base)).to eq([])
    end

    it "check 1: fails when core references a class outside core" do
      files = base.merge("lib/workspace/core/duration.rb" => "module Workspace\n  class Duration\n    def go = Sub.new\n  end\nend\n")

      found = violations_in(files)

      expect(found.map(&:key)).to eq(["core_references_nothing|lib/workspace/core/duration.rb|Sub"])
      expect(found.first.line).to eq(3)
    end

    it "does not count a core reference found only in a comment or a string" do
      files = base.merge("lib/workspace/core/duration.rb" => "module Workspace\n  class Duration\n    # Sub\n    X = \"Sub\"\n  end\nend\n")

      expect(violations_in(files)).to eq([])
    end

    it "fails when a file below commands references a Commands class" do
      files = base.merge("lib/workspace/sub.rb" => "module Workspace\n  class Sub\n    def go = Commands::Inbox.new\n  end\nend\n")

      expect(violations_in(files).map(&:key)).to eq(["commands_below_commands|lib/workspace/sub.rb|Commands::Inbox"])
    end

    it "lets the composition root, commands and the cli reference Commands classes" do
      uses = "module Workspace\n  class Holder\n    def go = Commands::Inbox.new\n  end\nend\n"
      files = base.merge(
        "lib/workspace.rb" => uses,
        "lib/workspace/cli.rb" => uses,
        "lib/workspace/commands/other.rb" => uses
      )

      expect(violations_in(files)).to eq([])
    end

    it "check 4: fails when a file other than the run store parses a run file" do
      source = "module Workspace\n  class Peek\n    def go(config) = JSON.parse(File.read(File.join(config.workflow_runs_dir, \"x.json\")))\n  end\nend\n"
      files = base.merge("lib/workspace/peek.rb" => source)

      expect(violations_in(files).map(&:key)).to eq(["run_file_parse|lib/workspace/peek.rb|JSON.parse"])
    end

    it "lets the run store and run_liveness parse run files" do
      source = "module Workspace\n  class Reader\n    def go(config) = JSON.parse(File.read(File.join(config.workflow_runs_dir, \"x.json\")))\n  end\nend\n"
      files = base.merge("lib/workspace/workflow_run_store.rb" => source, "lib/workspace/run_liveness.rb" => source)

      expect(violations_in(files)).to eq([])
    end
  end
end
