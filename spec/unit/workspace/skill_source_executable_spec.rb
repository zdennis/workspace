require "spec_helper"
require "tmpdir"
require "fileutils"

RSpec.describe Workspace::SkillSource, "#executable" do
  around do |example|
    Dir.mktmpdir("skill-source-exe") do |dir|
      @dir = File.realpath(dir)
      example.run
    end
  end

  def script(path, first_line = "#!/usr/bin/env ruby")
    FileUtils.mkdir_p(File.dirname(path))
    File.write(path, "#{first_line}\nputs 1\n")
  end

  def error_of
    yield
    nil
  rescue Workspace::Error => e
    e
  end

  it "answers a checkout's bin/workspace" do
    script("#{@dir}/co/bin/workspace")
    expect(described_class.new(workspace_dir: "#{@dir}/co").executable).to eq("#{@dir}/co/bin/workspace")
  end

  it "refuses a linked worktree" do
    script("#{@dir}/wt/bin/workspace")
    FileUtils.mkdir_p("#{@dir}/main/.git/worktrees/wt")
    File.write("#{@dir}/main/.git/worktrees/wt/commondir", "../..")
    File.write("#{@dir}/wt/.git", "gitdir: #{@dir}/main/.git/worktrees/wt\n")
    error = error_of { described_class.new(workspace_dir: "#{@dir}/wt").executable }
    expect(error.code).to eq("sweep_source_worktree")
    expect(error.details).to include("path" => "#{@dir}/wt")
  end

  it "reports a missing bin/workspace, and a directory that does not exist" do
    FileUtils.mkdir_p("#{@dir}/empty")
    expect(error_of { described_class.new(workspace_dir: "#{@dir}/empty").executable }.code).to eq("sweep_program_missing")
    expect(error_of { described_class.new(workspace_dir: "#{@dir}/nope").executable }.code).to eq("sweep_program_missing")
  end

  it "refuses a file without a Ruby shebang" do
    script("#{@dir}/sh/bin/workspace", "#!/bin/bash")
    expect(error_of { described_class.new(workspace_dir: "#{@dir}/sh").executable }.code).to eq("sweep_program_missing")
  end

  it "answers the opt path for a Cellar install, and never the opt wrapper in bin/" do
    script("#{@dir}/brew/Cellar/workspace/1.0/libexec/bin/workspace")
    script("#{@dir}/brew/opt/workspace/libexec/bin/workspace")
    FileUtils.mkdir_p("#{@dir}/brew/opt/workspace/libexec")
    expect(described_class.new(workspace_dir: "#{@dir}/brew/Cellar/workspace/1.0/libexec").executable).to eq("#{@dir}/brew/opt/workspace/libexec/bin/workspace")
    File.write("#{@dir}/brew/opt/workspace/libexec/bin/workspace", "#!/bin/bash\n")
    script("#{@dir}/brew/opt/workspace/bin/workspace")
    expect(error_of { described_class.new(workspace_dir: "#{@dir}/brew/Cellar/workspace/1.0/libexec").executable }.code).to eq("sweep_program_missing")
  end
end
