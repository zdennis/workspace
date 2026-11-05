RSpec.describe Workspace::ContextReasons do
  describe ".fix_hint" do
    it "gives a kind workspace scrapes from its own pane (Codex) the hint that takes effect for it" do
      hint = described_class.fix_hint("codex")

      expect(hint).to eq(described_class::SCRAPED_KIND_FIX_HINT)
      expect(hint).to include("context.patterns")
      expect(hint).to include("~/.config/workspace/config.yml")
      expect(hint).not_to include("statusLine")
    end

    it "gives Claude Code, an unknown kind, and no kind the statusLine routing hint" do
      expect(described_class.fix_hint("claude")).to eq(described_class::FIX_HINT)
      expect(described_class.fix_hint("nope")).to eq(described_class::FIX_HINT)
      expect(described_class.fix_hint(nil)).to eq(described_class::FIX_HINT)
    end
  end
end
