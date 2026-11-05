# frozen_string_literal: true

require "spec_helper"

RSpec.describe Workspace::ProtectedBranch do
  let(:git) { instance_double(Workspace::Git) }
  let(:project) { Struct.new(:root).new("/src/app") }
  let(:default_branch) { "main" }
  let(:main_branch) { "develop" }
  let(:targets) { {} }
  let(:held) { {} }

  subject(:protected_branch) { described_class.new(git: git) }

  before do
    allow(git).to receive(:default_branch_name).with("/src/app").and_return(default_branch)
    allow(git).to receive(:worktree_branch).with("/src/app").and_return(main_branch)
    allow(git).to receive(:branch_target) { |_root, name| targets.fetch(name, name) }
    allow(git).to receive(:find_worktree_by_branch) { |name, **| held[name] }
  end

  it "protects the default branch" do
    expect(protected_branch.call("main", project)).to eq(reason: "default_branch", path: nil)
  end

  it "reports the checkout holding the default branch" do
    held["main"] = "/src/app/.worktrees/keep"
    expect(protected_branch.call("main", project)).to eq(reason: "default_branch", path: "/src/app/.worktrees/keep")
  end

  it "protects the main checkout's branch and names the project root" do
    expect(protected_branch.call("develop", project)).to eq(reason: "main_checkout", path: "/src/app")
  end

  it "protects a symref to the default branch" do
    targets["HEAD-alias"] = "main"
    expect(protected_branch.call("HEAD-alias", project)).to include(reason: "default_branch")
  end

  it "protects a case alias" do
    expect(protected_branch.call("MAIN", project)).to include(reason: "default_branch")
  end

  it "does not protect a feature branch" do
    expect(protected_branch.call("feature", project)).to be_nil
  end

  it "does not protect a nil branch" do
    expect(protected_branch.call(nil, project)).to be_nil
  end

  context "when the default branch name is unknown" do
    let(:default_branch) { nil }

    it "counts as not protected" do
      expect(protected_branch.call("main", project)).to be_nil
    end
  end
end
