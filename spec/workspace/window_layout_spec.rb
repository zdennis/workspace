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
        screen_x: 0, screen_y: 0, screen_w: 1920, screen_h: 1080, current_bounds: []
      )
      expect(result).to eq([])
    end

    it "preserves size of a single window" do
      result = layout.calculate_tile_positions(
        screen_x: 0, screen_y: 0, screen_w: 1920, screen_h: 1080,
        current_bounds: [{x: 100, y: 200, width: 600, height: 800}]
      )
      expect(result.size).to eq(1)
      pos = result.first
      expect(pos[:width]).to eq(600)
      expect(pos[:height]).to eq(800)
      expect(pos[:x]).to eq(0)
      # vertically centered: (1080 - 800) / 2 = 140
      expect(pos[:y]).to eq(140)
    end

    it "places windows side-by-side keeping their sizes when they fit" do
      bounds = [
        {x: 0, y: 0, width: 500, height: 800},
        {x: 0, y: 0, width: 600, height: 900},
        {x: 0, y: 0, width: 400, height: 700}
      ]
      result = layout.calculate_tile_positions(
        screen_x: 0, screen_y: 0, screen_w: 1920, screen_h: 1080,
        current_bounds: bounds
      )
      expect(result.size).to eq(3)
      # Widths preserved
      expect(result[0][:width]).to eq(500)
      expect(result[1][:width]).to eq(600)
      expect(result[2][:width]).to eq(400)
      # Heights preserved
      expect(result[0][:height]).to eq(800)
      expect(result[1][:height]).to eq(900)
      expect(result[2][:height]).to eq(700)
      # Positions: left-to-right, starting at screen_x
      expect(result[0][:x]).to eq(0)
      expect(result[1][:x]).to eq(500)
      expect(result[2][:x]).to eq(1100)
      # Vertically centered
      expect(result[0][:y]).to eq(140) # (1080 - 800) / 2
      expect(result[1][:y]).to eq(90)  # (1080 - 900) / 2
      expect(result[2][:y]).to eq(190) # (1080 - 700) / 2
    end

    it "shrinks windows proportionally when total width exceeds screen" do
      bounds = [
        {x: 0, y: 0, width: 1200, height: 1000},
        {x: 0, y: 0, width: 1200, height: 800}
      ]
      result = layout.calculate_tile_positions(
        screen_x: 0, screen_y: 0, screen_w: 1920, screen_h: 1080,
        current_bounds: bounds
      )
      # Total = 2400, scale = 1920/2400 = 0.8
      expect(result[0][:width]).to eq(960)  # 1200 * 0.8
      expect(result[1][:width]).to eq(960)  # 1200 * 0.8
      expect(result[0][:height]).to eq(800) # 1000 * 0.8
      expect(result[1][:height]).to eq(640) # 800 * 0.8
      expect(result[0][:x]).to eq(0)
      expect(result[1][:x]).to eq(960)
    end

    it "handles non-zero screen offsets" do
      bounds = [
        {x: 0, y: 0, width: 800, height: 900},
        {x: 0, y: 0, width: 800, height: 900}
      ]
      result = layout.calculate_tile_positions(
        screen_x: 1920, screen_y: 100, screen_w: 1920, screen_h: 1080,
        current_bounds: bounds
      )
      expect(result[0][:x]).to eq(1920)
      expect(result[1][:x]).to eq(2720)
      expect(result[0][:width]).to eq(800)
      expect(result[1][:width]).to eq(800)
      # Vertically centered within screen: 100 + (1080 - 900) / 2 = 190
      expect(result[0][:y]).to eq(190)
      expect(result[1][:y]).to eq(190)
    end
  end
end
