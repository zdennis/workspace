require "spec_helper"

RSpec.describe "reflection.md isolation" do
  # Nothing may read a reflection into a prompt: these are the files that compose what a run's agent, a rejected
  # step's next attempt or a review round is sent.
  %w[
    lib/workspace/workflow_prompt.rb
    lib/workspace/instruction_composer.rb
    lib/workspace/workflow_review_round.rb
    lib/workspace/workflow_rejection.rb
  ].each do |path|
    it "#{path} never mentions reflection.md" do
      text = File.read(File.join(PROJECT_ROOT, path))

      expect(text).not_to include("reflection.md")
    end
  end
end
