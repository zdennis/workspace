RSpec.describe Workspace do
  describe ".run" do
    it "prints help for --help" do
      expect { Workspace.run(["--help"]) }.to output(/Usage: workspace/).to_stdout
    end
  end
end
