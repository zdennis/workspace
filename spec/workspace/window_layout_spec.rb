RSpec.describe Workspace::WindowLayout do
  let(:config) { Workspace::Config.new }
  let(:window_manager) { double("window_manager") }
  let(:output) { StringIO.new }
  let(:layout) { described_class.new(window_manager: window_manager, config: config, output: output) }

  describe "#calculate_positions" do
    it "returns empty array for 0 windows" do
      result = layout.calculate_positions(
        screen_x: 0, screen_y: 0, screen_w: 1920, screen_h: 1080, count: 0
      )
      expect(result).to eq([])
    end

    it "centers a single window on 1920x1080" do
      result = layout.calculate_positions(
        screen_x: 0, screen_y: 0, screen_w: 1920, screen_h: 1080, count: 1
      )
      expect(result.size).to eq(1)
      pos = result.first
      # window_width = (1920 * 0.22).to_i = 422
      # window_height = (1080 * 0.9).to_i = 972
      # y = (1080 - 972) / 2 = 54
      # spacing = 422 (no overlap needed)
      # start_x = (1920 - (0 * 422 + 422)) / 2 = 749
      expect(pos[:width]).to eq(422)
      expect(pos[:height]).to eq(972)
      expect(pos[:x]).to eq(749)
      expect(pos[:y]).to eq(54)
    end

    it "spaces 3 windows evenly on 1920x1080" do
      result = layout.calculate_positions(
        screen_x: 0, screen_y: 0, screen_w: 1920, screen_h: 1080, count: 3
      )
      expect(result.size).to eq(3)
      # window_width = 422, total = 422 * 3 = 1266 <= 1920, so spacing = 422
      # start_x = (1920 - (422 * 2 + 422)) / 2 = (1920 - 1266) / 2 = 327
      expect(result[0][:x]).to eq(327)
      expect(result[1][:x]).to eq(749)
      expect(result[2][:x]).to eq(1171)
      result.each do |pos|
        expect(pos[:width]).to eq(422)
        expect(pos[:height]).to eq(972)
        expect(pos[:y]).to eq(54)
      end
    end

    it "shrinks spacing when too many windows would overflow" do
      result = layout.calculate_positions(
        screen_x: 0, screen_y: 0, screen_w: 1920, screen_h: 1080, count: 6
      )
      expect(result.size).to eq(6)
      # window_width = 422, total = 422 * 6 = 2532 > 1920
      # spacing = ((1920 - 422).to_f / 5).to_i = (1498.0 / 5).to_i = 299
      # start_x = (1920 - (299 * 5 + 422)) / 2 = (1920 - 1917) / 2 = 1
      expect(result[0][:x]).to eq(1)
      expect(result[1][:x]).to eq(300)
      # Each subsequent window is spaced by 299
      result.each_cons(2) do |a, b|
        expect(b[:x] - a[:x]).to eq(299)
      end
    end

    it "handles non-zero screen offsets for second monitor" do
      result = layout.calculate_positions(
        screen_x: 1920, screen_y: 0, screen_w: 1920, screen_h: 1080, count: 1
      )
      pos = result.first
      # Same as single window but shifted by screen_x
      expect(pos[:x]).to eq(1920 + 749)
      expect(pos[:y]).to eq(54)
    end

    it "handles 2 windows symmetrically" do
      result = layout.calculate_positions(
        screen_x: 0, screen_y: 0, screen_w: 1920, screen_h: 1080, count: 2
      )
      # window_width = 422, total = 844 <= 1920, spacing = 422
      # start_x = (1920 - (422 + 422)) / 2 = 538
      expect(result[0][:x]).to eq(538)
      expect(result[1][:x]).to eq(960)
      # Verify symmetry: distance from left edge to first window == distance from last window right edge to right edge
      left_margin = result[0][:x]
      right_margin = 1920 - (result[1][:x] + 422)
      expect(left_margin).to eq(right_margin)
    end
  end

  describe "#calculate_tile_positions" do
    it "returns empty array for 0 windows" do
      result = layout.calculate_tile_positions(
        screen_x: 0, screen_y: 0, screen_w: 1920, screen_h: 1080, count: 0
      )
      expect(result).to eq([])
    end

    it "fills screen with a single window" do
      result = layout.calculate_tile_positions(
        screen_x: 0, screen_y: 0, screen_w: 1920, screen_h: 1080, count: 1
      )
      expect(result.size).to eq(1)
      pos = result.first
      expect(pos[:x]).to eq(0)
      expect(pos[:y]).to eq(0)
      expect(pos[:width]).to eq(1920)
      expect(pos[:height]).to eq(1080)
    end

    it "splits screen into equal columns for 3 windows" do
      result = layout.calculate_tile_positions(
        screen_x: 0, screen_y: 0, screen_w: 1920, screen_h: 1080, count: 3
      )
      expect(result.size).to eq(3)
      expect(result[0]).to eq(x: 0, y: 0, width: 640, height: 1080)
      expect(result[1]).to eq(x: 640, y: 0, width: 640, height: 1080)
      expect(result[2]).to eq(x: 1280, y: 0, width: 640, height: 1080)
    end

    it "gives the last column any remainder pixels" do
      result = layout.calculate_tile_positions(
        screen_x: 0, screen_y: 0, screen_w: 1920, screen_h: 1080, count: 7
      )
      # 1920 / 7 = 274, 274 * 7 = 1918, remainder = 2
      expect(result.first[:width]).to eq(274)
      expect(result.last[:width]).to eq(276)
      # All columns together fill the screen
      expect(result.last[:x] + result.last[:width]).to eq(1920)
    end

    it "handles non-zero screen offsets" do
      result = layout.calculate_tile_positions(
        screen_x: 1920, screen_y: 100, screen_w: 1920, screen_h: 1080, count: 2
      )
      expect(result[0]).to eq(x: 1920, y: 100, width: 960, height: 1080)
      expect(result[1]).to eq(x: 2880, y: 100, width: 960, height: 1080)
    end
  end
end
