# frozen_string_literal: true

require "spec_helper"

RSpec.describe Workspace::TerminalText do
  describe ".escape" do
    it "leaves ordinary text, including non-ASCII, alone" do
      expect(described_class.escape("plain, café 日本")).to eq("plain, café 日本")
    end

    it "names newline, return, tab and escape" do
      expect(described_class.escape("a\nb\rc\td\e[31m")).to eq("a\\nb\\rc\\td\\e[31m")
    end

    it "keeps tabs when asked, and still escapes newlines" do
      expect(described_class.escape("a\tb\nc", keep_tabs: true)).to eq("a\tb\\nc")
    end

    it "escapes C0, DEL and C1 controls as \\uXXXX" do
      expect(described_class.escape("\u0000\u0007\u007f\u009b")).to eq("\\u0000\\u0007\\u007F\\u009B")
    end

    it "escapes bidi controls and isolates" do
      text = "\u202a\u202b\u202c\u202d\u202e\u2066\u2067\u2068\u2069\u200e\u200f\u061c"
      expect(described_class.escape(text)).to eq(text.each_char.map { |c| format("\\u%04X", c.ord) }.join)
    end

    it "escapes zero-width and invisible characters" do
      text = "\u00ad\u180e\u200b\u200c\u200d\u2060\u2064\u2065\ufeff\u2028\u2029"
      expect(described_class.escape(text)).to eq(text.each_char.map { |c| format("\\u%04X", c.ord) }.join)
    end

    it "turns invalid UTF-8 into the replacement character without raising" do
      expect(described_class.escape((+"ok\xff\xfe!").force_encoding("UTF-8"))).to eq("ok��!")
    end

    it "prints nil as an empty string and other values through to_s" do
      expect(described_class.escape(nil)).to eq("")
      expect(described_class.escape(12)).to eq("12")
    end
  end
end
