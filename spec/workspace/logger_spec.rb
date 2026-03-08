require "stringio"

RSpec.describe Workspace::Logger do
  let(:output) { StringIO.new }

  describe "#debug" do
    context "when enabled" do
      subject(:logger) { described_class.new(output: output, enabled: true) }

      it "writes message with [DEBUG] prefix" do
        logger.debug("hello world")
        expect(output.string).to eq("[DEBUG] hello world\n")
      end

      it "accepts a block for deferred message construction" do
        logger.debug { "computed #{1 + 1}" }
        expect(output.string).to eq("[DEBUG] computed 2\n")
      end

      it "prefers block over message argument" do
        logger.debug("ignored") { "from block" }
        expect(output.string).to eq("[DEBUG] from block\n")
      end
    end

    context "when disabled" do
      subject(:logger) { described_class.new(output: output, enabled: false) }

      it "does not write anything" do
        logger.debug("hello")
        expect(output.string).to be_empty
      end

      it "does not evaluate the block" do
        evaluated = false
        logger.debug do
          evaluated = true
          "msg"
        end
        expect(evaluated).to be false
      end
    end
  end

  describe "#enabled?" do
    it "returns true when enabled" do
      logger = described_class.new(enabled: true)
      expect(logger.enabled?).to be true
    end

    it "returns false when disabled" do
      logger = described_class.new(enabled: false)
      expect(logger.enabled?).to be false
    end

    it "defaults to disabled" do
      logger = described_class.new
      expect(logger.enabled?).to be false
    end
  end

  describe "#enable!" do
    it "enables a previously disabled logger" do
      logger = described_class.new(output: output, enabled: false)
      logger.enable!
      expect(logger.enabled?).to be true
      logger.debug("now enabled")
      expect(output.string).to include("now enabled")
    end
  end
end
